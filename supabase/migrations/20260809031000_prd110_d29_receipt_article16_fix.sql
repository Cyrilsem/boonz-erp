-- PRD-110 leg 163 · D-29 rider · ARTICLE 16: the receipt stops reading the authority table
--
-- ⭐ FIXTURE 77 seq 12 CAUGHT THIS, one fire after the engine landed. 20260809030500 added a
--    receipt field `clusters_on_v3` computed as
--        (SELECT count(*) FROM public.engine_cutover_authority_v3 WHERE authoritative_engine='v3')
--    i.e. record_blocked_demand_v3 reached into the cutover registry directly, in the same unit
--    whose entire point is that it reads the machine-grain canonical sibling instead.
--
-- ⛔ THE TEMPTING FIX WAS TO LOOSEN THE ASSERTION - "it is only a witness, not the rule". That is
--    how a guard gets relaxed into uselessness (S-315). The witness is dropped instead:
--
--    - The flag state already has a canonical home: engine_cutover_authority_v3 itself, with
--      v_cutover_readiness_v3 as its registered read object (METRICS_REGISTRY) and
--      engine_cutover_audit_v3 as its history. A receipt copy is a second source of the same
--      truth - exactly what Article 16 exists to prevent.
--    - Routing it through v_cutover_readiness_v3 instead would satisfy the letter and cost a
--      WMAPE computation over engine_forecast_error_v3 on EVERY nightly cron-43 call, to
--      populate a field nothing consumes.
--    - What the receipt legitimately owns is what this CALL did: gaps_suppressed_by_cutover and
--      rows_closed_by_cutover. Both stay. Neither reads the registry.
--
--    Fixture 77's seq 35/48/54 therefore stop reading the flag state off the receipt and read it
--    in the SCENARIO, at each of the three stages, straight from the canonical table. A fixture
--    may read anything; a production writer may not. The correlation those assertions pin -
--    flag state vs. observed effect - is unchanged and is still driven, not argued.
--
-- Article 12: forward-only. 20260809030500 is not edited.
-- Cody: revision under Article 16, raised by the fixture rather than by review.

BEGIN;

CREATE TEMP TABLE _d29b_live_before ON COMMIT DROP AS
SELECT count(*)::int AS n,
       COALESCE(md5(string_agg(bd.blocked_demand_id::text, ',' ORDER BY bd.blocked_demand_id)), 'EMPTY') AS h
  FROM public.blocked_demand bd
 WHERE bd.plan_date < DATE '2027-01-01' AND bd.resolved_at IS NULL;

DO $pre$
DECLARE v_md5 text;
BEGIN
  SELECT md5(p.prosrc) INTO v_md5 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'record_blocked_demand_v3';
  IF v_md5 <> '9aa140565362614ce3c96b06104e0857' THEN
    RAISE EXCEPTION 'D-29 rider pre-image: record_blocked_demand_v3 prosrc md5 is %, expected the 20260809030500 image', v_md5;
  END IF;
  IF (SELECT count(*) FROM public.engine_cutover_authority_v3 WHERE authoritative_engine = 'v3') <> 0 THEN
    RAISE EXCEPTION 'D-29 rider pre-image: a cluster is already authoritative for v3; this unit ships FLAG-OFF';
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
    -- ⭐ D-29's audit surface: what THIS CALL did. Both read 0 at flag-off, so an existing
    -- consumer's receipt is a strict superset of the one it read yesterday.
    -- ⛔ The flag STATE is deliberately NOT echoed here (Article 16). It lives in the cutover
    -- registry, is read through v_cutover_readiness_v3, and its history is the cutover audit
    -- log. A copy on this receipt would be a second source of one truth.
    -- ⛔ The registry table is not named anywhere in this body ON PURPOSE: fixture 77 seq 12 and
    -- this unit's post-image guard both test for the bare table name, which is the one form of
    -- the check that no alias, join shape or CTE can slip past. The cost is that the table
    -- cannot be named even in a comment. That is the intended trade.
    'rows_closed_by_cutover',     v_closed_c,
    'gaps_suppressed_by_cutover', v_suppr,
    'open_rows_now',    (SELECT count(*) FROM public.blocked_demand
                          WHERE plan_date = p_plan_date AND source = p_source
                            AND resolved_at IS NULL),
    'other_reason_rows',v_other,
    'legacy_skipped',   v_legacy,
    'duration_ms',      (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int
  );
