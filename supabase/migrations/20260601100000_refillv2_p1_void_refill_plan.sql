-- Refill System v2 / Phase 1 (F1) — void_refill_plan: canonical whole-plan void.
--
-- Today reject_pod_refill_rows is per-machine, only touches 'draft' rows, and reuses
-- 'superseded' (which means "replaced by a newer stitch"). Voiding an entire plan_date needs
-- its own canonical writer with a distinct terminal state, archive-only (NEVER DELETE), and a
-- guard so a plan that is already physically dispatched cannot be silently voided out from
-- under refill_plan_output / refill_dispatching.
--
-- Scope: pod_refill_plan ONLY. It does not re-pick machines_to_visit (that is reschedule's job)
-- and does not mutate refill_plan_output (its own canonical writers own that state machine) —
-- instead it REFUSES when refill_plan_output for the date is past 'pending'. NOT YET APPLIED.

-- 1) New terminal state (forward-only: drop + re-add the CHECK; Article 12).
ALTER TABLE public.pod_refill_plan DROP CONSTRAINT IF EXISTS pod_refill_plan_status_check;
ALTER TABLE public.pod_refill_plan ADD CONSTRAINT pod_refill_plan_status_check
  CHECK (status = ANY (ARRAY['draft','approved','stitched','superseded','voided']));

-- 2) Canonical writer.
CREATE OR REPLACE FUNCTION public.void_refill_plan(
  p_plan_date date,
  p_reason    text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id  uuid;
  v_locked   int;
  v_voided   int;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'void_refill_plan', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id AND up.role = ANY(ARRAY['operator_admin','superadmin'])
  ) THEN
    RAISE EXCEPTION 'void_refill_plan: caller % lacks operator_admin/superadmin', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'p_plan_date required';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>= 10 chars; voiding a plan must be explicit)';
  END IF;

  -- Refuse if the plan is already in motion downstream. refill_plan_output rows past 'pending'
  -- mean dispatching has been written; voiding pod_refill_plan here would orphan them. The
  -- operator must cancel the dispatch leg first.
  SELECT COUNT(*) INTO v_locked
  FROM public.refill_plan_output rpo
  WHERE rpo.plan_date = p_plan_date
    AND rpo.operator_status IS DISTINCT FROM 'pending';
  IF v_locked > 0 THEN
    RAISE EXCEPTION 'void refused: % refill_plan_output row(s) for % are past pending (plan is dispatched). Cancel the dispatch leg first.', v_locked, p_plan_date;
  END IF;

  -- Archive (NEVER DELETE): move every still-live row to the 'voided' terminal state.
  UPDATE public.pod_refill_plan prp
     SET status     = 'voided',
         reasoning  = COALESCE(prp.reasoning, '{}'::jsonb)
                      || jsonb_build_object('voided_reason', p_reason,
                                            'voided_by', v_user_id, 'voided_at', now()),
         updated_at = now()
   WHERE prp.plan_date = p_plan_date
     AND prp.status IN ('draft','approved','stitched');
  GET DIAGNOSTICS v_voided = ROW_COUNT;

  RETURN jsonb_build_object(
    'plan_date', p_plan_date,
    'voided_rows', v_voided,
    'reason', p_reason);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.void_refill_plan(date, text) TO authenticated;
