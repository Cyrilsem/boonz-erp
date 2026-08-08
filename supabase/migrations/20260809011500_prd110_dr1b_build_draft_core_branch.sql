-- PRD-110 DR-1b · leg 161 · Object 4 of 4
-- _build_draft_core_v3 — the HALT becomes a BRANCH.
--
-- DR-1 (leg 160) put a guard in the live nightly producer whose only move was to stop: while
-- any cluster was authoritative for v3, the WHOLE fleet went unplanned. This replaces that with
-- the real thing — v19 plans the clusters it still owns, v3 plans the flipped ones, on one
-- plan_date.
--
-- ⛔ cutover_block_reason_v3 IS NOT TOUCHED. Fixture 74 seq 13 pins that this builder calls it;
--    seq 65/66 pin its fail-open WHEN OTHERS handler. Its body is byte-identical after this
--    migration. Only the builder's RESPONSE to `blocked` changed: branch, not halt.
--    ⚠️ Its message string still says "or ship DR-1b", which is now stale. It is no longer
--    reachable through this builder (the halt that returned it is gone) and is only visible to
--    a direct caller. Left byte-untouched deliberately rather than risk a 53-assertion fixture
--    banked one leg ago. Raised as S-313 with the one-line fix.
--
-- ⭐ FLAG-OFF PROOF: with 0 of 10 clusters authoritative, cutover_block_reason_v3 returns
--    blocked=false, the IF is never taken, engine_add_pod_v3 and promote_v3_shadow_to_live_v3
--    are never called from here, and the only surviving change is that engine_add_pod is
--    invoked one line earlier than before. Fixture 75 pins pod_refills byte-identical by md5.

