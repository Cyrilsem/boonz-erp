-- PRD-146 test: approve a return_to_warehouse pod edit whose product+expiry has no lot in the machine's primary
-- warehouse, so the approval takes the INSERT branch. Ends with RAISE so nothing persists. PASS = 'PRD146 PASS ...'.
-- Run without the migration it reports FAIL on case 1 (batch_id vocabulary trigger raises on 'POD_RETURN-').
-- Case 2 covers the sibling apply_inventory_correction insert path ('CORRECTION-' before the fix).
-- Uses a live Active pod row picked at run time; never the field edit 08c8bf83 or its pod row.
DO $t$
DECLARE
  c_approver uuid := 'bf32624e-3334-425d-b694-c5944b0c66f0';  -- role warehouse
  v_pod public.pod_inventory%ROWTYPE; v_wh uuid; v_edit uuid; r jsonb;
  v_wi public.warehouse_inventory%ROWTYPE; v_pod_after public.pod_inventory%ROWTYPE; v_edit_status text;
  v_exp date := current_date + 400;
  ok1 boolean := false; ok2 boolean := false; e1 text; e2 text;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_approver, 'role', 'authenticated')::text, true);

  -- 1. return_to_warehouse with no matching WH lot -> new RETURN-POD- lot, Active; pod row drained
  BEGIN
    SELECT p.pod_inventory_id, m.primary_warehouse_id INTO v_pod.pod_inventory_id, v_wh
      FROM public.pod_inventory p JOIN public.machines m USING (machine_id)
     WHERE p.status = 'Active' AND p.current_stock > 0 AND m.primary_warehouse_id IS NOT NULL
       AND p.pod_inventory_id <> '8fd04276-9ff4-4839-9ddc-684665dd438f'
       AND NOT EXISTS (SELECT 1 FROM public.warehouse_inventory w
                        WHERE w.warehouse_id = m.primary_warehouse_id AND w.boonz_product_id = p.boonz_product_id
                          AND COALESCE(w.expiration_date, DATE '1970-01-01') = COALESCE(p.expiration_date, DATE '1970-01-01'))
       AND NOT EXISTS (SELECT 1 FROM public.pod_inventory_edits e WHERE e.pod_inventory_id = p.pod_inventory_id AND e.status = 'pending')
     ORDER BY p.created_at DESC LIMIT 1;
    SELECT * INTO v_pod FROM public.pod_inventory WHERE pod_inventory_id = v_pod.pod_inventory_id;
    IF v_pod.pod_inventory_id IS NULL THEN RAISE EXCEPTION 'no candidate pod row'; END IF;

    INSERT INTO public.pod_inventory_edits (pod_inventory_id, machine_id, boonz_product_id, requested_by, edit_type, quantity_update, notes)
    VALUES (v_pod.pod_inventory_id, v_pod.machine_id, v_pod.boonz_product_id, c_approver, 'return_to_warehouse', 2, 'PRD-146 test')
    RETURNING edit_id INTO v_edit;

    r := public.approve_pod_inventory_edit(v_edit, c_approver, NULL, false);
    SELECT * INTO v_wi FROM public.warehouse_inventory WHERE wh_inventory_id = (r->>'wh_inventory_id_credited')::uuid;
    SELECT * INTO v_pod_after FROM public.pod_inventory WHERE pod_inventory_id = v_pod.pod_inventory_id;
    SELECT status INTO v_edit_status FROM public.pod_inventory_edits WHERE edit_id = v_edit;

    ok1 := r->>'result' = 'success'
       AND v_wi.batch_id LIKE 'RETURN-POD-%' AND v_wi.status = 'Active' AND v_wi.warehouse_stock = 2
       AND v_wi.warehouse_id = v_wh AND v_wi.expiration_date IS NOT DISTINCT FROM v_pod.expiration_date
       AND v_pod_after.status = 'Inactive' AND v_pod_after.current_stock = 0
       AND v_edit_status = 'approved';
    e1 := format('result %s, wh batch %s status %s stock %s, pod %s/%s, edit %s',
                 r->>'result', v_wi.batch_id, v_wi.status, v_wi.warehouse_stock, v_pod_after.status, v_pod_after.current_stock, v_edit_status);
  EXCEPTION WHEN OTHERS THEN e1 := SQLERRM; END;

  -- 2. apply_inventory_correction path B with no lot for that expiry -> new RECOUNT-CORRECTION- lot
  BEGIN
    r := public.apply_inventory_correction(NULL, v_pod.boonz_product_id, v_wh, v_exp, 3, 'PRD-146 test', c_approver);
    SELECT * INTO v_wi FROM public.warehouse_inventory WHERE wh_inventory_id = (r->>'wh_inventory_id')::uuid;
    ok2 := (r->>'inserted')::boolean AND v_wi.batch_id LIKE 'RECOUNT-CORRECTION-%' AND v_wi.warehouse_stock = 3;
    e2 := format('inserted %s, batch %s, stock %s', r->>'inserted', v_wi.batch_id, v_wi.warehouse_stock);
  EXCEPTION WHEN OTHERS THEN e2 := SQLERRM; END;

  RAISE EXCEPTION 'PRD146 % | pod_return %:% | correction_insert %:%',
    CASE WHEN ok1 AND ok2 THEN 'PASS' ELSE 'FAIL' END, ok1, e1, ok2, e2;
END
$t$;
