-- PRD-110 STEP 7 · S1 — full-fleet shadow run (leg 119)
--
-- Goal-command S1: "full-fleet shadow run, all machines, one date — runtime < 10 min,
-- zero errors".
--
-- ============================================================================
-- DESIGN CORRECTION vs PRD-110-STEP7-STRESS-DESIGN.md §S1 (re-derived live, LAW 13)
-- ============================================================================
-- The design says "clean-on-entry the four shadow/date-scoped tables". Measured live:
-- `pod_refills_shadow` carries `tg_pod_refills_shadow_append_only` (BEFORE DELETE OR
-- UPDATE), which raises 42501 on any DELETE — ADR-shadow-plan-tables §5.1. A
-- clean-on-entry S1 would therefore refuse on its SECOND run and could never be
-- re-run. `shadow_runner_log_v3` is likewise append-only for UPDATE.
--
-- S1 therefore uses the BANK-AND-DIFF idiom, which is what S-199 already established
-- for S4: the shadow tables are `run_id`-keyed, so a re-run legitimately mints a NEW
-- generation rather than replacing the old one. S1 banks the run_id set and the
-- `shadow_runner_log_v3` id watermark BEFORE the run and measures only what the run
-- itself minted. NOTHING is cleaned on entry: the only plan-table write S1 makes goes
-- through `pick_machine_manually`, which is itself an upsert (see THIRD CORRECTION).
--
-- SECOND CORRECTION (rewritten at Cody review, leg 119 — the earlier draft of this
-- comment was WRONG and would have misled a future leg):
-- `run_nightly_shadow_v3` STEP 1 calls `engine_add_pod_v3` DIRECTLY, and that
-- function's pick predicate is measured to be
-- `plan_date = p_plan_date AND status IN ('picked','cs_added')` in all five of its
-- references. But the engine ALSO `PERFORM public._assert_gate_zero(p_plan_date)`,
-- which raises `check_violation` on any row with `status='picked' AND confirmed_at
-- IS NULL`. So the confirm is NOT irrelevant to v3 — a `'picked'` plant that forgot
-- `confirmed_at` would be refused as `blocked_gate0`.
-- ⭐ This plant sidesteps the hazard entirely by going through the canonical Gate-0
-- manual-add writer, which stamps `status='cs_added'` + `confirmed_at=now()`. Under
-- `cs_added` the gate-zero predicate cannot match at all.
--
-- THIRD CORRECTION (Cody, Article 1/3): the plant must NOT raw-INSERT
-- `machines_to_visit`. RPC_REGISTRY designates that table protected with a canonical
-- writer set, and carries a standing Cody condition that the first consumer turning a
-- ranking into a `machines_to_visit` row is a new class-(b) review. S1 therefore calls
-- `pick_machine_manually(plan_date, machine_id, reason)` — DEFINER, service-role
-- bypass on NULL `auth.uid()`, sets `app.via_rpc` + `app.rpc_name` (Articles 4 and 8),
-- and idempotent via `ON CONFLICT (plan_date, machine_id)`. Because it upserts, the
-- clean-on-entry DELETE is unnecessary and is gone: S1 now writes NO raw SQL against
-- any plan table. LAW 11 is honoured more exactly than by a synthesised 'picked' row.
--
-- ============================================================================
-- MEASURED PREMISES (2026-08-04, all re-derived live this leg)
-- ============================================================================
--   fleet (include_in_refill AND status='Active') = 31 · v_shelf_state = 656 rows
--   2030-11-01..06 band free: machines_to_visit 0 · refill_plan_output 0 ·
--     pod_refill_plan 0 · pod_refills_shadow 0 · shadow_runner_log_v3 0 ·
--     golden.fixtures with a plan_date in 2030-11 = 0
--   run_nightly_shadow_v3(p_plan_date date, p_days_cover int, p_settle_limit int, p_note text)
--   engine_add_pod_v3 role gate: NULL auth.uid() = trusted server-side caller
--   engine_add_pod_v3 does NOT reference v_slot_binding_drift or
--     v_facing_performance_v3 — S-209's 23.6 s materialisation is not on the STEP-1 path
--   engine_forecast_error_v3 settle backlog = 0, so STEP 3 is empty even before
--     p_settle_limit clamps it
--   is_refill_planning_day_v3('2030-11-01') = true — so a zero-pick run classifies as
--     'no_picks', NOT 'skipped_calendar'. The vacuity detector works on this date.
--
-- LAW 12: p_plan_date is guarded to the synthetic 2030+ band and refused if it
-- collides with any golden fixture's plan_date. Live plan dates are unreachable.
-- ADR §8 obligation 3: absolute (NOT date-scoped) counts of pod_refills,
-- pod_refill_plan and refill_plan_output are pinned before and after.
-- S-197: this plant does NOT set app.via_rpc.