CREATE OR REPLACE FUNCTION public._build_draft_core_v3(p_plan_date date, p_repick boolean, p_auto_confirm boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '1200000'
AS $function$
DECLARE
  v_user_id   uuid;
  v_picked    int;
  v_confirmed int;
  v_included  int;
  v_repicked  boolean := false;
  v_auto_conf jsonb;
  v_picks     jsonb;
  v_add       jsonb;
  v_add_v3    jsonb;
  v_promo     jsonb;
  v_swap      jsonb;
  v_final     jsonb;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id AND up.role IN ('operator_admin', 'superadmin')
  ) THEN
    RETURN jsonb_build_object('status', 'error',
      'message', 'unauthorized: requires operator_admin or superadmin');
  END IF;
  IF p_plan_date IS NULL THEN RAISE EXCEPTION 'p_plan_date required'; END IF;

  -- PRD-035 WS-E calendar. CS DECISION D-35: the rule is NOT restated here. Stage 1 asks
  -- is_refill_planning_day_v3 by name, which is the same object run_nightly_shadow_v3 asks,
  -- so the two cannot drift apart (Article 16: the illegal copy is retired, not shadowed).
  -- Safe as a straight swap only because the NULL-date RAISE above already discharges the
  -- helper's extra IS NOT NULL guard; golden fixture 61 pins the agreement over a full week.
  IF NOT public.is_refill_planning_day_v3(p_plan_date) THEN
    RETURN jsonb_build_object('status', 'skipped_saturday', 'plan_date', p_plan_date,
      'message', 'Saturday is a delivery day; no refill plan is generated (PRD-035 WS-E calendar)');
  END IF;

  -- LAW 12 guard, preserved verbatim from v1: never regenerate a live plan.
  IF EXISTS (SELECT 1 FROM public.pod_refill_plan
              WHERE plan_date = p_plan_date AND status IN ('approved','stitched'))
     OR EXISTS (SELECT 1 FROM public.refill_dispatching WHERE dispatch_date = p_plan_date) THEN
    RETURN jsonb_build_object('status', 'refused_live_plan', 'plan_date', p_plan_date,
      'message', 'plan already approved/stitched/dispatched; use edit RPCs');
  END IF;

  IF p_repick THEN
    PERFORM public.pick_machines_for_refill(p_plan_date);
    v_repicked := true;
  END IF;

  -- THE P0.3 CHANGE. v1 called this unconditionally, which is the auto-fallback CS forbade.
  IF p_auto_confirm THEN
    v_auto_conf := public.confirm_machines_to_visit(p_plan_date);
  ELSE
    v_auto_conf := jsonb_build_object('status', 'skipped_manual_gate', 'confirmed_now', 0,
      'message', 'Gate 0 is manual: CS confirms the pick list, no auto-confirm (CS decision #1)');
  END IF;

  SELECT
    COUNT(*) FILTER (WHERE status = 'picked'),
    COUNT(*) FILTER (WHERE status IN ('picked','cs_added') AND confirmed_at IS NOT NULL),
    COUNT(*) FILTER (WHERE status IN ('picked','cs_added') AND confirmed_at IS NOT NULL AND COALESCE(is_included, true) = true)
  INTO v_picked, v_confirmed, v_included
  FROM public.machines_to_visit
  WHERE plan_date = p_plan_date;

  BEGIN
    PERFORM public._assert_gate_zero(p_plan_date);
  EXCEPTION WHEN OTHERS THEN
    -- BUILD SPEC P0.3: "8pm advisory must render the 'awaiting your confirmation' state with
    -- the pick list." v1 returned only two counts, so the advisory had nothing to render.
    SELECT jsonb_agg(jsonb_build_object(
             'machine_id',     mtv.machine_id,
             'official_name',  mtv.official_name,
             'priority_score', mtv.priority_score,
             'picked_reasons', mtv.picked_reasons,
             'venue_group',    mtv.venue_group,
             'service_track',  mtv.service_track,
             'is_included',    COALESCE(mtv.is_included, true)
           ) ORDER BY mtv.priority_score DESC NULLS LAST, mtv.official_name)
      INTO v_picks
      FROM public.machines_to_visit mtv
     WHERE mtv.plan_date = p_plan_date AND mtv.status = 'picked' AND mtv.confirmed_at IS NULL;

    RETURN jsonb_build_object(
      'status',          'awaiting_confirmation',
      'plan_date',       p_plan_date,
      'repicked',        v_repicked,
      'confirmed',       v_confirmed,
      'picked',          v_picked,
      'awaiting_count',  COALESCE(jsonb_array_length(v_picks), 0),
      'pick_list',       COALESCE(v_picks, '[]'::jsonb),
      'auto_confirm',    p_auto_confirm,
      'next_action',     'CS confirms the pick list (confirm_machines_to_visit / pick_machine_manually / unpick_machine_to_visit), then build_confirmed_now_v3(plan_date) - or wait for the next cron cycle.'
    );
  END;

  IF v_included = 0 THEN
    RETURN jsonb_build_object('status', 'no_included_machines',
      'plan_date', p_plan_date, 'confirmed', v_confirmed);
  END IF;

  -- ── PRD-110 DR-1: the per-cluster cutover guard. Flag-off = unreachable. ──────
  -- Placed HERE deliberately: everything above (calendar, LAW-12 live-plan guard, repick,
  -- Gate-0 advisory) still runs, so a flipped cluster costs the PLAN and never the advisory.
  -- cutover_block_reason_v3 fails OPEN, so this can never halt the plan because IT broke.
  -- ── PRD-110 DR-1b: the HALT became a BRANCH. ─────────────────────────────────
  -- DR-1 could only stop: while any cluster was authoritative for v3 the whole fleet went
  -- unplanned. Correct and loud, and useless as a cutover. DR-1b makes the flip actually
  -- plan that cluster with v3 and everyone else with v19, on the same plan_date.
  --
  -- cutover_block_reason_v3 is still CALLED and its body is byte-untouched (fixture 74 seq 13
  -- pins the call, seq 65/66 pin the fail-open handler). What changed is what this builder
  -- DOES with `blocked`: it is now the BRANCH predicate, not a halt. It still fails OPEN, so
  -- a failure of its own read leaves every cluster on v19 and the plan is built as before.
  DECLARE v_cut jsonb; BEGIN
    v_cut := public.cutover_block_reason_v3();

    -- v19 FIRST, and it is now machine-scoped: its pod_refills DELETE and its `picked` CTE
    -- both skip v3-authoritative machines, so it can no longer wipe what v3 is about to write.
    v_add := engine_add_pod(p_plan_date, 14);

    IF COALESCE((v_cut->>'blocked')::boolean, false) THEN
      -- ⭐ v3 shadow-plans the WHOLE FLEET here, not just the flipped clusters. Scoping the
      --    v3 READ to authoritative machines would be the obvious symmetry and it would
      --    deadlock the cutover on its own evidence: with 0 clusters flipped v3 would plan
      --    nothing, engine_forecast_error_v3 would stop accruing, and no cluster could ever
      --    clear the readiness gate. v3's SHADOW scope is the fleet; v3's LIVE scope is the
      --    flipped clusters. That asymmetry IS the design.
      v_add_v3 := public.engine_add_pod_v3(p_plan_date, 14);

      -- ...and only the flipped clusters' rows are published into the live table. This
      -- REFUSES rather than publishing an empty plan if the date has no v3 shadow run.
      v_promo  := public.promote_v3_shadow_to_live_v3(p_plan_date);
    END IF;
  END;

  v_swap  := engine_swap_pod(p_plan_date, 2, 0.30, 14);
  v_final := engine_finalize_pod(p_plan_date);

  RETURN jsonb_build_object(
    'status',             'draft_ready',
    'plan_date',          p_plan_date,
    'repicked',           v_repicked,
    'auto_confirm',       p_auto_confirm,
    'machines_picked',    v_picked,
    'machines_confirmed', v_confirmed,
    'machines_included',  v_included,
    'auto_confirmed',     v_auto_conf,
    'stage_2a',           v_add,
    'stage_2a_v3',        v_add_v3,
    'stage_2a_promote',   v_promo,
    'stage_2b',           v_swap,
    'stage_2c',           v_final,
    'coverage',           public.check_refill_coverage(p_plan_date)
  );
