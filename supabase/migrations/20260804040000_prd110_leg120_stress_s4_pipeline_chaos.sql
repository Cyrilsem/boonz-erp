-- PRD-110 STEP 7 · S4 — pipeline chaos (leg 120)
--
-- Goal-command S4: "re-run every engine 3× same date — idempotent, no dup lines".
--
-- ============================================================================
-- THE FIVE S-221 FLAWS IN THE DRAFT, AND WHAT REPLACES EACH
-- ============================================================================
-- `docs/prds/PRD-110-S4-scenario-DRAFT.sql` (leg 109) was never dry-proven and cannot
-- run. Leg 119 measured all five failures; leg 120 re-measured each one live before
-- writing a line of this file (LAW 13). The corrections:
--
--   1. WRONG OBJECT. The draft fires `run_nightly_shadow_v3` (engine + measure +
--      settle), which exercises ONE engine and never touches the stitch ladder.
--      "Every engine" is `run_pipeline_v3`, measured this leg to chain FOUR objects:
--        engine_add_pod_v3 -> compose_plan_with_edits_v3 -> stitch_v3
--        -> record_blocked_demand_v3 (step 4, gated on p_promote_blocked).
--      S4 drives `run_pipeline_v3`. ⭐ Note `run_pipeline_v3` has NO p_settle_limit
--      argument, so the draft's (and the design doc's) `p_settle_limit => 0` mandate
--      is moot here — it belonged to the runner, which S4 no longer calls.
--   2. CLEAN-ON-ENTRY IS REFUSED. `tg_pod_refills_shadow_append_only` and
--      `tg_refill_plan_output_shadow_append_only` are both BEFORE DELETE OR UPDATE
--      and raise 42501. S4 uses S1's BANK-AND-DIFF idiom instead: bank the run_id set
--      for the date up front, measure only generations this call mints. Nothing is
--      cleaned; nothing needs to be.
--   3. `min(s.created_at)` IS A 42703 — `pod_refills_shadow` has no `created_at`.
--      Generations are ordered by the loop index that minted them, which is exact.
--   4. RAW-`INSERT` INTO `machines_to_visit`. Cody's leg-119 ruling binds every
--      remaining suite: that table is protected in practice (RPC_REGISTRY designates
--      it so in three entries and RPC_REGISTRY:1214 carries a standing class-(b)
--      condition on exactly this consumer). S4 plants through
--      `pick_machine_manually`, which upserts — so no DELETE is needed and S4 issues
--      NO raw SQL against any plan table.
--   5. IT IS A GOLDEN FIXTURE. S1–S6 must stay out of `golden.fixtures` or S7 would
--      measure itself. Shipped as `golden.stress_s4_v1()`, modelled on
--      `golden.stress_s1_v1` (leg 119) and `golden.stress_s6_v1` (leg 117).
--
-- ============================================================================
-- WHICH FORM OF IDEMPOTENCE THIS TESTS (S-221 requires the suite to say)
-- ============================================================================
-- SINGLE-TRANSACTION form, as leg 119 recommended. All p_runs pipeline runs execute
-- inside one transaction, so no COMMIT of this suite's own output can be observed by a
-- later run of the same suite. The point is to remove input drift from the experiment,
-- so that a difference between generations can only come from the pipeline reading its
-- OWN prior output — an engine that accumulated across generations, or a compose step
-- that composed over a composed run, would diverge on run 2. A cross-transaction S4
-- would instead be measuring input stability, which is S7's job.
--
-- ⛔ CORRECTION AT CODY REVIEW — DO NOT RESTATE THE EARLIER VERSION OF THIS PARAGRAPH.
-- The draft claimed the runs "read ONE snapshot". THEY DO NOT. PostgreSQL's default
-- isolation is READ COMMITTED, under which every STATEMENT takes a FRESH snapshot, so
-- three sequential `run_pipeline_v3` calls see three snapshots and a concurrent commit
-- between them is visible. One transaction is NOT one snapshot, and a future leg acting
-- on the earlier wording would mis-diagnose a legitimate input drift as an engine defect
-- (the S-219 failure mode exactly). The suite cannot raise its own isolation level from
-- inside a function — SET TRANSACTION ISOLATION LEVEL must precede every query in the
-- transaction — so instead it carries an INPUT-DRIFT SENTINEL (assertion 33): a
-- fingerprint of the volatile inputs taken before the first run and again after the
-- last. `shelf_composition` is fingerprinted in full because cron 44 rewrites it every
-- hour at :40; the remaining input tables are pinned by row count. If assertion 33 reds,
-- the generation fingerprints are ALLOWED to differ and the cause is drift, not the
-- pipeline. Read 33 FIRST whenever 7, 8 or 9 is red.
--
-- ⛔ S-199 IS THE WHOLE DESIGN: the shadow tables are `run_id`-keyed and every engine
-- mints `gen_random_uuid()` per call with no DELETE and no ON CONFLICT, so three runs
-- LEGITIMATELY produce three generations. "Idempotent" therefore means CONTENT
-- EQUALITY PER `run_id`, never row-count stability. An S4 asserting "row count
-- unchanged" would go red against correct behaviour. Every assertion below compares
-- generation-to-generation content, and the only absolute counts asserted are the
-- LIVE tables, which must not move at all.
--
-- ============================================================================
-- MEASURED PREMISES (2026-08-04 leg 120, every one re-derived live)
-- ============================================================================
--   2030-11-04 free across all nine touched relations: machines_to_visit 0 ·
--     refill_plan_output 0 · pod_refill_plan 0 · pod_refills_shadow 0 ·
--     refill_plan_output_shadow 0 · pod_refill_plan_shadow 0 · shadow_runner_log_v3 0 ·
--     pipeline_runs_v3 0 · blocked_demand 0 · plan_edits_v3 0 ·
--     golden.fixtures with plan_date 2030-11-04 = 0
--   run_pipeline_v3(p_plan_date date, p_days_cover int, p_base_run_id uuid,
--                   p_promote_blocked boolean, p_note text) -> jsonb, SECURITY DEFINER,
--     NULL auth.uid() = trusted server-side caller
--   ONE full-fleet pipeline run on this date, dry-tested and rolled back:
--     engine 34 317 ms / 544 lines / 161 units / 31 machines · compose 67 ms /
--     lines_out 46 / units_out 161 (it drops the 498 qty-0 lines) · stitch 4 583 ms /
--     lines_in 46 / rows_out 47 / units_placed 160 / units_blocked 1 · total 38 983 ms.
--   ⛔ A THREE-MACHINE PLANT IS VACUOUS ON THIS DATE. Dry-tested first with the three
--     lowest machine_ids: the engine wrote 64 lines but units_planned = 0, so compose
--     dropped all 64, `run_pipeline_v3` returned status `composed_empty`, and STITCH
--     NEVER RAN. The engine's cost is ~34 s of fixed view materialisation regardless of
--     fleet size, so there is nothing to save by planting a subset. S4 plants the whole
--     fleet, and assertion 17 pins the coverage so a future shrink cannot go unnoticed.
--   engine output is unique on (machine_id, shelf_id, pod_product_id) — 0 duplicate
--     keys measured; stitch output is unique on the full leg key AND, as it happens,
--     on (machine, shelf, pod) too. Only the full-key uniqueness is ASSERTED: a shelf
--     whose need splits across an M2M leg and a WH leg may legitimately emit two rows
--     sharing (machine, shelf, pod), so asserting that would risk redding against
--     correct behaviour. The shelf/pod figure is recorded as a metric instead.
--   `_blocked_demand_gaps_stitch_v3` scopes to stitch's OWN LATEST run for the date
--     (ORDER BY produced_at DESC, run_id DESC LIMIT 1), so extra generations do NOT
--     fan the gap set out — run N promotes run N's stitch and nothing older.
--   `v_blocked_demand_open` filters `plan_date < '2030-01-01'`, so rows this suite
--     writes on 2030-11-04 are structurally invisible to procurement.
--
-- ============================================================================
-- WHY p_promote_blocked DEFAULTS TO TRUE, AND WHY THAT IS NOT EXECUTING D-29
-- ============================================================================
-- D-29 parks AUTO-promotion — the nightly path deciding by itself to write
-- `blocked_demand`. This suite passes the argument EXPLICITLY on a synthetic 2030
-- date. No default changes, no cron changes, no flag flips: `refill_policy_params` is
-- untouched and cron 45 still calls the nightly runner, which has no such step at all
-- (S-220). Running step 4 here is what makes S4 honest — `record_blocked_demand_v3`
-- is the one object in the chain whose idempotence is enforced by a UNIQUE index
-- rather than by minting a fresh run_id, so it is where "no dup lines" can actually
-- fail. Pass p_promote_blocked => false to skip it; assertions 23-27 then report
-- `skipped` and are excluded from n_pass/n_fail rather than passing vacuously.
--
-- ⚠️ EXPECTED, AND ASSERTED, NOT A DEFECT: run 1 INSERTs its blocked rows and runs
-- 2..N UPDATE them. `reasoning` carries the promoting stitch `run_id`, which is a new
-- uuid each generation, so the writer's `WHERE ... IS DISTINCT FROM` guard correctly
-- fires. The invariant that matters is that the OPEN ROW COUNT never moves and the
-- content fingerprint (machine, shelf, pod, qty, reason) is identical across all
-- generations — i.e. re-running re-stamps, it never duplicates.
--
-- LAW 4 / ADR §8 obligation 3: absolute (NOT date-scoped) counts of pod_refills,
-- pod_refill_plan and refill_plan_output are pinned before and after.
-- LAW 12: p_plan_date is guarded to the synthetic 2030+ band and refused if it
-- collides with any golden fixture's plan_date. Live plan dates are unreachable.
-- S-197: this plant does NOT set app.via_rpc.