CREATE OR REPLACE FUNCTION golden.stress_s1_v1(
  p_plan_date  date    DEFAULT '2030-11-01'::date,
  p_days_cover integer DEFAULT 7,
  p_record     boolean DEFAULT true,
  p_note       text    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'golden', 'public', 'pg_temp'
AS $fn$
DECLARE
  v_started     timestamptz := clock_timestamp();
  v_t0          timestamptz;
  v_dur_ms      integer;

  v_fleet       integer;
  v_planted     integer;
  v_scope       integer;
  v_mid         uuid;
  v_unconfirmed integer;

  v_srl_wm      bigint;
  v_runs_before uuid[];
  v_new_runs    uuid[];
  v_n_new_runs  integer;

  v_res         jsonb;
  v_lines       integer := 0;
  v_machines    integer := 0;
  v_units       bigint  := 0;
  v_qty0_nocl   integer := 0;
  v_null_mach   integer := 0;

  v_err_steps   integer;
  v_summary_st  text;
  v_engine_st   text;
  v_measure_st  text;

  v_pr_b bigint; v_pr_a bigint;
  v_pp_b bigint; v_pp_a bigint;
  v_ro_b bigint; v_ro_a bigint;

  v_detail      jsonb;
  v_np          integer;
  v_nf          integer;
  v_passed      boolean;
  v_id          uuid;
BEGIN
  ---------------------------------------------------------------- LAW 12 guards
  IF p_plan_date IS NULL OR p_plan_date < '2030-01-01'::date THEN
    RAISE EXCEPTION 'stress_s1_v1: p_plan_date must be in the synthetic 2030+ band, got % '
                    '(LAW 12 - never plant on a live plan date)', p_plan_date;
  END IF;

  IF EXISTS (SELECT 1 FROM golden.fixtures f WHERE f.plan_date = p_plan_date) THEN
    RAISE EXCEPTION 'stress_s1_v1: % is a golden fixture plan_date; the fixture cleans on '
                    'entry and would destroy the stress run', p_plan_date;
  END IF;

  IF p_days_cover IS NULL OR p_days_cover < 1 OR p_days_cover > 60 THEN
    RAISE EXCEPTION 'stress_s1_v1: p_days_cover must be 1..60, got %', p_days_cover;
  END IF;

  ------------------------------------------------------- BANK (append-only safe)
  -- pod_refills_shadow cannot be cleaned (ADR §5.1). Bank its run_id set for the
  -- date and the shadow_runner_log_v3 id watermark, then measure only the delta.
  SELECT COALESCE(array_agg(DISTINCT s.run_id), ARRAY[]::uuid[])
    INTO v_runs_before
    FROM public.pod_refills_shadow s
   WHERE s.plan_date = p_plan_date;

  SELECT COALESCE(max(l.id), 0) INTO v_srl_wm FROM public.shadow_runner_log_v3 l;

  -- ADR §8 obligation 3 tripwire: ABSOLUTE counts, deliberately not date-scoped.
  SELECT count(*) INTO v_pr_b FROM public.pod_refills;
  SELECT count(*) INTO v_pp_b FROM public.pod_refill_plan;
  SELECT count(*) INTO v_ro_b FROM public.refill_plan_output;

  SELECT count(*) INTO v_fleet
    FROM public.machines m
   WHERE m.include_in_refill AND m.status = 'Active';

  ---------------------------------------------------------------------- PLANT
  -- Article 1/3: go through the canonical Gate-0 manual-add writer, never raw SQL.
  -- It upserts on (plan_date, machine_id), so the suite is re-runnable with no DELETE.
  FOR v_mid IN
    SELECT m.machine_id FROM public.machines m
     WHERE m.include_in_refill AND m.status = 'Active'
     ORDER BY m.machine_id
  LOOP
    PERFORM public.pick_machine_manually(
              p_plan_date, v_mid, 'PRD-110 STEP 7 S1 full-fleet shadow stress');
  END LOOP;

  -- Measure the plant from the TABLE, not from ROW_COUNT: a stale row left by an
  -- earlier run of a since-changed fleet must show up as a miscount, not be masked
  -- by counting only the rows this call happened to touch.
  SELECT count(*) INTO v_planted
    FROM public.machines_to_visit
   WHERE plan_date = p_plan_date AND status IN ('picked','cs_added');

  -- Gate 0 must be genuinely satisfied, not merely unreachable (LAW 11).
  SELECT count(*) INTO v_unconfirmed
    FROM public.machines_to_visit
   WHERE plan_date = p_plan_date AND status = 'picked' AND confirmed_at IS NULL;

  -- Scope the engine is expected to cover, measured the same way the engine does.
  SELECT count(*) INTO v_scope
    FROM public.v_shelf_state vs
   WHERE vs.machine_id IN (SELECT machine_id FROM public.machines_to_visit
                            WHERE plan_date = p_plan_date AND status IN ('picked','cs_added'));

  ------------------------------------------------------------------ THE RUN
  -- p_settle_limit => 0 is MANDATORY (S-199): STEP 3 loops other plan_dates, which
  -- makes the timing non-hermetic and the write set unbounded.
  v_t0  := clock_timestamp();
  v_res := public.run_nightly_shadow_v3(p_plan_date, p_days_cover, 0,
                                        COALESCE(p_note, 'PRD-110 S1'));
  v_dur_ms := (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int;

  --------------------------------------------------------------------- MEASURE
  SELECT COALESCE(array_agg(DISTINCT s.run_id), ARRAY[]::uuid[])
    INTO v_new_runs
    FROM public.pod_refills_shadow s
   WHERE s.plan_date = p_plan_date
     AND NOT (s.run_id = ANY (v_runs_before));
  v_n_new_runs := COALESCE(array_length(v_new_runs, 1), 0);

  IF v_n_new_runs > 0 THEN
    SELECT count(*), count(DISTINCT s.machine_id), COALESCE(sum(s.qty), 0),
           count(*) FILTER (WHERE s.qty = 0 AND s.clamp_reason IS NULL),
           count(*) FILTER (WHERE s.machine_id IS NULL OR s.shelf_id IS NULL)
      INTO v_lines, v_machines, v_units, v_qty0_nocl, v_null_mach
      FROM public.pod_refills_shadow s
     WHERE s.plan_date = p_plan_date
       AND s.run_id = ANY (v_new_runs);
  END IF;

  SELECT count(*) FILTER (WHERE l.status = 'error'),
         max(l.status) FILTER (WHERE l.step = 'summary'),
         max(l.status) FILTER (WHERE l.step = 'engine'),
         max(l.status) FILTER (WHERE l.step = 'measure')
    INTO v_err_steps, v_summary_st, v_engine_st, v_measure_st
    FROM public.shadow_runner_log_v3 l
   WHERE l.id > v_srl_wm AND l.plan_date = p_plan_date;

  SELECT count(*) INTO v_pr_a FROM public.pod_refills;
  SELECT count(*) INTO v_pp_a FROM public.pod_refill_plan;
  SELECT count(*) INTO v_ro_a FROM public.refill_plan_output;

  ------------------------------------------------------------------ ASSERTIONS
  SELECT jsonb_agg(jsonb_build_object(
           'seq', t.seq, 'name', t.name, 'expect', t.expect,
           'actual', t.actual, 'passed', t.passed) ORDER BY t.seq),
         count(*) FILTER (WHERE t.passed),
         count(*) FILTER (WHERE NOT t.passed)
    INTO v_detail, v_np, v_nf
    FROM (VALUES
      -- the headline requirement
      ( 1, 'runtime_under_10_min',      '< 600000 ms',
           v_dur_ms::text,                              v_dur_ms < 600000),
      ( 2, 'zero_error_steps',          '0',
           v_err_steps::text,                           v_err_steps = 0),
      ( 3, 'summary_status_ok',         'ok',
           COALESCE(v_summary_st,'<none>'),             v_summary_st = 'ok'),
      ( 4, 'engine_status_ok',          'ok',
           COALESCE(v_engine_st,'<none>'),              v_engine_st = 'ok'),
      ( 5, 'measure_status_ok_or_skip', 'ok|skipped',
           COALESCE(v_measure_st,'<none>'),             v_measure_st IN ('ok','skipped')),
      -- NON-VACUITY (the S-132 trap: a no_picks run finishing in 2 s is not a pass)
      ( 6, 'plant_covers_whole_fleet',  v_fleet::text,
           v_planted::text,                             v_planted = v_fleet AND v_fleet > 0),
      ( 7, 'exactly_one_new_run_id',    '1',
           v_n_new_runs::text,                          v_n_new_runs = 1),
      ( 8, 'lines_written_gt_zero',     '> 0',
           v_lines::text,                               v_lines > 0),
      ( 9, 'machines_covered_eq_fleet', v_fleet::text,
           v_machines::text,                            v_machines = v_fleet),
      (10, 'shelf_scope_gt_zero',       '> 0',
           v_scope::text,                               v_scope > 0),
      -- LAW 5 sibling: a silent qty-0 with no clamp_reason is a build failure
      (11, 'no_unexplained_qty0',       '0',
           v_qty0_nocl::text,                           v_qty0_nocl = 0),
      (12, 'no_null_keys_in_output',    '0',
           v_null_mach::text,                           v_null_mach = 0),
      -- ADR §8 obligation 3: SHADOW, DON'T SWITCH (LAW 4). Absolute counts.
      (13, 'live_pod_refills_untouched', v_pr_b::text,
           v_pr_a::text,                                v_pr_a = v_pr_b),
      (14, 'live_pod_refill_plan_untouched', v_pp_b::text,
           v_pp_a::text,                                v_pp_a = v_pp_b),
      (15, 'live_refill_plan_output_untouched', v_ro_b::text,
           v_ro_a::text,                                v_ro_a = v_ro_b),
      -- LAW 11: Gate 0 satisfied by a real manual confirm, not bypassed.
      (16, 'gate0_no_unconfirmed_picks', '0',
           v_unconfirmed::text,                         v_unconfirmed = 0)
    ) AS t(seq, name, expect, actual, passed);

  v_passed := (v_nf = 0);

  ---------------------------------------------------------------------- RECORD
  IF p_record THEN
    v_id := golden.record_stress(
              p_suite      => 'S1',
              p_passed     => v_passed,
              p_started_at => v_started,
              p_metric     => jsonb_build_object(
                                'plan_date',        p_plan_date,
                                'days_cover',       p_days_cover,
                                'settle_limit',     0,
                                'run_duration_ms',  v_dur_ms,
                                'fleet',            v_fleet,
                                'machines_planted', v_planted,
                                'shelf_scope',      v_scope,
                                'new_run_ids',      v_n_new_runs,
                                'lines',            v_lines,
                                'machines_covered', v_machines,
                                'units',            v_units,
                                'runner_result',    v_res),
              p_detail     => v_detail,
              p_note       => COALESCE(p_note, 'PRD-110 STEP 7 S1 full-fleet shadow run'),
              p_driver     => 'sql',
              p_n_pass     => v_np,
              p_n_fail     => v_nf);
  END IF;

  RETURN jsonb_build_object(
    'suite',            'S1',
    'stress_run_id',    v_id,
    'passed',           v_passed,
    'n_pass',           v_np,
    'n_fail',           v_nf,
    'run_duration_ms',  v_dur_ms,
    'plan_date',        p_plan_date,
    'fleet',            v_fleet,
    'lines',            v_lines,
    'machines_covered', v_machines,
    'new_run_ids',      v_new_runs,
    'detail',           v_detail);
END
$fn$;

COMMENT ON FUNCTION golden.stress_s1_v1(date, integer, boolean, text) IS
  'PRD-110 STEP 7 S1: full-fleet shadow run on one synthetic date. Plants the whole '
  'include_in_refill/Active fleet through the canonical Gate-0 writer '
  'pick_machine_manually (Article 1/3 - S1 issues NO raw SQL against any plan table; '
  'that RPC upserts, so no clean-on-entry is needed), fires run_nightly_shadow_v3 with '
  'p_settle_limit=0 (S-199), and measures only the run_id generation the run itself '
  'minted - pod_refills_shadow is append-only per ADR §5.1 so it can never be cleaned. '
  '16 assertions: runtime < 10 min, zero error steps, full non-vacuity (fleet coverage, '
  'lines > 0, one new run_id), LAW 5 qty-0 explainability, LAW 11 Gate-0 confirm, and the '
  'ADR §8 obligation-3 tripwire on absolute live-table counts. '
  'Guarded to the synthetic 2030+ band and refuses any golden fixture plan_date (LAW 12).';

-- INVOKER by default, matching golden.record_stress and golden.stress_s6_v1.
-- No grants: golden.* is operator-only, reached through the service role.
REVOKE ALL ON FUNCTION golden.stress_s1_v1(date, integer, boolean, text) FROM PUBLIC;