END;
$function$
;
-- ── post-image guards ────────────────────────────────────────────────────────────
DO $guard$
DECLARE
  v_src   text;
  v_gsrc  text;
BEGIN
  SELECT prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = '_build_draft_core_v3';
  IF v_src IS NULL THEN RAISE EXCEPTION 'DR-1b: _build_draft_core_v3 missing after replace'; END IF;

  -- The branch landed...
  IF position('promote_v3_shadow_to_live_v3' in v_src) = 0 THEN
    RAISE EXCEPTION 'DR-1b: the promotion call did not land in the builder';
  END IF;
  IF position('engine_add_pod_v3(p_plan_date, 14)' in v_src) = 0 THEN
    RAISE EXCEPTION 'DR-1b: the v3 shadow call did not land in the builder';
  END IF;

  -- ...and the halt is GONE.
  IF position('refused_cutover_not_implemented' in v_src) > 0 THEN
    RAISE EXCEPTION 'DR-1b: the cutover HALT survived; the builder can still refuse the fleet';
  END IF;

  -- Fixture 74 seq 13: the builder must still CALL the gate.
  IF position('cutover_block_reason_v3' in v_src) = 0 THEN
    RAISE EXCEPTION 'DR-1b: the builder stopped calling cutover_block_reason_v3 (fixture 74 seq 13)';
  END IF;

  -- Fixture 74 seq 21 / LAW 12: the live-plan guard must be untouched.
  IF position('refused_live_plan' in v_src) = 0 THEN
    RAISE EXCEPTION 'DR-1b: the LAW 12 live-plan guard was disturbed (fixture 74 seq 21)';
  END IF;

  -- LAW 11: manual Gate 0, no auto-fallback.
  IF position('skipped_manual_gate' in v_src) = 0 THEN
    RAISE EXCEPTION 'DR-1b: the manual Gate-0 branch was disturbed (LAW 11)';
  END IF;

  -- Fixture 74 seq 65/66: the gate's fail-open handler must be byte-untouched.
  SELECT prosrc INTO v_gsrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'cutover_block_reason_v3';
  IF position('WHEN OTHERS' in v_gsrc) = 0 OR position('degraded' in v_gsrc) = 0 THEN
    RAISE EXCEPTION 'DR-1b: cutover_block_reason_v3 fail-open handler was disturbed';
  END IF;

  RAISE NOTICE 'DR-1b: builder branched; halt removed, gate still called, LAW 11/12 intact';
END $guard$;