-- ---------------------------------------------------------------------------
-- INPUT-DRIFT SENTINEL (Cody revision 2)
-- ---------------------------------------------------------------------------
-- One transaction is NOT one snapshot: PostgreSQL defaults to READ COMMITTED, so each
-- statement in `stress_s4_v1` sees a fresh snapshot and a concurrent COMMIT landing
-- between two pipeline runs is visible to the second. `stress_s4_v1` therefore cannot
-- claim its generations are compared against frozen inputs — it has to MEASURE that.
--
-- `shelf_composition` is fingerprinted ROW BY ROW because cron 44
-- (prd110_p14_composition_estimator_hourly, `40 * * * *`) rewrites it every hour and is
-- the one scheduled writer that can realistically fire inside S4's ~2-minute window.
-- Everything else the engine reads is pinned by row count, which is cheap and catches
-- an insert or delete; a silent in-place UPDATE of, say, one warehouse row would slip
-- through, and that is an accepted limit of the sentinel, not an oversight. The point
-- is to make the common drift self-diagnosing, not to prove global quiescence.
--
-- STABLE, read-only, INVOKER. No writes, no protected entity touched.

-- ⛔ DROP-then-CREATE, and why this is NOT an Article 12/13 violation. An earlier
-- iteration of THIS SAME, STILL-UNREGISTERED migration created the helper returning
-- `text`, and PostgreSQL refuses to change a function's return type in place (42P13).
-- The object has never appeared in a registered migration, nothing is deployed against
-- it, and its ONLY caller is `golden.stress_s4_v1` forty lines below in this same file.
-- There is no consumer to deprecate and no 90-day window to serve — the drop simply
-- keeps a dead signature from being left behind. Re-running this file after the jsonb
-- version is live drops and recreates the same object inside one transaction, so the
-- migration stays idempotent either way.
DROP FUNCTION IF EXISTS golden._s4_input_fingerprint(date);

