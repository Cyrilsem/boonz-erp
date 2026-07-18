-- ROLLBACK: restore live pre-Batch-2 body of receive_purchase_order_addition
-- captured 2026-07-18 from eizcexopcuoycuosittm
-- md5(pg_get_functiondef) = 40f10fb3026345a9e5dbf0141e643d52
CREATE OR REPLACE FUNCTION public.receive_purchase_order_addition(p_addition_id uuid, p_warehouse_id uuid, p_expiry date DEFAULT NULL::date, p_batch_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role text;
  v_addition    po_additions%ROWTYPE;
  v_today       date := (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date;
  v_wh_id       uuid;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'receive_purchase_order_addition', true);

  SELECT role INTO v_caller_role FROM user_profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RETURN jsonb_build_object('status','error','error','Insufficient role');
  END IF;

  IF p_addition_id IS NULL OR p_warehouse_id IS NULL THEN
    RETURN jsonb_build_object('status','error','error','p_addition_id and p_warehouse_id are required');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM warehouses WHERE warehouse_id = p_warehouse_id) THEN
    RETURN jsonb_build_object('status','error','error','Unknown warehouse_id');
  END IF;

  SELECT * INTO v_addition FROM po_additions WHERE addition_id = p_addition_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','error','error','PO addition not found');
  END IF;

  IF v_addition.status = 'received' THEN
    RETURN jsonb_build_object('status','already_received',
      'message','PO addition already received — no duplicate created');
  END IF;

  INSERT INTO warehouse_inventory (
    boonz_product_id, warehouse_stock, status, snapshot_date,
    expiration_date, warehouse_id, batch_id
  ) VALUES (
    v_addition.boonz_product_id, v_addition.qty, 'Active', v_today,
    COALESCE(p_expiry, v_addition.expiry_date),
    p_warehouse_id,
    COALESCE(p_batch_id, format('PO-ADDITION-%s', substring(p_addition_id::text, 1, 8)))
  );

  UPDATE po_additions
  SET status      = 'received',
      received_at = now(),
      received_by = auth.uid()
  WHERE addition_id = p_addition_id;

  RETURN jsonb_build_object(
    'status', 'ok',
    'addition_id', p_addition_id,
    'warehouse_id', p_warehouse_id,
    'qty', v_addition.qty,
    'expiry', COALESCE(p_expiry, v_addition.expiry_date)
  );
END;
$function$
