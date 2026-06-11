-- Refill System v2 / Phase 1 (F1) — swap_pod_refill_row: in-place product swap on a plan row.
--
-- pod_refill_plan's PK is (plan_date, machine_id, shelf_id, pod_product_id, action), so "swapping
-- the product on a shelf" is necessarily a two-row operation: stop the old product's row and add
-- the new product's row carrying the same qty + action. Rather than re-implement the writes (and
-- duplicate the locked-shelf guard, audit, role gate), this orchestrator COMPOSES the existing
-- canonical writers:
--   * edit_pod_refill_row(..., p_new_qty := 0)  -> stops the old product (edit_type 'stop')
--   * add_pod_refill_row(..., p_qty := carried) -> adds the new product (edit_type 'add')
-- Both sub-writers already set app.via_rpc, enforce the operator_admin/superadmin/warehouse tier,
-- run the refill_plan_output locked-shelf guard, and write pod_refill_plan_audit. No new raw write
-- path is introduced. APPLIED 2026-06-01 (attended apply; verified in pg_proc).

CREATE OR REPLACE FUNCTION public.swap_pod_refill_row(
  p_plan_date          date,
  p_machine_id         uuid,
  p_shelf_id           uuid,
  p_old_pod_product_id uuid,
  p_new_pod_product_id uuid,
  p_action             text,
  p_reason             text,
  p_conductor_session  text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_old_qty int;
  v_stop    jsonb;
  v_add     jsonb;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'swap_pod_refill_row', true);

  -- Tier matches the composed writers (operator_admin/superadmin/warehouse). The inner calls
  -- re-check the same gate; this up-front check gives a clearer error and avoids partial work.
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND role = ANY(ARRAY['operator_admin','superadmin','warehouse'])
  ) THEN
    RAISE EXCEPTION 'forbidden: swap_pod_refill_row requires operator_admin, superadmin, or warehouse';
  END IF;

  IF p_new_pod_product_id = p_old_pod_product_id THEN
    RAISE EXCEPTION 'swap_pod_refill_row: new product equals old product (nothing to swap)';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>= 10 chars)';
  END IF;

  -- Carry the existing qty from the row being swapped out.
  SELECT qty INTO v_old_qty
  FROM public.pod_refill_plan
  WHERE plan_date = p_plan_date AND machine_id = p_machine_id AND shelf_id = p_shelf_id
    AND pod_product_id = p_old_pod_product_id AND action = p_action;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'swap_pod_refill_row: no % row for old product % on this shelf/plan', p_action, p_old_pod_product_id;
  END IF;

  -- Stop the old product (qty -> 0). edit_pod_refill_row enforces the locked-shelf guard, so a
  -- shelf already dispatched (refill_plan_output past pending) raises here and nothing is written.
  v_stop := public.edit_pod_refill_row(
    p_plan_date, p_machine_id, p_shelf_id, p_old_pod_product_id, p_action,
    p_new_qty := 0,
    p_reason  := format('swap_out -> %s: %s', p_new_pod_product_id, p_reason),
    p_conductor_session := p_conductor_session);

  -- Add the new product carrying the old qty + action via the canonical add path (validates the
  -- product exists, dedupes the 5-tuple, audits, and stamps source_origin='warehouse').
  v_add := public.add_pod_refill_row(
    p_plan_date, p_machine_id, p_shelf_id, p_new_pod_product_id, p_action, v_old_qty,
    p_reason := format('swap_in <- %s: %s', p_old_pod_product_id, p_reason),
    p_conductor_session := p_conductor_session);

  RETURN jsonb_build_object(
    'swap', 'done',
    'plan_date', p_plan_date, 'machine_id', p_machine_id, 'shelf_id', p_shelf_id,
    'action', p_action, 'old_pod_product_id', p_old_pod_product_id,
    'new_pod_product_id', p_new_pod_product_id, 'qty_carried', v_old_qty,
    'stopped', v_stop, 'added', v_add, 'restitch_required', true);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.swap_pod_refill_row(date,uuid,uuid,uuid,uuid,text,text,text) TO authenticated;
