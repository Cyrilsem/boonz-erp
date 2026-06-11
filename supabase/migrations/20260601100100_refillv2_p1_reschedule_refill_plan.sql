-- Refill System v2 / Phase 1 (F1) — reschedule_refill_plan: move a whole plan between dates.
--
-- A "plan" is the visit list + confirmation state (machines_to_visit) AND the draft rows
-- (pod_refill_plan), both keyed leading on plan_date. Rescheduling moves BOTH coherently so the
-- confirm gate (_assert_gate_zero) and the 8pm builder still line up on the new date. Draft-only
-- moves were rejected (they leave the target date with rows but no visit list / confirm gate).
--
-- Archive-safe: this is a key move (UPDATE plan_date), never a delete. Guarded so it cannot
-- clobber an occupied target date, and cannot move a plan that is already physically dispatched.
-- NOT YET APPLIED.

CREATE OR REPLACE FUNCTION public.reschedule_refill_plan(
  p_from_date date,
  p_to_date   date,
  p_reason    text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id  uuid;
  v_locked   int;
  v_tgt_mtv  int;
  v_tgt_plan int;
  v_moved_mtv  int;
  v_moved_plan int;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'reschedule_refill_plan', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id AND up.role = ANY(ARRAY['operator_admin','superadmin'])
  ) THEN
    RAISE EXCEPTION 'reschedule_refill_plan: caller % lacks operator_admin/superadmin', v_user_id;
  END IF;

  IF p_from_date IS NULL OR p_to_date IS NULL THEN
    RAISE EXCEPTION 'p_from_date and p_to_date required';
  END IF;
  IF p_from_date = p_to_date THEN
    RAISE EXCEPTION 'p_from_date and p_to_date must differ';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>= 10 chars)';
  END IF;

  -- Guard 1: source must not be dispatched (would orphan refill_plan_output / dispatching).
  SELECT COUNT(*) INTO v_locked
  FROM public.refill_plan_output rpo
  WHERE rpo.plan_date = p_from_date
    AND rpo.operator_status IS DISTINCT FROM 'pending';
  IF v_locked > 0 THEN
    RAISE EXCEPTION 'reschedule refused: % refill_plan_output row(s) for % past pending (already dispatched)', v_locked, p_from_date;
  END IF;

  -- Guard 2: target date must be empty in both tables (no clobber).
  SELECT COUNT(*) INTO v_tgt_mtv
  FROM public.machines_to_visit WHERE plan_date = p_to_date;
  SELECT COUNT(*) INTO v_tgt_plan
  FROM public.pod_refill_plan
  WHERE plan_date = p_to_date AND status NOT IN ('voided','superseded');
  IF v_tgt_mtv > 0 OR v_tgt_plan > 0 THEN
    RAISE EXCEPTION 'reschedule refused: target % already has % machines_to_visit and % live pod_refill_plan row(s). Void or clear it first.', p_to_date, v_tgt_mtv, v_tgt_plan;
  END IF;

  -- Move the visit list (preserves status / confirmed_at / is_included).
  UPDATE public.machines_to_visit
     SET plan_date = p_to_date, updated_at = now()
   WHERE plan_date = p_from_date;
  GET DIAGNOSTICS v_moved_mtv = ROW_COUNT;

  -- Move the live draft rows; terminal rows (voided/superseded) stay on the old date.
  UPDATE public.pod_refill_plan prp
     SET plan_date  = p_to_date,
         reasoning  = COALESCE(prp.reasoning, '{}'::jsonb)
                      || jsonb_build_object('rescheduled_from', p_from_date,
                                            'reschedule_reason', p_reason,
                                            'rescheduled_by', v_user_id, 'rescheduled_at', now()),
         updated_at = now()
   WHERE prp.plan_date = p_from_date
     AND prp.status IN ('draft','approved','stitched');
  GET DIAGNOSTICS v_moved_plan = ROW_COUNT;

  RETURN jsonb_build_object(
    'from_date', p_from_date, 'to_date', p_to_date,
    'machines_moved', v_moved_mtv, 'plan_rows_moved', v_moved_plan,
    'reason', p_reason);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.reschedule_refill_plan(date, date, text) TO authenticated;