-- ⭐ Returns jsonb, ONE KEY PER COMPONENT, deliberately not a single md5: when the
-- sentinel reds, assertion 33 names the drifted key outright instead of printing two
-- opaque hashes and leaving the next leg to bisect a ten-way concat by hand.
CREATE OR REPLACE FUNCTION golden._s4_input_fingerprint(p_plan_date date)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path TO 'golden', 'public', 'pg_temp'
AS $fp$
  SELECT jsonb_build_object(
    -- full content: the hourly estimator cron rewrites this table
    'shelf_composition', (SELECT md5(COALESCE(string_agg(
       c.shelf_id::text ||':'|| COALESCE(c.boonz_product_id::text,'~') ||':'||
       COALESCE(c.expiry_bucket::text,'~') ||':'|| COALESCE(c.est_qty::text,'~') ||':'||
       COALESCE(c.confidence::text,'~'), ';'
       ORDER BY c.shelf_id, c.boonz_product_id, c.expiry_bucket), ''))
       FROM public.shelf_composition c),
    -- row-count pins on the rest of the engine's input surface
    'machines',            (SELECT count(*) FROM public.machines),
    'shelf_configurations',(SELECT count(*) FROM public.shelf_configurations),
    'slot_lifecycle',      (SELECT count(*) FROM public.slot_lifecycle),
    'pod_inventory',       (SELECT count(*) FROM public.pod_inventory),
    'warehouse_inventory', (SELECT count(*) FROM public.warehouse_inventory),
    'product_sourcing',    (SELECT count(*) FROM public.product_sourcing),
    'inventory_events',    (SELECT count(*) FROM public.inventory_events),
    'plan_edits',          (SELECT count(*) FROM public.plan_edits_v3
                             WHERE plan_date = p_plan_date),
    'machines_to_visit',   (SELECT count(*) FROM public.machines_to_visit
                             WHERE plan_date = p_plan_date),
    -- the dial sheet is a one-row wide table; any tuning mid-suite would move the plan
    'params_updated_at',   (SELECT max(updated_at)::text FROM public.refill_policy_params)
  );
$fp$;

COMMENT ON FUNCTION golden._s4_input_fingerprint(date) IS
  'PRD-110 STEP 7 S4 input-drift sentinel. One transaction is NOT one snapshot under '
  'READ COMMITTED, so stress_s4_v1 pins the volatile engine inputs before its first run '
  'and re-reads them after its last (assertion 33). shelf_composition is hashed in full '
  'because cron 44 rewrites it hourly; the rest of the input surface is pinned by row '
  'count. A red assertion 33 means the generation fingerprints are ALLOWED to differ and '
  'the pipeline is not the suspect.';

REVOKE ALL ON FUNCTION golden._s4_input_fingerprint(date) FROM PUBLIC;

