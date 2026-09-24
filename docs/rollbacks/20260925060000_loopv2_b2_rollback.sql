-- Rollback capture for 20260925060000_loopv2_b2_pick_machines_v12.sql
-- Prior live body of _build_draft_core_v3 (before the picker_config switch was wired in).
-- pick_machines_v12 and pick_rhythm_params are new objects added by that migration; rollback for
-- those is DROP FUNCTION public.pick_machines_v12(date, int) and DROP TABLE
-- public.pick_rhythm_params, plus ALTER TABLE public.machines_to_visit_shadow ALTER COLUMN
-- building_id TYPE uuid USING building_id::uuid (only valid while that table is still empty).

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

  DECLARE v_cut jsonb; BEGIN
    v_cut := public.cutover_block_reason_v3();

    v_add := engine_add_pod(p_plan_date, 14);

    IF COALESCE((v_cut->>'blocked')::boolean, false) THEN
      v_add_v3 := public.engine_add_pod_v3(p_plan_date, 14);
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
$function$;
