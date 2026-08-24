-- PRD-016d: field purchases that go shop → machine (never touching a warehouse shelf).
-- Composes two existing canonical writers in ONE transaction:
--   receive_purchase_order_addition  (credits WH + mirrors the PO line, so cost lands)
--   record_actual_refill             (debits that WH and credits the pod, so the units end where they are)
-- Net warehouse effect = 0; cost is attributed to the machine visit. No new direct table writes.
-- Article 1 (delegates to canonical writers), 4 (role + input validation + via_rpc), 8, 12. Cody OK.
-- Applied to prod via MCP 2026-08-21 19:10 UTC.
CREATE OR REPLACE FUNCTION public.receive_po_addition_into_machine(
  p_addition_id uuid,
  p_machine_id  uuid,
  p_shelf_code  text,
  p_visit_date  date DEFAULT NULL,
  p_reason      text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_role        text;
  v_uid         uuid := auth.uid();
  v_add         po_additions%ROWTYPE;
  v_machine     machines%ROWTYPE;
  v_wh          uuid;
  v_shelf_id    uuid;
  v_pod_expiry  date;
  v_expiry      date;
  v_visit       date := COALESCE(p_visit_date, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date);
  v_recv        jsonb;
  v_refill      jsonb;
BEGIN
  PERFORM public.set_write_context('receive_po_addition_into_machine',
    COALESCE(p_reason, format('field purchase received straight into machine %s shelf %s', p_machine_id, p_shelf_code)),
    'po_receive', p_addition_id::text);

  SELECT role INTO v_role FROM user_profiles WHERE id = v_uid;
  IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RETURN jsonb_build_object('status','error','error','Insufficient role');
  END IF;
  IF p_addition_id IS NULL OR p_machine_id IS NULL OR COALESCE(btrim(p_shelf_code),'') = '' THEN
    RETURN jsonb_build_object('status','error','error','p_addition_id, p_machine_id and p_shelf_code are required');
  END IF;

  SELECT * INTO v_add FROM po_additions WHERE addition_id = p_addition_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','error','error','PO addition not found'); END IF;
  IF v_add.status = 'received' THEN
    RETURN jsonb_build_object('status','already_received',
      'message','PO addition already received — no duplicate created');
  END IF;

  SELECT * INTO v_machine FROM machines WHERE machine_id = p_machine_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','error','error','Machine not found'); END IF;

  v_wh := v_machine.primary_warehouse_id;
  IF v_wh IS NULL THEN
    RETURN jsonb_build_object('status','error','error',
      format('Machine %s has no primary_warehouse_id — cannot attribute the receipt', v_machine.official_name));
  END IF;

  SELECT shelf_id INTO v_shelf_id FROM shelf_configurations
   WHERE machine_id = p_machine_id AND shelf_code = upper(btrim(p_shelf_code));
  IF v_shelf_id IS NULL THEN
    RETURN jsonb_build_object('status','error','error',
      format('Shelf %s is not configured on %s', p_shelf_code, v_machine.official_name));
  END IF;

  -- 1) receive into the machine's serving warehouse (cost + PO line mirror)
  v_recv := public.receive_purchase_order_addition(p_addition_id, v_wh, v_add.expiry_date, NULL);
  IF COALESCE(v_recv->>'status','') NOT IN ('ok','already_received') THEN
    RETURN jsonb_build_object('status','error','error',
      COALESCE(v_recv->>'error','receive_purchase_order_addition failed'), 'receive_result', v_recv);
  END IF;

  -- 2) pod expiry key: pod_inventory allows ONE Active row per machine+shelf+product, so a merge
  --    must reuse the shelf's existing expiry. Only a fresh shelf takes the purchase expiry.
  SELECT pi.expiration_date INTO v_pod_expiry
    FROM pod_inventory pi
   WHERE pi.machine_id = p_machine_id AND pi.shelf_id = v_shelf_id
     AND pi.boonz_product_id = v_add.boonz_product_id AND pi.status = 'Active'
   ORDER BY pi.snapshot_at DESC NULLS LAST LIMIT 1;
  v_expiry := COALESCE(v_pod_expiry, v_add.expiry_date);

  -- 3) move it straight out of the warehouse and onto the shelf
  v_refill := public.record_actual_refill(
    v_machine.official_name, v_visit,
    jsonb_build_array(jsonb_build_object(
      'action','refill','boonz_product_id', v_add.boonz_product_id,
      'shelf_code', upper(btrim(p_shelf_code)), 'qty', v_add.qty,
      'expiration_date', v_expiry, 'warehouse_id', v_wh,
      'notes', format('field purchase %s received straight into machine', COALESCE(v_add.po_id,'')))),
    'cs', v_uid,
    COALESCE(p_reason, format('PO addition %s placed directly in %s %s',
             p_addition_id, v_machine.official_name, upper(btrim(p_shelf_code)))),
    false);

  RETURN jsonb_build_object(
    'status', CASE WHEN COALESCE(v_refill->>'status','') = 'applied' THEN 'ok' ELSE 'partial' END,
    'addition_id', p_addition_id, 'qty', v_add.qty,
    'machine', v_machine.official_name, 'shelf_code', upper(btrim(p_shelf_code)),
    'warehouse_id', v_wh, 'visit_date', v_visit,
    'pod_expiry_used', v_expiry, 'purchase_expiry', v_add.expiry_date,
    'expiry_key_reused', (v_pod_expiry IS NOT NULL AND v_pod_expiry IS DISTINCT FROM v_add.expiry_date),
    'receive_result', v_recv, 'refill_result', v_refill);
END;
$function$;

REVOKE ALL ON FUNCTION public.receive_po_addition_into_machine(uuid,uuid,text,date,text) FROM public;
GRANT EXECUTE ON FUNCTION public.receive_po_addition_into_machine(uuid,uuid,text,date,text) TO authenticated, service_role;