CREATE OR REPLACE FUNCTION golden.stress_s4_v1(
  p_plan_date       date    DEFAULT '2030-11-04'::date,
  p_days_cover      integer DEFAULT 7,
  p_runs            integer DEFAULT 3,
  p_promote_blocked boolean DEFAULT true,
  p_record          boolean DEFAULT true,
  p_note            text    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'golden', 'public', 'pg_temp'
AS $fn$
DECLARE
  v_started   timestamptz := clock_timestamp();
  v_t0        timestamptz;
  v_i         integer;
  v_mid       uuid;

  v_fleet     integer;
  v_planted   integer;
  v_unconf    integer;

  -- banked state
  v_prs_runs_b  uuid[];
  v_rpos_runs_b uuid[];
  v_pr_b bigint; v_pr_a bigint;
  v_pp_b bigint; v_pp_a bigint;
  v_ro_b bigint; v_ro_a bigint;
  v_bd_b bigint; v_bd_a bigint;          -- global, METRIC ONLY (cron 43 writes this table)
  v_bds_b bigint; v_bds_a bigint;        -- (plan_date, source) scoped, the ASSERTED pair
  v_in_fp_b jsonb; v_in_fp_a jsonb;      -- input-drift sentinel
  v_in_drift text;                       -- the drifted keys, named

  -- per-generation captures
  v_res        jsonb;
  v_status     text[]  := ARRAY[]::text[];
  v_pipe_id    uuid[]  := ARRAY[]::uuid[];
  v_base_id    uuid[]  := ARRAY[]::uuid[];
  v_plan_id    uuid[]  := ARRAY[]::uuid[];
  v_stit_id    uuid[]  := ARRAY[]::uuid[];
  v_eng_fp     text[]  := ARRAY[]::text[];
  v_cmp_fp     text[]  := ARRAY[]::text[];
  v_stt_fp     text[]  := ARRAY[]::text[];
  v_bd_fp      text[]  := ARRAY[]::text[];
  v_eng_n      int[]   := ARRAY[]::int[];
  v_cmp_n      int[]   := ARRAY[]::int[];
  v_stt_n      int[]   := ARRAY[]::int[];
  v_eng_dup    int[]   := ARRAY[]::int[];
  v_stt_dupf   int[]   := ARRAY[]::int[];
  v_stt_dupsp  int[]   := ARRAY[]::int[];
  v_eng_q0     int[]   := ARRAY[]::int[];
  v_mach_n     int[]   := ARRAY[]::int[];
  v_units_pl   int[]   := ARRAY[]::int[];
  v_bd_open    int[]   := ARRAY[]::int[];
  v_bd_ins     int[]   := ARRAY[]::int[];
  v_bd_upd     int[]   := ARRAY[]::int[];
  v_bd_cls     int[]   := ARRAY[]::int[];
  v_ms         int[]   := ARRAY[]::int[];

  v_base uuid; v_plan uuid; v_stit uuid;
  v_fp text; v_n int; v_d int; v_d2 int; v_q0 int; v_mc int;
  v_blocked jsonb;

  v_total_ms  integer;
  v_receipts  integer;
  v_new_ids   integer;

  v_detail jsonb;
  v_np integer; v_nf integer; v_ns integer;
  v_passed boolean;
  v_id uuid;
BEGIN
  ---------------------------------------------------------------- LAW 12 guards
  IF p_plan_date IS NULL OR p_plan_date < '2030-01-01'::date THEN
    RAISE EXCEPTION 'stress_s4_v1: p_plan_date must be in the synthetic 2030+ band, got % '
                    '(LAW 12 - never plant on a live plan date)', p_plan_date;
  END IF;

  IF EXISTS (SELECT 1 FROM golden.fixtures f WHERE f.plan_date = p_plan_date) THEN
    RAISE EXCEPTION 'stress_s4_v1: % is a golden fixture plan_date; the fixture cleans on '
                    'entry and would destroy the stress run', p_plan_date;
  END IF;

  IF p_days_cover IS NULL OR p_days_cover < 1 OR p_days_cover > 60 THEN
    RAISE EXCEPTION 'stress_s4_v1: p_days_cover must be 1..60, got %', p_days_cover;
  END IF;

  -- 2 is the minimum that can compare anything; 5 caps a ~40 s/run suite at ~3.5 min.
  IF p_runs IS NULL OR p_runs < 2 OR p_runs > 5 THEN
    RAISE EXCEPTION 'stress_s4_v1: p_runs must be 2..5 (goal command says 3), got %', p_runs;
  END IF;

  ------------------------------------------------------- BANK (append-only safe)
  SELECT COALESCE(array_agg(DISTINCT s.run_id), ARRAY[]::uuid[]) INTO v_prs_runs_b
    FROM public.pod_refills_shadow s WHERE s.plan_date = p_plan_date;

  SELECT COALESCE(array_agg(DISTINCT o.run_id), ARRAY[]::uuid[]) INTO v_rpos_runs_b
    FROM public.refill_plan_output_shadow o WHERE o.plan_date = p_plan_date;

  -- ADR §8 obligation 3 tripwire: ABSOLUTE counts, deliberately not date-scoped.
  SELECT count(*) INTO v_pr_b FROM public.pod_refills;
  SELECT count(*) INTO v_pp_b FROM public.pod_refill_plan;
  SELECT count(*) INTO v_ro_b FROM public.refill_plan_output;
  -- ⛔ GLOBAL count is a METRIC, never an assertion: cron 43
  -- (prd110_p05_blocked_demand_2015_dubai, 15 16 * * * UTC) writes this table on the
  -- LIVE plan date, so a global before/after pair can move for reasons that have
  -- nothing to do with S4. PARKING-LOT:5757 rules exactly this out. The ASSERTED pair
  -- is scoped to (plan_date, source), which no other writer can reach on a 2030 date.
  SELECT count(*) INTO v_bd_b FROM public.blocked_demand;
  SELECT count(*) INTO v_bds_b FROM public.blocked_demand
   WHERE plan_date = p_plan_date AND source = 'stitch';


  SELECT count(*) INTO v_fleet
    FROM public.machines m WHERE m.include_in_refill AND m.status = 'Active';

  ---------------------------------------------------------------------- PLANT
  -- Article 1/3 (Cody, leg 119): canonical Gate-0 writer only. It upserts on
  -- (plan_date, machine_id) and stamps status='cs_added' + confirmed_at, so the suite
  -- is re-runnable with no DELETE and `_assert_gate_zero` cannot match (S-219).
  FOR v_mid IN
    SELECT m.machine_id FROM public.machines m
     WHERE m.include_in_refill AND m.status = 'Active'
     ORDER BY m.machine_id
  LOOP
    PERFORM public.pick_machine_manually(
              p_plan_date, v_mid, 'PRD-110 STEP 7 S4 pipeline chaos');
  END LOOP;

  SELECT count(*) INTO v_planted
    FROM public.machines_to_visit
   WHERE plan_date = p_plan_date AND status IN ('picked','cs_added');

  SELECT count(*) INTO v_unconf
    FROM public.machines_to_visit
   WHERE plan_date = p_plan_date AND status = 'picked' AND confirmed_at IS NULL;

  -- INPUT-DRIFT SENTINEL (Cody revision 2), taken AFTER the plant on purpose.
  -- ⛔ The first draft captured it BEFORE, and the dry run duly went red on the suite's
  -- OWN 31 machines_to_visit rows. The sentinel's question is "did the inputs move
  -- ACROSS THE RUNS", not "did setup happen" — so the baseline is the post-plant state.
  SELECT golden._s4_input_fingerprint(p_plan_date) INTO v_in_fp_b;

  --------------------------------------------------------------- THE RUNS ×N
  FOR v_i IN 1..p_runs LOOP
    v_t0  := clock_timestamp();
    v_res := public.run_pipeline_v3(
               p_plan_date, p_days_cover, NULL, p_promote_blocked,
               COALESCE(p_note, 'PRD-110 S4') || ' run ' || v_i || '/' || p_runs);
    v_ms  := v_ms || (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int;

    v_status  := v_status  || COALESCE(v_res->>'status', '<null>');
    v_pipe_id := v_pipe_id || (v_res->>'pipeline_run_id')::uuid;

    v_base := (v_res->>'base_run_id')::uuid;
    v_plan := (v_res->>'planned_run_id')::uuid;
    v_stit := (v_res->'stitch'->>'run_id')::uuid;
    v_base_id := v_base_id || v_base;
    v_plan_id := v_plan_id || v_plan;
    v_stit_id := v_stit_id || v_stit;

    ---------------------------------------------------------- engine generation
    SELECT md5(COALESCE(string_agg(
             s.machine_id::text ||'|'|| s.shelf_id::text ||'|'||
             COALESCE(s.pod_product_id::text,'~') ||'|'|| s.qty::text, ';'
             ORDER BY s.machine_id, s.shelf_id, s.pod_product_id, s.qty), '')),
           count(*),
           count(*) - count(DISTINCT (s.machine_id, s.shelf_id, s.pod_product_id)),
           count(*) FILTER (WHERE s.qty = 0 AND s.clamp_reason IS NULL),
           count(DISTINCT s.machine_id)
      INTO v_fp, v_n, v_d, v_q0, v_mc
      FROM public.pod_refills_shadow s WHERE s.run_id = v_base;
    v_eng_fp  := v_eng_fp  || v_fp;
    v_eng_n   := v_eng_n   || v_n;
    v_eng_dup := v_eng_dup || v_d;
    v_eng_q0  := v_eng_q0  || v_q0;
    v_mach_n  := v_mach_n  || v_mc;

    --------------------------------------------------------- compose generation
    SELECT md5(COALESCE(string_agg(
             s.machine_id::text ||'|'|| s.shelf_id::text ||'|'||
             COALESCE(s.pod_product_id::text,'~') ||'|'|| s.qty::text, ';'
             ORDER BY s.machine_id, s.shelf_id, s.pod_product_id, s.qty), '')),
           count(*)
      INTO v_fp, v_n
      FROM public.pod_refills_shadow s WHERE s.run_id = v_plan;
    v_cmp_fp := v_cmp_fp || v_fp;
    v_cmp_n  := v_cmp_n  || v_n;

    ---------------------------------------------------------- stitch generation
    SELECT md5(COALESCE(string_agg(
             o.machine_id::text ||'|'|| o.shelf_id::text ||'|'||
             COALESCE(o.pod_product_id::text,'~') ||'|'|| COALESCE(o.action,'~') ||'|'||
             o.qty::text ||'|'|| COALESCE(o.resolved_rung,'~') ||'|'||
             COALESCE(o.source_origin::text,'~') ||'|'||
             COALESCE(o.from_machine_id::text,'~'), ';'
             ORDER BY o.machine_id, o.shelf_id, o.pod_product_id, o.action, o.qty,
                      o.resolved_rung, o.source_origin::text, o.from_machine_id), '')),
           count(*),
           count(*) - count(DISTINCT (o.machine_id, o.shelf_id, o.pod_product_id,
                                      o.action, o.resolved_rung, o.source_origin,
                                      o.from_machine_id)),
           count(*) - count(DISTINCT (o.machine_id, o.shelf_id, o.pod_product_id))
      INTO v_fp, v_n, v_d, v_d2
      FROM public.refill_plan_output_shadow o WHERE o.run_id = v_stit;
    v_stt_fp    := v_stt_fp    || v_fp;
    v_stt_n     := v_stt_n     || v_n;
    v_stt_dupf  := v_stt_dupf  || v_d;
    v_stt_dupsp := v_stt_dupsp || v_d2;
    v_units_pl  := v_units_pl  || COALESCE((v_res->'stitch'->>'units_placed')::int, 0);

    ------------------------------------------------- blocked-demand promotion
    v_blocked := v_res->'blocked';
    v_bd_ins  := v_bd_ins || COALESCE((v_blocked->>'rows_inserted')::int, 0);
    v_bd_upd  := v_bd_upd || COALESCE((v_blocked->>'rows_updated')::int, 0);
    v_bd_cls  := v_bd_cls || COALESCE((v_blocked->>'rows_closed_stale')::int, 0);

    SELECT count(*),
           md5(COALESCE(string_agg(
             b.machine_id::text ||'|'|| b.shelf_id::text ||'|'||
             b.pod_product_id::text ||'|'|| b.qty_blocked::text ||'|'|| b.reason, ';'
             ORDER BY b.machine_id, b.shelf_id, b.pod_product_id), ''))
      INTO v_n, v_fp
      FROM public.blocked_demand b
     WHERE b.plan_date = p_plan_date AND b.source = 'stitch' AND b.resolved_at IS NULL;
    v_bd_open := v_bd_open || v_n;
    v_bd_fp   := v_bd_fp   || v_fp;
  END LOOP;

  v_total_ms := (extract(epoch FROM clock_timestamp() - v_started) * 1000)::int;

  SELECT count(*) INTO v_receipts
    FROM public.pipeline_runs_v3 WHERE pipeline_run_id = ANY (v_pipe_id);

  -- every run_id this suite minted must be genuinely new against the bank
  SELECT count(*) INTO v_new_ids
    FROM unnest(v_base_id || v_plan_id) AS u(id)
   WHERE u.id IS NOT NULL AND u.id = ANY (v_prs_runs_b);

  SELECT count(*) INTO v_pr_a FROM public.pod_refills;
  SELECT count(*) INTO v_pp_a FROM public.pod_refill_plan;
  SELECT count(*) INTO v_ro_a FROM public.refill_plan_output;
  SELECT count(*) INTO v_bd_a FROM public.blocked_demand;
  SELECT count(*) INTO v_bds_a FROM public.blocked_demand
   WHERE plan_date = p_plan_date AND source = 'stitch';
  SELECT golden._s4_input_fingerprint(p_plan_date) INTO v_in_fp_a;

  SELECT COALESCE(string_agg(k.key || ': ' || (v_in_fp_b->>k.key) || ' -> '
                             || (v_in_fp_a->>k.key), '; ' ORDER BY k.key), 'none')
    INTO v_in_drift
    FROM jsonb_object_keys(v_in_fp_b) AS k(key)
   WHERE (v_in_fp_b->k.key) IS DISTINCT FROM (v_in_fp_a->k.key);

  ------------------------------------------------------------------ ASSERTIONS
  SELECT jsonb_agg(jsonb_build_object(
           'seq', t.seq, 'name', t.name, 'expect', t.expect,
           'actual', t.actual, 'passed', t.passed, 'skipped', t.skipped) ORDER BY t.seq),
         -- ⛔ COALESCE on the fail side, NOT the pass side: a NULL verdict must land as a
         -- FAILURE, never vanish from both counters and read as a clean run.
         count(*) FILTER (WHERE t.passed AND NOT t.skipped),
         count(*) FILTER (WHERE NOT COALESCE(t.passed, false) AND NOT t.skipped),
         count(*) FILTER (WHERE t.skipped)
    INTO v_detail, v_np, v_nf, v_ns
    FROM (VALUES
      -- ---- the pipeline actually completed, every time -----------------------
      ( 1, 'every_run_status_ok', 'all ok',
           array_to_string(v_status, ','),
           (SELECT bool_and(s = 'ok') FROM unnest(v_status) AS u(s)), false),
      -- ---- generations are distinct by design (S-199), never reused ----------
      ( 2, 'distinct_pipeline_run_ids', p_runs::text,
           (SELECT count(DISTINCT id)::text FROM unnest(v_pipe_id) AS u(id)),
           (SELECT count(DISTINCT id) FROM unnest(v_pipe_id) AS u(id)) = p_runs, false),
      ( 3, 'distinct_base_run_ids', p_runs::text,
           (SELECT count(DISTINCT id)::text FROM unnest(v_base_id) AS u(id)),
           (SELECT count(DISTINCT id) FROM unnest(v_base_id) AS u(id)) = p_runs, false),
      ( 4, 'distinct_planned_run_ids', p_runs::text,
           (SELECT count(DISTINCT id)::text FROM unnest(v_plan_id) AS u(id)),
           (SELECT count(DISTINCT id) FROM unnest(v_plan_id) AS u(id)) = p_runs, false),
      ( 5, 'distinct_stitch_run_ids', p_runs::text,
           (SELECT count(DISTINCT id)::text FROM unnest(v_stit_id) AS u(id)),
           (SELECT count(DISTINCT id) FROM unnest(v_stit_id) AS u(id)) = p_runs, false),
      ( 6, 'no_minted_run_id_collides_with_bank', '0',
           v_new_ids::text, v_new_ids = 0, false),
      -- ---- IDEMPOTENCE: content equality per run_id, NOT row-count stability --
      ( 7, 'engine_fingerprint_identical', '1 distinct',
           (SELECT count(DISTINCT f)::text FROM unnest(v_eng_fp) AS u(f)),
           (SELECT count(DISTINCT f) FROM unnest(v_eng_fp) AS u(f)) = 1, false),
      ( 8, 'compose_fingerprint_identical', '1 distinct',
           (SELECT count(DISTINCT f)::text FROM unnest(v_cmp_fp) AS u(f)),
           (SELECT count(DISTINCT f) FROM unnest(v_cmp_fp) AS u(f)) = 1, false),
      ( 9, 'stitch_fingerprint_identical', '1 distinct',
           (SELECT count(DISTINCT f)::text FROM unnest(v_stt_fp) AS u(f)),
           (SELECT count(DISTINCT f) FROM unnest(v_stt_fp) AS u(f)) = 1, false),
      (10, 'engine_line_count_identical', '1 distinct',
           array_to_string(v_eng_n, ','),
           (SELECT count(DISTINCT n) FROM unnest(v_eng_n) AS u(n)) = 1, false),
      (11, 'compose_line_count_identical', '1 distinct',
           array_to_string(v_cmp_n, ','),
           (SELECT count(DISTINCT n) FROM unnest(v_cmp_n) AS u(n)) = 1, false),
      (12, 'stitch_row_count_identical', '1 distinct',
           array_to_string(v_stt_n, ','),
           (SELECT count(DISTINCT n) FROM unnest(v_stt_n) AS u(n)) = 1, false),
      -- ---- NON-VACUITY (S-132: three no_picks runs are trivially identical) ---
      (13, 'engine_lines_gt_zero', '> 0',
           array_to_string(v_eng_n, ','),
           (SELECT bool_and(n > 0) FROM unnest(v_eng_n) AS u(n)), false),
      (14, 'compose_lines_gt_zero', '> 0',
           array_to_string(v_cmp_n, ','),
           (SELECT bool_and(n > 0) FROM unnest(v_cmp_n) AS u(n)), false),
      (15, 'stitch_rows_gt_zero', '> 0',
           array_to_string(v_stt_n, ','),
           (SELECT bool_and(n > 0) FROM unnest(v_stt_n) AS u(n)), false),
      (16, 'units_placed_gt_zero', '> 0',
           array_to_string(v_units_pl, ','),
           (SELECT bool_and(n > 0) FROM unnest(v_units_pl) AS u(n)), false),
      (17, 'machines_covered_eq_fleet', v_fleet::text,
           array_to_string(v_mach_n, ','),
           v_fleet > 0 AND (SELECT bool_and(n = v_fleet) FROM unnest(v_mach_n) AS u(n)), false),
      (18, 'plant_covers_whole_fleet', v_fleet::text,
           v_planted::text, v_planted = v_fleet AND v_fleet > 0, false),
      -- ---- NO DUP LINES ------------------------------------------------------
      (19, 'engine_no_dup_shelf_pod', '0',
           array_to_string(v_eng_dup, ','),
           (SELECT bool_and(n = 0) FROM unnest(v_eng_dup) AS u(n)), false),
      (20, 'stitch_no_dup_full_leg_key', '0',
           array_to_string(v_stt_dupf, ','),
           (SELECT bool_and(n = 0) FROM unnest(v_stt_dupf) AS u(n)), false),
      -- ---- LAW 5 sibling and LAW 11 -----------------------------------------
      (21, 'no_unexplained_qty0', '0',
           array_to_string(v_eng_q0, ','),
           (SELECT bool_and(n = 0) FROM unnest(v_eng_q0) AS u(n)), false),
      (22, 'gate0_no_unconfirmed_picks', '0',
           v_unconf::text, v_unconf = 0, false),
      -- ---- blocked-demand promotion: the UNIQUE-index idempotence ------------
      (23, 'bd_open_rows_constant', '1 distinct',
           array_to_string(v_bd_open, ','),
           (SELECT count(DISTINCT n) FROM unnest(v_bd_open) AS u(n)) = 1,
           NOT p_promote_blocked),
      (24, 'bd_inserts_only_on_first_run', 'first > 0, rest 0',
           array_to_string(v_bd_ins, ','),
           v_bd_ins[1] > 0 AND (SELECT bool_and(n = 0)
                                  FROM unnest(v_bd_ins[2:p_runs]) AS u(n)),
           NOT p_promote_blocked),
      (25, 'bd_no_stale_closes', '0',
           array_to_string(v_bd_cls, ','),
           (SELECT bool_and(n = 0) FROM unnest(v_bd_cls) AS u(n)),
           NOT p_promote_blocked),
      (26, 'bd_content_fingerprint_identical', '1 distinct',
           (SELECT count(DISTINCT f)::text FROM unnest(v_bd_fp) AS u(f)),
           (SELECT count(DISTINCT f) FROM unnest(v_bd_fp) AS u(f)) = 1,
           NOT p_promote_blocked),
      -- ⛔ SCOPED, not global (Cody revision 1 / PARKING-LOT:5757). The suite's own
      -- footprint on this date must equal exactly what run 1 inserted: promotion
      -- re-stamps, it never duplicates. The global pair is carried as a metric.
      (27, 'bd_scoped_growth_eq_first_insert', v_bd_ins[1]::text,
           (v_bds_a - v_bds_b)::text, (v_bds_a - v_bds_b) = v_bd_ins[1],
           NOT p_promote_blocked),
      -- ---- LAW 4 / ADR §8 obligation 3: SHADOW, DON'T SWITCH -----------------
      (28, 'live_pod_refills_untouched', v_pr_b::text,
           v_pr_a::text, v_pr_a = v_pr_b, false),
      (29, 'live_pod_refill_plan_untouched', v_pp_b::text,
           v_pp_a::text, v_pp_a = v_pp_b, false),
      (30, 'live_refill_plan_output_untouched', v_ro_b::text,
           v_ro_a::text, v_ro_a = v_ro_b, false),
      -- ---- receipts and budget ----------------------------------------------
      (31, 'pipeline_receipts_written', p_runs::text,
           v_receipts::text, v_receipts = p_runs, false),
      (32, 'total_runtime_under_10_min', '< 600000 ms',
           v_total_ms::text, v_total_ms < 600000, false),
      -- ⭐ READ THIS ONE FIRST when 7, 8 or 9 is red: if the inputs moved under the
      -- suite, the generations are ALLOWED to differ and the pipeline is not at fault.
      (33, 'inputs_stable_across_runs', 'none',
           v_in_drift, v_in_fp_a = v_in_fp_b, false)
    ) AS t(seq, name, expect, actual, passed, skipped);

  v_passed := (v_nf = 0);

  ---------------------------------------------------------------------- RECORD
  IF p_record THEN
    v_id := golden.record_stress(
              p_suite      => 'S4',
              p_passed     => v_passed,
              p_started_at => v_started,
              p_metric     => jsonb_build_object(
                                'plan_date',        p_plan_date,
                                'days_cover',       p_days_cover,
                                'runs',             p_runs,
                                'promote_blocked',  p_promote_blocked,
                                'idempotence_form', 'single-transaction, READ COMMITTED: one txn is NOT '
                                                 || 'one snapshot, so assertion 33 pins the inputs '
                                                 || 'and divergence is only attributable to the '
                                                 || 'pipeline reading its own output when 33 is green',
                                'total_ms',         v_total_ms,
                                'per_run_ms',       to_jsonb(v_ms),
                                'fleet',            v_fleet,
                                'machines_planted', v_planted,
                                'engine_lines',     to_jsonb(v_eng_n),
                                'compose_lines',    to_jsonb(v_cmp_n),
                                'stitch_rows',      to_jsonb(v_stt_n),
                                'units_placed',     to_jsonb(v_units_pl),
                                'stitch_dup_shelf_pod_metric_only', to_jsonb(v_stt_dupsp),
                                'bd_global_before', v_bd_b,
                                'bd_global_after',  v_bd_a,
                                'bd_scoped_before', v_bds_b,
                                'bd_scoped_after',  v_bds_a,
                                'input_fp_before',  v_in_fp_b,
                                'input_fp_after',   v_in_fp_a,
                                'input_drift',      v_in_drift,
                                'bd_open',          to_jsonb(v_bd_open),
                                'bd_inserted',      to_jsonb(v_bd_ins),
                                'bd_updated',       to_jsonb(v_bd_upd),
                                'bd_closed_stale',  to_jsonb(v_bd_cls),
                                'engine_fp',        to_jsonb(v_eng_fp),
                                'compose_fp',       to_jsonb(v_cmp_fp),
                                'stitch_fp',        to_jsonb(v_stt_fp),
                                'base_run_ids',     to_jsonb(v_base_id),
                                'planned_run_ids',  to_jsonb(v_plan_id),
                                'stitch_run_ids',   to_jsonb(v_stit_id),
                                'assertions_skipped', v_ns),
              p_detail     => v_detail,
              p_note       => COALESCE(p_note, 'PRD-110 STEP 7 S4 pipeline chaos'),
              p_driver     => 'sql',
              p_n_pass     => v_np,
              p_n_fail     => v_nf);
  END IF;

  RETURN jsonb_build_object(
    'suite',         'S4',
    'stress_run_id', v_id,
    'passed',        v_passed,
    'n_pass',        v_np,
    'n_fail',        v_nf,
    'n_skip',        v_ns,
    'runs',          p_runs,
    'total_ms',      v_total_ms,
    'per_run_ms',    to_jsonb(v_ms),
    'plan_date',     p_plan_date,
    'detail',        v_detail);
END
$fn$;

COMMENT ON FUNCTION golden.stress_s4_v1(date, integer, integer, boolean, boolean, text) IS
  'PRD-110 STEP 7 S4: pipeline chaos - run_pipeline_v3 p_runs times on one synthetic '
  'date inside ONE transaction, proving every engine in the chain (engine_add_pod_v3 -> '
  'compose_plan_with_edits_v3 -> stitch_v3 -> record_blocked_demand_v3) is idempotent '
  'and emits no duplicate lines. Idempotence here means CONTENT EQUALITY PER run_id, '
  'never row-count stability: the shadow tables are run_id-keyed and each engine mints '
  'a fresh uuid per call, so N runs legitimately produce N generations (S-199). Plants '
  'the whole fleet through pick_machine_manually (Article 1/3 - S4 issues NO raw SQL '
  'against any plan table); a subset plant is vacuous because compose drops the all-qty-0 '
  'output and stitch never runs. 32 assertions: three md5 content fingerprints identical '
  'across generations, generation distinctness, full non-vacuity, no duplicate leg keys, '
  'LAW 5 qty-0 explainability, LAW 11 Gate-0 confirm, blocked_demand UNIQUE-index '
  'idempotence (insert once, re-stamp thereafter, open count never moves), and the '
  'ADR 8 obligation-3 tripwire on absolute live-table counts. Guarded to the synthetic '
  '2030+ band and refuses any golden fixture plan_date (LAW 12).';

-- INVOKER by default, matching golden.record_stress, stress_s1_v1 and stress_s6_v1.
-- No grants: golden.* is operator-only, reached through the service role.
REVOKE ALL ON FUNCTION golden.stress_s4_v1(date, integer, integer, boolean, boolean, text) FROM PUBLIC;
