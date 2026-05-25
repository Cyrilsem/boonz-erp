-- PRD-011 Bug 3: restore_pod_refill_row
-- New canonical writer for the pod_refill_plan 'superseded' -> 'draft'
-- transition. Used by the FE Restore button on rows that engine_finalize_pod
-- conflict-resolution marked as superseded. Without this RPC, the FE
-- "Restore" toggle was client-side only and never reached the database.
--
-- Article 1: existing canonical writers for pod_refill_plan are engine_*
-- and edit_pod_refill_row / stop_pod_refill_row / reject_pod_refill_rows.
-- This adds a fifth: restore_pod_refill_row, narrowly scoped to the
-- 'superseded' -> 'draft' flip and rejecting any other current status.
-- Article 4: app.via_rpc + app.rpc_name set; operator_admin role gate.
-- Article 8: relies on the existing pod_refill_plan audit trigger.
-- Article 12: forward-only CREATE OR REPLACE.

CREATE OR REPLACE FUNCTION public.restore_pod_refill_row(
  p_plan_date date,
  p_machine_id uuid,
  p_shelf_id uuid,
  p_pod_product_id uuid,
  p_action text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_user_id   uuid;
  v_row_count integer;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'restore_pod_refill_row', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id
      AND up.role = ANY (ARRAY['operator_admin','superadmin','manager'])
  ) THEN
    RAISE EXCEPTION 'restore_pod_refill_row: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_plan_date IS NULL OR p_machine_id IS NULL OR p_shelf_id IS NULL
     OR p_pod_product_id IS NULL OR p_action IS NULL THEN
    RAISE EXCEPTION 'restore_pod_refill_row: all 5 PK columns required';
  END IF;

  IF p_action NOT IN ('REFILL','ADD_NEW','REMOVE','M2W','NOTHING') THEN
    RAISE EXCEPTION 'restore_pod_refill_row: invalid action %', p_action;
  END IF;

  UPDATE public.pod_refill_plan
     SET status = 'draft',
         reasoning = COALESCE(reasoning, '{}'::jsonb)
                     || jsonb_build_object('restored_from_superseded_at', now()),
         updated_at = now()
   WHERE plan_date      = p_plan_date
     AND machine_id     = p_machine_id
     AND shelf_id       = p_shelf_id
     AND pod_product_id = p_pod_product_id
     AND action         = p_action
     AND status         = 'superseded';

  GET DIAGNOSTICS v_row_count = ROW_COUNT;
  IF v_row_count = 0 THEN
    RAISE EXCEPTION 'restore_pod_refill_row: no superseded row found for (%s, %s, %s, %s, %s)',
      p_plan_date, p_machine_id, p_shelf_id, p_pod_product_id, p_action;
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.restore_pod_refill_row(date, uuid, uuid, uuid, text)
  TO authenticated;
