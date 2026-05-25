-- Phase G P3 A.2: PO physical receipt gate substrate.
-- Cody-approved against Articles 1, 2, 4, 5, 6, 8, 12.
-- Applied to prod 2026-05-25 via MCP. This file is the repo mirror.

-- 1. New column on purchase_orders.
ALTER TABLE public.purchase_orders
  ADD COLUMN IF NOT EXISTS physical_received_qty numeric NULL;

COMMENT ON COLUMN public.purchase_orders.physical_received_qty IS
'Physically-confirmed unit count, set via confirm_physical_receipt. NULL = not yet confirmed; existing rows backfilled NULL per PRD D3.';

-- 2. Widen warehouse_inventory.status CHECK to accept PendingPhysicalReceipt.
ALTER TABLE public.warehouse_inventory
  DROP CONSTRAINT IF EXISTS warehouse_inventory_status_check;
ALTER TABLE public.warehouse_inventory
  ADD CONSTRAINT warehouse_inventory_status_check
  CHECK (status = ANY (ARRAY[
    'Active'::text,
    'Inactive'::text,
    'Expired'::text,
    'Removed'::text,
    'Reserved'::text,
    'PendingPhysicalReceipt'::text
  ]));

-- 3. New canonical writer for physical_received_qty.
CREATE OR REPLACE FUNCTION public.confirm_physical_receipt(
  p_po_line_id uuid,
  p_physical_qty numeric,
  p_received_by uuid DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_user_id   uuid;
  v_caller    text;
  v_line      public.purchase_orders%ROWTYPE;
  v_before    jsonb;
  v_after     jsonb;
BEGIN
  v_user_id := COALESCE(p_received_by, auth.uid());
  SELECT role INTO v_caller FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller IS NULL OR v_caller NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'confirm_physical_receipt: forbidden for role %', COALESCE(v_caller,'unknown');
  END IF;

  IF p_po_line_id IS NULL THEN RAISE EXCEPTION 'p_po_line_id required'; END IF;
  IF p_physical_qty IS NULL OR p_physical_qty < 0 THEN
    RAISE EXCEPTION 'p_physical_qty must be >= 0';
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'confirm_physical_receipt', true);

  SELECT * INTO v_line FROM public.purchase_orders
   WHERE po_line_id = p_po_line_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'confirm_physical_receipt: po_line_id % not found', p_po_line_id;
  END IF;
  IF v_line.received_date IS NULL THEN
    RAISE EXCEPTION 'confirm_physical_receipt: po_line_id % has not been received yet (received_date is NULL)', p_po_line_id;
  END IF;
  IF v_line.physical_received_qty IS NOT NULL THEN
    RAISE EXCEPTION 'confirm_physical_receipt: po_line_id % already confirmed (physical_received_qty = %)',
      p_po_line_id, v_line.physical_received_qty;
  END IF;

  v_before := jsonb_build_object(
    'received_qty', v_line.received_qty,
    'physical_received_qty', v_line.physical_received_qty,
    'purchase_outcome', v_line.purchase_outcome
  );

  UPDATE public.purchase_orders
     SET physical_received_qty = p_physical_qty,
         last_edited_at = now(),
         last_edited_by = v_user_id
   WHERE po_line_id = p_po_line_id;

  v_after := jsonb_build_object(
    'received_qty', v_line.received_qty,
    'physical_received_qty', p_physical_qty,
    'delta_vs_received', p_physical_qty - COALESCE(v_line.received_qty, 0)
  );

  INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
  VALUES (
    v_line.po_id,
    'physical_receipt_confirmed',
    v_user_id,
    jsonb_build_object(
      'po_line_id', p_po_line_id,
      'before', v_before, 'after', v_after,
      'notes', p_notes, 'actor_role', v_caller
    )
  );

  INSERT INTO public.write_audit_log (
    table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, payload
  ) VALUES (
    'purchase_orders', 'UPDATE', p_po_line_id::text, v_user_id, v_caller,
    true, 'confirm_physical_receipt',
    jsonb_build_object('po_id', v_line.po_id, 'before', v_before, 'after', v_after, 'notes', p_notes)
  );

  RETURN jsonb_build_object(
    'po_line_id', p_po_line_id,
    'po_id', v_line.po_id,
    'received_qty', v_line.received_qty,
    'physical_received_qty', p_physical_qty,
    'delta', p_physical_qty - COALESCE(v_line.received_qty, 0),
    'confirmed_at', now(),
    'confirmed_by', v_user_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.confirm_physical_receipt(uuid, numeric, uuid, text) TO authenticated;
