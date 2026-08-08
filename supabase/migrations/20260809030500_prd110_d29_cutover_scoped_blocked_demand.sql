-- PRD-110 leg 163 · D-29 EXECUTED · the blocked-demand ledger gets ONE owner per cluster
--
-- CS RULING: "D-29 -> YES AT CUTOVER. Nightly runner promotes stitch blocked demand for
--             v3-authoritative clusters; engine_add rows suppressed there. No double counting."
--
-- ONE predicate, read at the three sites in record_blocked_demand_v3 that call
-- _blocked_demand_gaps_for_source_v3 (the counters, the INSERT, the DELETE's NOT EXISTS):
--
--     public.is_cluster_authoritative_v3(g.machine_id) = (p_source = 'stitch')
--
-- p_source='engine_add' keeps the gaps on clusters still on v19; p_source='stitch' keeps the gaps
-- on clusters flipped to v3. Exactly one source owns any given machine, at every flag state.
--
-- ⭐ ARTICLE 16: it READS the machine-grain canonical sibling. The authority rule is never
--    restated here - fixture 77 seq 12 refuses this function if engine_cutover_authority_v3 ever
--    appears in its body.
--
-- ⛔ THE DELETE IS THE DESIGN DECISION, NOT A DETAIL. Scoping it means a flip DELETES that
--    cluster's open engine_add rows from a LIVE PROCUREMENT WORKLIST. That is the dedup CS asked
--    for, and a worklist that shrinks for an unstated reason is the LAW-5 silent-qty-0 failure
--    wearing a different hat. So the receipt is split rather than widened:
--      rows_closed_stale       the gap genuinely went away          (unchanged meaning)
--      rows_closed_by_cutover  the gap is still there; the OTHER engine owns it now   (new)
--      gaps_suppressed_by_cutover  what the READ dropped before any row was written   (new)
--      clusters_on_v3          the flag state the call ran under                      (new)
--    gaps_found = 0 with gaps_suppressed_by_cutover = 0 means "no gaps".
--    gaps_found = 0 with gaps_suppressed_by_cutover = N means "another engine owns them".
--    Those two are indistinguishable without this counter, and they call for opposite actions.
--
-- ⛔ CODY FINDING, STATED RATHER THAN GLOSSED (Article 8): tg_audit_blocked_demand mints a
--    write_audit_log row for every DELETE this function performs, so Article 8 is satisfied at
--    row grain. It is NOT satisfied at REASON grain: the audit row for a cutover close and the
--    audit row for a stale close are identical - both read rpc_name='record_blocked_demand_v3'.
--    ONLY THE RECEIPT SPLITS THEM, AND RECEIPTS ARE NOT PERSISTED. A reader asking "why did this
--    procurement row vanish" must correlate against engine_cutover_audit_v3 by timestamp. Making
--    the audit row itself carry the reason means two separate DELETE statements with distinct
--    GUCs; that is a real improvement and it is NOT in this unit's scope (LAW 10). Parked, named.
--
-- ⛔ FLAG-OFF, AND WHAT IT MEANS FOR EACH ARM:
--    engine_add (cron 43, nightly, 16:15 UTC) - at 0 authoritative clusters keep evaluates
--      (false = false) = true for every machine, so the arm is byte-identical to today.
--      Fixture 77 seq 31/32/33 drive that rather than assert it.
--    stitch - at 0 authoritative clusters this arm records NOTHING, which is correct and is a
--      real change. It is inert in production: blocked_demand carries 48 stitch rows and ALL 48
--      sit on 2030 fixture dates, ZERO on real dates; no cron calls it with 'stitch'; and D-34
--      (the nightly runner that will) has not shipped. Verified live before apply.
--
-- LAW 1: fixture 77 (20260809030000) landed RED before this migration. Fixture 47 is re-baselined
--        in 20260809031000 - under D-29 its premise genuinely changed and it must now establish
--        authority for its own cluster, which makes it the stitch arm's end-to-end proof.
-- Cody: reviewed, approve-with-revisions; all revisions landed before apply.

BEGIN;

-- ⭐ CODY REVISION 2: the live worklist is the number CS actually reads. Pin it for the whole
--    migration in a temp table and compare at the end. Proving inertness on a synthetic 2030
--    date proves nothing about the 22 open real-date rows.
CREATE TEMP TABLE _d29_live_before ON COMMIT DROP AS
SELECT count(*)::int AS n,
       COALESCE(md5(string_agg(bd.blocked_demand_id::text, ',' ORDER BY bd.blocked_demand_id)), 'EMPTY') AS h
  FROM public.blocked_demand bd
 WHERE bd.plan_date < DATE '2027-01-01' AND bd.resolved_at IS NULL;

-- ── PRE-IMAGE GUARD: refuse to patch a body that is not the one this unit was written against ──
DO $pre$
DECLARE v_md5 text; v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'record_blocked_demand_v3';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'D-29 pre-image: expected exactly 1 record_blocked_demand_v3 signature, found %', v_n;
  END IF;

  SELECT md5(p.prosrc) INTO v_md5 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'record_blocked_demand_v3';
  IF v_md5 <> 'f950b17fb2cc11d4f1a1e5eb9558b6ee' THEN
    RAISE EXCEPTION 'D-29 pre-image: record_blocked_demand_v3 prosrc md5 is %, expected f950b17fb2cc11d4f1a1e5eb9558b6ee', v_md5;
  END IF;

  -- the canonical sibling this unit reads must exist and be the machine-grain one
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'public' AND p.proname = 'is_cluster_authoritative_v3'
                    AND pg_get_function_identity_arguments(p.oid) = 'p_machine_id uuid') THEN
    RAISE EXCEPTION 'D-29 pre-image: is_cluster_authoritative_v3(uuid) is missing; DR-1/DR-1b must ship first';
  END IF;

  -- ⛔ LAW 4 at apply time: this migration may not land on a flipped fleet, or its "inert"
  --    claim would be untestable against the live table.
  IF (SELECT count(*) FROM public.engine_cutover_authority_v3 WHERE authoritative_engine = 'v3') <> 0 THEN
    RAISE EXCEPTION 'D-29 pre-image: a cluster is already authoritative for v3; this unit ships FLAG-OFF';
  END IF;
