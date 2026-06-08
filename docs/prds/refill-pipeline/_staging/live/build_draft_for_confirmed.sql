CREATE OR REPLACE FUNCTION public.build_draft_for_confirmed(p_plan_date date DEFAULT (CURRENT_DATE + 1))
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
  v_auto_conf jsonb;
  v_add       jsonb;
  v_swap      jsonb;
  v_final     jsonb;
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

  -- AUTO-CONFIRM (refill fix 2026-06-07): drafts are non-committal; real gates are approve + stitch.
  -- Canonical writer, idempotent, service-role bypass for the cron. Kills the Gate-0 deadlock.
  v_auto_conf := public.confirm_machines_to_visit(p_plan_date);

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
    RETURN jsonb_build_object('status', 'awaiting_confirmation',
      'plan_date', p_plan_date, 'confirmed', v_confirmed, 'picked', v_picked);
  END;

  IF v_included = 0 THEN
    RETURN jsonb_build_object('status', 'no_included_machines',
      'plan_date', p_plan_date, 'confirmed', v_confirmed);
  END IF;

  v_add   := engine_add_pod(p_plan_date, 14);
  v_swap  := engine_swap_pod(p_plan_date, 2, 0.30, 14);
  -- STAGE 2c (refill fix 2026-06-07): materialize pod_refill_plan so the FE "Load draft" has rows.
  v_final := engine_finalize_pod(p_plan_date);

  RETURN jsonb_build_object(
    'status', 'draft_ready',
    'plan_date', p_plan_date,
    'machines_picked', v_picked,
    'machines_confirmed', v_confirmed,
    'machines_included', v_included,
    'auto_confirmed', v_auto_conf,
    'stage_2a', v_add,
    'stage_2b', v_swap,
    'stage_2c', v_final
  );
END;
$function$;
