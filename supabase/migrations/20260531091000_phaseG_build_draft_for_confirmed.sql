-- PRD-015 Phase B / AC#1 + AC#2(edge) — engine-build orchestrator that NEVER re-picks.
-- Runs the engine over CONFIRMED + INCLUDED machines only. Gate 0 is the human confirm
-- step (feedback_cron_keep_human_confirm): if unconfirmed picks exist, returns a clean
-- 'awaiting_confirmation' status (NOT an error) so the 8pm cron exits 0 with no noise.
-- Role: operator_admin/superadmin (CS: build_draft stays this tier, no warehouse).
-- Does NOT call pick_machines_for_refill. NOT YET APPLIED (files-only per PRD-015 cadence).

CREATE OR REPLACE FUNCTION public.build_draft_for_confirmed(p_plan_date date DEFAULT (CURRENT_DATE + 1))
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id   uuid;
  v_picked    int;
  v_confirmed int;
  v_included  int;
  v_add       jsonb;
  v_swap      jsonb;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'build_draft_for_confirmed', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id AND up.role IN ('operator_admin', 'superadmin')
  ) THEN
    RETURN jsonb_build_object('status', 'error',
      'message', 'unauthorized: requires operator_admin or superadmin');
  END IF;
  IF p_plan_date IS NULL THEN RAISE EXCEPTION 'p_plan_date required'; END IF;

  SELECT
    COUNT(*) FILTER (WHERE status = 'picked'),
    COUNT(*) FILTER (WHERE status IN ('picked','cs_added') AND confirmed_at IS NOT NULL),
    COUNT(*) FILTER (WHERE status IN ('picked','cs_added') AND confirmed_at IS NOT NULL AND COALESCE(is_included, true) = true)
  INTO v_picked, v_confirmed, v_included
  FROM public.machines_to_visit
  WHERE plan_date = p_plan_date;

  -- Gate 0: never auto-confirm. _assert_gate_zero RAISES (check_violation) if any picked
  -- machine is unconfirmed; convert that to a clean awaiting_confirmation status.
  BEGIN
    PERFORM public._assert_gate_zero(p_plan_date);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('status', 'awaiting_confirmation',
      'plan_date', p_plan_date, 'confirmed', v_confirmed, 'picked', v_picked);
  END;

  -- Edge case (PRD-015): every confirmed machine excluded from the route.
  IF v_included = 0 THEN
    RETURN jsonb_build_object('status', 'no_included_machines',
      'plan_date', p_plan_date, 'confirmed', v_confirmed);
  END IF;

  -- Engine build over confirmed+included machines. (engine_add_pod / engine_swap_pod
  -- honor is_included per AC#12 once their machines_to_visit read is filtered —
  -- companion migrations phaseG_engine_add_pod_is_included / _swap_.)
  v_add  := engine_add_pod(p_plan_date, 14);
  v_swap := engine_swap_pod(p_plan_date, 2, 0.30, 14);

  RETURN jsonb_build_object(
    'status', 'draft_ready',
    'plan_date', p_plan_date,
    'machines_picked', v_picked,
    'machines_confirmed', v_confirmed,
    'machines_included', v_included,
    'stage_2a', v_add,
    'stage_2b', v_swap
  );
END;
$function$;
GRANT EXECUTE ON FUNCTION public.build_draft_for_confirmed(date) TO authenticated;
