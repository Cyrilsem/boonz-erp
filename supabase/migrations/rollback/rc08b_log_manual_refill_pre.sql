-- VERBATIM pre-B live body of log_manual_refill (captured 2026-07-18). Included by rc08b_rollback.sql.
CREATE OR REPLACE FUNCTION public.log_manual_refill(p_machine_name text, p_source_warehouse_id uuid, p_refill_date date, p_lines jsonb, p_reason text DEFAULT 'manual_refill_backlog'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role text; v_machine_id uuid; v_wh_name text; v_line jsonb; v_bpid uuid; v_qty numeric; v_exp date; v_shelf_code text; v_shelf_id uuid; v_product_name text;
  v_remaining numeric; v_src_row warehouse_inventory%ROWTYPE; v_pick numeric; v_pod_id uuid;
  v_lines_processed int := 0; v_total_units numeric := 0; v_wh_decremented numeric := 0; v_results jsonb := '[]'::jsonb;
  v_new_purchase boolean; v_new_wh_id uuid;  -- PRD-036 Phase B
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'log_manual_refill', true);
  PERFORM set_config('app.provenance_reason', 'manual_adjust', true);
  SELECT role INTO v_role FROM user_profiles WHERE id = auth.uid();
  IF v_role IS NULL OR v_role NOT IN ('warehouse', 'operator_admin', 'superadmin', 'manager') THEN RAISE EXCEPTION 'Unauthorized: role "%" cannot log manual refills', COALESCE(v_role, 'none'); END IF;
  SELECT machine_id INTO v_machine_id FROM machines WHERE official_name = p_machine_name;
  IF v_machine_id IS NULL THEN RAISE EXCEPTION 'Machine "%" not found', p_machine_name; END IF;
  SELECT name INTO v_wh_name FROM warehouses WHERE warehouse_id = p_source_warehouse_id;
  IF v_wh_name IS NULL THEN RAISE EXCEPTION 'Warehouse % not found', p_source_warehouse_id; END IF;
  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN RAISE EXCEPTION 'p_lines must be a non-empty JSON array'; END IF;
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_bpid := (v_line->>'boonz_product_id')::uuid;
    v_qty := (v_line->>'qty')::numeric;
    v_exp := (v_line->>'expiration_date')::date;
    v_shelf_code := v_line->>'shelf_code';
    v_new_purchase := COALESCE((v_line->>'new_purchase')::boolean, false);  -- PRD-036 Phase B
    IF v_bpid IS NULL THEN RAISE EXCEPTION 'boonz_product_id required in every line'; END IF;
    IF v_qty IS NULL OR v_qty <= 0 THEN RAISE EXCEPTION 'qty must be > 0'; END IF;
    IF v_shelf_code IS NULL THEN RAISE EXCEPTION 'shelf_code required in every line'; END IF;
    IF v_new_purchase AND v_exp IS NULL THEN RAISE EXCEPTION 'new_purchase line requires expiration_date (boonz_product %)', v_bpid; END IF;
    SELECT boonz_product_name INTO v_product_name FROM boonz_products WHERE product_id = v_bpid;
    IF v_product_name IS NULL THEN RAISE EXCEPTION 'boonz_product_id % not found', v_bpid; END IF;
    SELECT shelf_id INTO v_shelf_id FROM shelf_configurations WHERE machine_id = v_machine_id AND shelf_code = v_shelf_code;
    v_remaining := v_qty;

    IF v_new_purchase THEN
      INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id)
      VALUES (v_bpid, v_qty, v_exp, 'Active', format('NEW-PURCHASE-%s', p_refill_date), CURRENT_DATE, p_source_warehouse_id)
      RETURNING wh_inventory_id INTO v_new_wh_id;
      PERFORM set_config('app.source_event_id', v_new_wh_id::text, true);
      INSERT INTO inventory_audit_log (wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason)
      VALUES (v_new_wh_id, v_bpid, auth.uid(), 0, v_qty, format('Manual NEW PURCHASE receipt at %s: %s units of %s (exp %s) — %s', v_wh_name, v_qty, v_product_name, v_exp, p_reason));
      UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) - v_qty WHERE wh_inventory_id = v_new_wh_id;
      INSERT INTO inventory_audit_log (wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason)
      VALUES (v_new_wh_id, v_bpid, auth.uid(), v_qty, 0, format('Manual NEW PURCHASE OUT to %s/%s: %s units of %s — %s', p_machine_name, v_shelf_code, v_qty, v_product_name, p_reason));
      v_remaining := 0;
      v_wh_decremented := v_wh_decremented + v_qty;
    ELSE
      FOR v_src_row IN SELECT * FROM warehouse_inventory WHERE boonz_product_id = v_bpid AND warehouse_id = p_source_warehouse_id AND status = 'Active' AND COALESCE(warehouse_stock, 0) > 0 ORDER BY expiration_date ASC NULLS LAST, created_at ASC FOR UPDATE LOOP
        EXIT WHEN v_remaining <= 0;
        v_pick := LEAST(v_remaining, v_src_row.warehouse_stock);
        PERFORM set_config('app.source_event_id', v_src_row.wh_inventory_id::text, true);
        UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) - v_pick WHERE wh_inventory_id = v_src_row.wh_inventory_id;
        INSERT INTO inventory_audit_log (wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason) VALUES (v_src_row.wh_inventory_id, v_bpid, auth.uid(), v_src_row.warehouse_stock, v_src_row.warehouse_stock - v_pick, format('Manual refill OUT to %s/%s: %s units of %s — %s', p_machine_name, v_shelf_code, v_pick, v_product_name, p_reason));
        v_remaining := v_remaining - v_pick;
        v_wh_decremented := v_wh_decremented + v_pick;
      END LOOP;
    END IF;

    INSERT INTO pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, estimated_remaining, expiration_date, batch_id, status, snapshot_at) VALUES (v_machine_id, v_shelf_id, v_bpid, p_refill_date, v_qty, v_qty, v_exp, CASE WHEN v_new_purchase THEN format('NEW-PURCHASE-%s', p_refill_date) ELSE format('MANUAL-REFILL-%s', p_refill_date) END, 'Active', now()) RETURNING pod_inventory_id INTO v_pod_id;
    INSERT INTO pod_inventory_audit_log (pod_inventory_id, machine_id, shelf_id, boonz_product_id, expiration_date, source, operation, old_stock, new_stock, delta, old_status, new_status, actor, reference_id, notes) VALUES (v_pod_id, v_machine_id, v_shelf_id, v_bpid, v_exp, 'refill', 'insert', 0, v_qty, v_qty, NULL, 'Active', auth.uid(), format('manual-refill-%s-%s', p_machine_name, p_refill_date), format('%s: %s x %s on %s — %s%s', v_product_name, v_qty, v_shelf_code, p_refill_date, p_reason, CASE WHEN v_new_purchase THEN ' [new purchase]' ELSE '' END));
    v_lines_processed := v_lines_processed + 1;
    v_total_units := v_total_units + v_qty;
    v_results := v_results || jsonb_build_object('shelf_code', v_shelf_code, 'product', v_product_name, 'qty', v_qty, 'pod_inventory_id', v_pod_id, 'new_purchase', v_new_purchase, 'wh_decremented', v_qty - GREATEST(v_remaining, 0), 'wh_shortfall', GREATEST(v_remaining, 0));
  END LOOP;
  RETURN jsonb_build_object('status', 'ok', 'machine', p_machine_name, 'source_warehouse', v_wh_name, 'refill_date', p_refill_date, 'lines_processed', v_lines_processed, 'total_units_to_pod', v_total_units, 'total_wh_decremented', v_wh_decremented, 'shortfall_warning', CASE WHEN v_wh_decremented < v_total_units THEN format('WH had %s less than the %s refilled — physical count may be needed', v_total_units - v_wh_decremented, v_total_units) ELSE NULL END, 'details', v_results);
END;
$function$;
