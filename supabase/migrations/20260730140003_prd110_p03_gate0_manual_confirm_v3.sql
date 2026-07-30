-- PRD-110 P0.3 - Gate 0 manual activation, wave 1 (CS decision #1: NO auto-fallback)
--
-- THE DEFECT (one line): build_draft_for_confirmed calls
--     v_auto_conf := public.confirm_machines_to_visit(p_plan_date);
-- BEFORE PERFORM public._assert_gate_zero(p_plan_date). The gate exists and engine_add_pod
-- already enforces it - the 8pm cron simply pre-satisfies it every night on CS's behalf.
-- Observed live for 2026-07-31: 10 rows, all status='picked', all confirmed_at IS NULL.
--
-- SHIPPED FLAG-OFF (LAW 4 "shadow, don't switch" + LAW 12 "the nightly advisory must still
-- work the same night"):
--   * new param gate0_require_manual_confirm DEFAULT false
--   * cron 13 is NOT repointed here - it keeps calling build_draft_for_confirmed (v1),
--     so tonight's 20:00 Dubai advisory is byte-identical.
--   * activation = 2 lines, parked as D-01 in PRD-110-PARKING-LOT.md.
--
-- Structure: one internal core + two thin public RPCs, so the 2a/2b/2c engine chain is
-- written once and cannot drift between the cron path and the on-demand path.
--
-- VERIFIED 2026-07-30 11:30 UTC on synthetic plan_date 2030-06-17, engine-free (the seeded
-- machine carries is_included=false so v_included=0 returns before stage 2a):
--   A flag ON  + unconfirmed          -> awaiting_confirmation, awaiting_count 1, pick_list 1
--   B flag ON  + build_confirmed_now  -> awaiting_confirmation
--   C after confirm_machines_to_visit -> gate passes (no_included_machines)
--   D flag OFF + unconfirmed          -> auto-confirms, gate passes  [legacy parity]
--   E flag OFF + build_confirmed_now  -> still refuses (never auto-confirms, by design)
--   driver_feedback open count 8 -> 8 (no S-08 exposure; engines never ran)

-- ---------------------------------------------------------------- 1. the flag (default OFF)
ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS gate0_require_manual_confirm boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.refill_policy_params.gate0_require_manual_confirm IS
  'PRD-110 P0.3 / CS decision 2026-07-30 #1. When true, build_draft_for_confirmed_v3 does NOT '
  'auto-confirm picked machines: the 8pm cron picks and STOPS, and the engines run only for '
  'machines CS confirmed. NO deadline fallback in wave 1. Default false = legacy behaviour.';

-- ---------------------------------------------------------------- 2. shared core
CREATE OR REPLACE FUNCTION public._build_draft_core_v3(
  p_plan_date    date,
  p_repick       boolean,
  p_auto_confirm boolean
) RETURNS jsonb
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

  -- PRD-035 WS-E: Saturday is a delivery day (no refill plan). Preserved verbatim from v1.
  IF EXTRACT(DOW FROM p_plan_date) = 6 THEN
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

  v_add   := engine_add_pod(p_plan_date, 14);
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
    'stage_2b',           v_swap,
    'stage_2c',           v_final,
    'coverage',           public.check_refill_coverage(p_plan_date)
  );
END;
$function$;

-- ---------------------------------------------------------------- 3. cron-facing RPC
CREATE OR REPLACE FUNCTION public.build_draft_for_confirmed_v3(
  p_plan_date date    DEFAULT resolve_refill_plan_date(),
  p_repick    boolean DEFAULT true
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '1200000'
AS $function$
DECLARE
  v_manual_gate boolean;
  v_out         jsonb;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'build_draft_for_confirmed_v3', true);

  SELECT COALESCE(gate0_require_manual_confirm, false) INTO v_manual_gate
    FROM public.refill_policy_params WHERE id = 1;
  v_manual_gate := COALESCE(v_manual_gate, false);

  v_out := public._build_draft_core_v3(p_plan_date, p_repick, NOT v_manual_gate);

  RETURN v_out || jsonb_build_object(
    'gate0_require_manual_confirm', v_manual_gate,
    'engine_version', 'build_draft_for_confirmed_v3');
END;
$function$;

COMMENT ON FUNCTION public.build_draft_for_confirmed_v3(date, boolean) IS
  'PRD-110 P0.3. Successor to build_draft_for_confirmed. Identical behaviour while '
  'refill_policy_params.gate0_require_manual_confirm = false. When true, picks and STOPS at '
  'status=picked/confirmed_at NULL and returns status=awaiting_confirmation WITH the pick list. '
  'No deadline fallback in wave 1 (CS decision 2026-07-30 #1).';

-- ---------------------------------------------------------------- 4. on-demand RPC
CREATE OR REPLACE FUNCTION public.build_confirmed_now_v3(
  p_plan_date date DEFAULT resolve_refill_plan_date()
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '1200000'
AS $function$
DECLARE
  v_out jsonb;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'build_confirmed_now_v3', true);

  -- Never repicks (that would churn the list CS just curated) and NEVER auto-confirms,
  -- regardless of the flag: this is the button CS presses AFTER confirming.
  v_out := public._build_draft_core_v3(p_plan_date, false, false);

  RETURN v_out || jsonb_build_object('engine_version', 'build_confirmed_now_v3');
END;
$function$;

COMMENT ON FUNCTION public.build_confirmed_now_v3(date) IS
  'PRD-110 P0.3. On-demand draft build for the machines CS has already confirmed. No repick, '
  'no auto-confirm. Returns awaiting_confirmation (with pick list) if any picked row is still '
  'unconfirmed. This is BUILD SPEC P0.3''s "or on-demand RPC build_confirmed_now_v3(plan_date)".';

REVOKE ALL ON FUNCTION public._build_draft_core_v3(date, boolean, boolean) FROM PUBLIC;