END $function$;

DO $post$
DECLARE v_src text; v_nd int; v_n int;
BEGIN
  SELECT p.prosrc, p.pronargdefaults INTO v_src, v_nd
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'record_blocked_demand_v3';
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'record_blocked_demand_v3';

  IF v_n <> 1  THEN RAISE EXCEPTION 'D-29 rider: % signatures, expected 1', v_n; END IF;
  IF v_nd <> 1 THEN RAISE EXCEPTION 'D-29 rider: pronargdefaults is %, expected 1', v_nd; END IF;

  -- ⭐⭐ THE POINT OF THIS RIDER: the registry table is gone from the body entirely.
  IF v_src LIKE '%engine_cutover_authority_v3%' THEN
    RAISE EXCEPTION 'D-29 rider: record_blocked_demand_v3 still reads engine_cutover_authority_v3 directly (Article 16)';
  END IF;

  -- everything D-29 actually shipped must survive the rider
  IF (length(v_src) - length(replace(v_src, 'is_cluster_authoritative_v3(g.machine_id) = (p_source', '')))
       / length('is_cluster_authoritative_v3(g.machine_id) = (p_source') <> 3 THEN
    RAISE EXCEPTION 'D-29 rider: the keep predicate is no longer at exactly 3 gap sites';
  END IF;
  IF v_src NOT LIKE '%is_cluster_authoritative_v3(bd.machine_id) <> (p_source%' THEN
    RAISE EXCEPTION 'D-29 rider: the DELETE classifier is gone'; END IF;
  IF v_src NOT LIKE '%rows_closed_by_cutover%'     THEN RAISE EXCEPTION 'D-29 rider: rows_closed_by_cutover is gone'; END IF;
  IF v_src NOT LIKE '%gaps_suppressed_by_cutover%' THEN RAISE EXCEPTION 'D-29 rider: gaps_suppressed_by_cutover is gone'; END IF;
  IF v_src NOT LIKE '%rows_closed_stale%'          THEN RAISE EXCEPTION 'D-29 rider: rows_closed_stale is gone'; END IF;
  IF v_src NOT LIKE '%operator_admin%'             THEN RAISE EXCEPTION 'D-29 rider: the role gate is gone'; END IF;
  IF v_src NOT LIKE '%not implemented%'            THEN RAISE EXCEPTION 'D-29 rider: the pack refusal is gone'; END IF;
  IF v_src NOT LIKE '%app.via_rpc%'                THEN RAISE EXCEPTION 'D-29 rider: the provenance GUC is gone'; END IF;
  IF v_src NOT LIKE '%app.rpc_name%'               THEN RAISE EXCEPTION 'D-29 rider: the rpc_name GUC is gone'; END IF;
  IF v_src NOT LIKE '%legacy_skipped%'             THEN RAISE EXCEPTION 'D-29 rider: the legacy diagnostic is gone'; END IF;
  IF has_function_privilege('anon','public.record_blocked_demand_v3(date,text)','EXECUTE') THEN
    RAISE EXCEPTION 'D-29 rider: anon can EXECUTE record_blocked_demand_v3'; END IF;
END $post$;

-- ── FIXTURE 77: the three flag-state witnesses move OFF the receipt and into the scenario ──────
-- ⭐ Captured at all three stages (before the flip, while flipped, after the revert) from the
--    canonical table. A fixture may read the registry; a production writer may not.
UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
$OLD$  v_open_novo_back   int := -1;
BEGIN$OLD$,
$NEW$  v_open_novo_back   int := -1;
  v_flag_base int := -1;
  v_flag_flip int := -1;
  v_flag_back int := -1;
BEGIN$NEW$)
 WHERE fixture_id = 77;

UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
$OLD$    v_base := public.record_blocked_demand_v3(v_d, 'engine_add');$OLD$,
$NEW$    v_base := public.record_blocked_demand_v3(v_d, 'engine_add');
    v_flag_base := (SELECT count(*) FROM public.engine_cutover_authority_v3 WHERE authoritative_engine='v3');$NEW$)
 WHERE fixture_id = 77;

UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
$OLD$    v_after := public.record_blocked_demand_v3(v_d, 'engine_add');$OLD$,
$NEW$    v_after := public.record_blocked_demand_v3(v_d, 'engine_add');
    v_flag_flip := (SELECT count(*) FROM public.engine_cutover_authority_v3 WHERE authoritative_engine='v3');$NEW$)
 WHERE fixture_id = 77;

UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
$OLD$    v_back := public.record_blocked_demand_v3(v_d, 'engine_add');$OLD$,
$NEW$    v_back := public.record_blocked_demand_v3(v_d, 'engine_add');
    v_flag_back := (SELECT count(*) FROM public.engine_cutover_authority_v3 WHERE authoritative_engine='v3');$NEW$)
 WHERE fixture_id = 77;

UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
$OLD$      'base_clusters',    (v_base->>'clusters_on_v3'),$OLD$,
$NEW$      'base_clusters',    v_flag_base,$NEW$)
 WHERE fixture_id = 77;

UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
$OLD$      'after_clusters',   (v_after->>'clusters_on_v3'),$OLD$,
$NEW$      'after_clusters',   v_flag_flip,$NEW$)
 WHERE fixture_id = 77;

UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
$OLD$      'back_clusters',    (v_back->>'clusters_on_v3'),$OLD$,
$NEW$      'back_clusters',    v_flag_back,$NEW$)
 WHERE fixture_id = 77;

UPDATE golden.assertions
   SET description = 'The scenario witnesses the flag state this call ran under - read from the canonical registry, NOT echoed on the receipt (Article 16)'
 WHERE fixture_id = 77 AND seq IN (35, 48, 54);

-- ⭐ seq 12 STAYS EXACTLY AS WRITTEN. It is the assertion that caught this, and loosening it to
--    accommodate the code it caught is how a guard becomes decoration.

-- ── the applied change did what it claimed, and the live worklist never moved ──────────────────
DO $verify$
DECLARE v_src text; v_n int; v_h text; v_bn int; v_bh text; v_repl int;
BEGIN
  SELECT scenario_sql INTO v_src FROM golden.fixtures WHERE fixture_id = 77;
  -- ⛔ ->> is the discriminator. The fixture's STATIC half still has a scratch key spelled
  --    clusters_on_v3 that reads the registry directly for seq 30's LAW-4 check, and that is
  --    correct: a fixture may read the registry. What must be gone is reading it off the
  --    RECEIPT, which is spelled ->>'clusters_on_v3'.
  IF v_src LIKE '%->>''clusters_on_v3''%' THEN
    RAISE EXCEPTION 'D-29 rider: fixture 77 still reads clusters_on_v3 off the receipt; a replace() did not match';
  END IF;
  SELECT count(*) INTO v_repl FROM regexp_matches(v_src, 'v_flag_(base|flip|back) :=', 'g');
  IF v_repl <> 3 THEN
    RAISE EXCEPTION 'D-29 rider: expected 3 scenario-side flag captures, found %', v_repl;
  END IF;

  SELECT n, h INTO v_bn, v_bh FROM _d29b_live_before;
  SELECT count(*)::int,
         COALESCE(md5(string_agg(bd.blocked_demand_id::text, ',' ORDER BY bd.blocked_demand_id)), 'EMPTY')
    INTO v_n, v_h FROM public.blocked_demand bd
   WHERE bd.plan_date < DATE '2027-01-01' AND bd.resolved_at IS NULL;
  IF v_n <> v_bn OR v_h IS DISTINCT FROM v_bh THEN
    RAISE EXCEPTION 'D-29 rider: the LIVE procurement worklist moved (% -> % rows)', v_bn, v_n;
  END IF;
END $verify$;

COMMIT;