END $pre$;

CREATE OR REPLACE FUNCTION public.record_blocked_demand_v3(p_plan_date date, p_source text DEFAULT 'engine_add'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id  uuid;
  v_gaps     int := 0;
  v_units    int := 0;
  v_ins      int := 0;
  v_upd      int := 0;
  v_closed   int := 0;
  v_closed_c int := 0;
  v_suppr    int := 0;
  v_other    int := 0;
  v_legacy   int := 0;
  v_t0       timestamptz := clock_timestamp();
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'record_blocked_demand_v3', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_user_id AND up.role IN ('operator_admin','superadmin')
  ) THEN
    RAISE EXCEPTION 'record_blocked_demand_v3: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'record_blocked_demand_v3: p_plan_date is required';
  END IF;
  -- P3.1e. 'stitch' joins 'engine_add' as a supported source. ⛔ 'pack' still raises: it is
  -- a valid blocked_demand.source but has no gap source until P4.4b, and a writer that
  -- silently recorded nothing would be indistinguishable from a clean run.
  IF p_source IS NULL OR p_source NOT IN ('engine_add','stitch') THEN
    RAISE EXCEPTION 'record_blocked_demand_v3: source % not implemented (engine_add since P0.5, stitch since P3.1e; pack lands with P4.4b)', p_source;
  END IF;

  -- ⭐⭐ D-29. ONE OWNER PER CLUSTER. A gap counts for this source only when the machine's
  -- cluster is on the engine this source speaks for: engine_add owns the clusters still on
  -- v19, stitch owns the clusters flipped to v3. The rule is read from the machine-grain
  -- canonical sibling, never restated (Article 16).
  --
  -- ⛔ v_suppr is not decoration. Without it a caller cannot tell "no gaps" from "the other
  -- engine owns them" - the same silent-zero LAW 5 forbids in the plan, one layer up.
  SELECT count(*) FILTER (WHERE g.keep)::int,
         COALESCE(sum(g.qty_blocked) FILTER (WHERE g.keep), 0)::int,
         count(*) FILTER (WHERE g.keep AND g.reason = 'routing_gap')::int,
         count(*) FILTER (WHERE NOT g.keep)::int
    INTO v_gaps, v_units, v_other, v_suppr
    FROM (SELECT g.*,
                 (public.is_cluster_authoritative_v3(g.machine_id) = (p_source = 'stitch')) AS keep
            FROM public._blocked_demand_gaps_for_source_v3(p_plan_date, p_source) g) g;

  -- 'legacy' counts v19 pod_refills rows that predate the need_raw field, so it is an
  -- engine_add diagnostic only. Reporting it for a stitch run would attribute an unrelated
  -- table's shape to this call.
  IF p_source = 'engine_add' THEN
    SELECT count(*)::int INTO v_legacy
      FROM public.pod_refills pr
     WHERE pr.plan_date = p_plan_date AND pr.reasoning->>'need_raw' IS NULL;
  END IF;

  WITH ins AS (
    INSERT INTO public.blocked_demand AS bd
      (plan_date, machine_id, shelf_id, pod_product_id, qty_blocked, reason, source,
       detected_by, reasoning)
    SELECT p_plan_date, g.machine_id, g.shelf_id, g.pod_product_id, g.qty_blocked, g.reason,
           p_source, 'record_blocked_demand_v3', g.reasoning
      FROM public._blocked_demand_gaps_for_source_v3(p_plan_date, p_source) g
     WHERE public.is_cluster_authoritative_v3(g.machine_id) = (p_source = 'stitch')
    ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id, source)
      WHERE resolved_at IS NULL
    DO UPDATE SET qty_blocked = EXCLUDED.qty_blocked,
                  reason      = EXCLUDED.reason,
                  reasoning   = EXCLUDED.reasoning
    WHERE bd.qty_blocked IS DISTINCT FROM EXCLUDED.qty_blocked
       OR bd.reason      IS DISTINCT FROM EXCLUDED.reason
       OR bd.reasoning   IS DISTINCT FROM EXCLUDED.reasoning
    RETURNING (xmax = 0) AS was_insert
  )
  SELECT count(*) FILTER (WHERE was_insert)::int,
         count(*) FILTER (WHERE NOT was_insert)::int
    INTO v_ins, v_upd
    FROM ins;

  -- ⛔ THE CLOSE. Two different events reach this DELETE and they must not share a counter:
  -- a gap that genuinely resolved, and a gap this source no longer owns because CS flipped
  -- the cluster. The second one removes work from a live procurement worklist, so it is
  -- attributed on its own line.
  WITH del AS (
    DELETE FROM public.blocked_demand bd
     WHERE bd.plan_date   = p_plan_date
       AND bd.source      = p_source
       AND bd.resolved_at IS NULL
       AND NOT EXISTS (
         SELECT 1 FROM public._blocked_demand_gaps_for_source_v3(p_plan_date, p_source) g
          WHERE g.machine_id     = bd.machine_id
            AND g.shelf_id       = bd.shelf_id
            AND g.pod_product_id = bd.pod_product_id
            AND public.is_cluster_authoritative_v3(g.machine_id) = (p_source = 'stitch'))
    RETURNING (public.is_cluster_authoritative_v3(bd.machine_id) <> (p_source = 'stitch')) AS was_cutover)
  SELECT count(*) FILTER (WHERE was_cutover)::int,
         count(*) FILTER (WHERE NOT was_cutover)::int
    INTO v_closed_c, v_closed FROM del;

  RETURN jsonb_build_object(
    'plan_date',        p_plan_date,
    'source',           p_source,
    'gaps_found',       v_gaps,
    'units_blocked',    v_units,
    'rows_inserted',    v_ins,
    'rows_updated',     v_upd,
    'rows_closed_stale',v_closed,
    -- ⭐ D-29's audit surface. Both default to 0 at flag-off, so a receipt read by an existing
    -- consumer is a strict superset of the one it read yesterday.
    'rows_closed_by_cutover',     v_closed_c,
    'gaps_suppressed_by_cutover', v_suppr,
    'clusters_on_v3',   (SELECT count(*) FROM public.engine_cutover_authority_v3
                          WHERE authoritative_engine = 'v3'),
    'open_rows_now',    (SELECT count(*) FROM public.blocked_demand
                          WHERE plan_date = p_plan_date AND source = p_source
                            AND resolved_at IS NULL),
    'other_reason_rows',v_other,
    'legacy_skipped',   v_legacy,
    'duration_ms',      (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int
  );
END $function$;

-- ── POST-IMAGE GUARD: the change landed AND nothing load-bearing moved ─────────────────────────
DO $post$
DECLARE v_src text; v_n int; v_nd int;
BEGIN
  SELECT p.prosrc, p.pronargdefaults INTO v_src, v_nd
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'record_blocked_demand_v3';

  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'record_blocked_demand_v3';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'D-29 post-image: % signatures of record_blocked_demand_v3, expected 1 (an overload would make cron 43 ambiguous)', v_n;
  END IF;
  -- ⛔ Article 1 / cron 43: it is called with ONE argument.
  IF v_nd <> 1 THEN
    RAISE EXCEPTION 'D-29 post-image: pronargdefaults is %, expected 1', v_nd;
  END IF;

  -- the predicate landed at all THREE gap sites plus the DELETE classifier
  IF (length(v_src) - length(replace(v_src, 'is_cluster_authoritative_v3(g.machine_id) = (p_source', '')))
       / length('is_cluster_authoritative_v3(g.machine_id) = (p_source') <> 3 THEN
    RAISE EXCEPTION 'D-29 post-image: the keep predicate must appear at exactly 3 gap sites (counters, INSERT, DELETE)';
  END IF;
  IF v_src NOT LIKE '%is_cluster_authoritative_v3(bd.machine_id) <> (p_source%' THEN
    RAISE EXCEPTION 'D-29 post-image: the DELETE does not classify its own closes';
  END IF;

  -- Article 16: the rule is READ, never restated
  IF v_src LIKE '%engine_cutover_authority_v3 a%' OR v_src LIKE '%JOIN public.engine_cutover_authority_v3%' THEN
    RAISE EXCEPTION 'D-29 post-image: the authority rule is restated inline instead of read from the canonical sibling';
  END IF;

  -- the three new receipt keys
  IF v_src NOT LIKE '%rows_closed_by_cutover%'
     OR v_src NOT LIKE '%gaps_suppressed_by_cutover%'
     OR v_src NOT LIKE '%clusters_on_v3%'
     OR v_src NOT LIKE '%rows_closed_stale%' THEN
    RAISE EXCEPTION 'D-29 post-image: a receipt key is missing';
  END IF;

  -- ⭐ NAMED SURVIVOR CHECKS - the guards that had to come through the edit untouched
  IF v_src NOT LIKE '%operator_admin%'      THEN RAISE EXCEPTION 'D-29 post-image: the role gate is gone'; END IF;
  IF v_src NOT LIKE '%not implemented%'     THEN RAISE EXCEPTION 'D-29 post-image: the pack refusal is gone'; END IF;
  IF v_src NOT LIKE '%app.via_rpc%'         THEN RAISE EXCEPTION 'D-29 post-image: the provenance GUC is gone'; END IF;
  IF v_src NOT LIKE '%app.rpc_name%'        THEN RAISE EXCEPTION 'D-29 post-image: the rpc_name GUC is gone'; END IF;
  IF v_src NOT LIKE '%legacy_skipped%'      THEN RAISE EXCEPTION 'D-29 post-image: the legacy diagnostic is gone'; END IF;
  IF v_src NOT LIKE '%p_plan_date is required%' THEN RAISE EXCEPTION 'D-29 post-image: the null-date guard is gone'; END IF;

  -- ⛔ S-88: anon may not execute the writer. CREATE OR REPLACE preserves grants, so this is a
  --    check that the pre-existing revoke is still in force, not a new one.
  IF has_function_privilege('anon','public.record_blocked_demand_v3(date,text)','EXECUTE') THEN
    RAISE EXCEPTION 'D-29 post-image: anon can EXECUTE record_blocked_demand_v3';
  END IF;

  -- ⛔ the gap sources are NOT part of this unit
  IF (SELECT md5(p.prosrc) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname='public' AND p.proname='_blocked_demand_gaps_for_source_v3')
     <> '2b3ab311e394b9d5c794e598feb8bd5b' THEN
    RAISE EXCEPTION 'D-29 post-image: the gap dispatcher moved; it must be byte-untouched';
  END IF;
END $post$;

-- ── FLAG-OFF PROOF, EXECUTED: at 0 authoritative clusters the engine_add arm suppresses nothing ─
-- ⛔ Driven inside a subtransaction that is discarded, on a synthetic 2030 date, so the live
--    procurement worklist is never written to by this migration.
DO $inert$
DECLARE v_r jsonb; v_d date := DATE '2030-09-09';
BEGIN
  BEGIN
    v_r := public.record_blocked_demand_v3(v_d, 'engine_add');
    IF (v_r->>'gaps_suppressed_by_cutover') <> '0' THEN
      RAISE EXCEPTION 'D-29 inertness: engine_add suppressed % gaps at 0 authoritative clusters', v_r->>'gaps_suppressed_by_cutover';
    END IF;
    IF (v_r->>'clusters_on_v3') <> '0' THEN
      RAISE EXCEPTION 'D-29 inertness: clusters_on_v3 reads %, expected 0', v_r->>'clusters_on_v3';
    END IF;
    IF (v_r->>'rows_closed_by_cutover') <> '0' THEN
      RAISE EXCEPTION 'D-29 inertness: rows_closed_by_cutover reads %, expected 0', v_r->>'rows_closed_by_cutover';
    END IF;
    RAISE EXCEPTION 'D29INERT_OK';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'D29INERT_OK' THEN RAISE; END IF;
  END;
END $inert$;

-- ── CODY REVISION 2, THE OTHER HALF: the LIVE procurement worklist, unchanged ───────────────────
-- ⛔ Not a count comparison alone. The identity set is compared, so a delete-and-reinsert that
--    happened to keep the count would still be caught.
DO $live$
DECLARE v_n int; v_h text; v_bn int; v_bh text;
BEGIN
  SELECT n, h INTO v_bn, v_bh FROM _d29_live_before;
  SELECT count(*)::int,
         COALESCE(md5(string_agg(bd.blocked_demand_id::text, ',' ORDER BY bd.blocked_demand_id)), 'EMPTY')
    INTO v_n, v_h
    FROM public.blocked_demand bd
   WHERE bd.plan_date < DATE '2027-01-01' AND bd.resolved_at IS NULL;

  IF v_n <> v_bn OR v_h IS DISTINCT FROM v_bh THEN
    RAISE EXCEPTION 'D-29: the LIVE procurement worklist moved across this migration (% -> % rows, % -> %). This unit ships FLAG-OFF and must not touch a single real-date row.',
      v_bn, v_n, v_bh, v_h;
  END IF;
  RAISE NOTICE 'D-29 live worklist unchanged: % open rows on real dates', v_n;
END $live$;

COMMIT;
