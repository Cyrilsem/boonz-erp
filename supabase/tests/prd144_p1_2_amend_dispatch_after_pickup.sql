-- PRD-144 P1-2 test: amend_dispatch_after_pickup (qty down, void, shelf move, refusals). Ends with RAISE: nothing persists.
-- PASS = 'PRD144_P1_2 PASS ...'.
DO $t$
DECLARE
  a record; b record; s record; bad record; wh_before record; wh_after record;
  r_qty jsonb; r_void jsonb; r_shelf jsonb; e_map text := 'not refused'; e_role text := 'not refused'; e_actor text := 'not refused';
  a_after record; b_after record; v_logs int;
BEGIN
  -- line A: qty down by 1 (needs a pinned reservation with consumer stock)
  SELECT rd.dispatch_id, rd.filled_quantity, rd.from_wh_inventory_id, rd.machine_id, rd.boonz_product_id, rd.shelf_id INTO a
    FROM refill_dispatching rd JOIN warehouse_inventory wi ON wi.wh_inventory_id = rd.from_wh_inventory_id
   WHERE rd.picked_up AND rd.include AND rd.delivered_at IS NULL AND NOT COALESCE(rd.item_added,false) AND NOT COALESCE(rd.returned,false)
     AND NOT COALESCE(rd.cancelled,false) AND rd.action = 'Refill' AND NOT COALESCE(rd.is_m2m,false)
     AND rd.filled_quantity >= 2 AND wi.consumer_stock >= 1
   ORDER BY rd.dispatch_date DESC LIMIT 1;
  SELECT warehouse_stock, consumer_stock INTO wh_before FROM warehouse_inventory WHERE wh_inventory_id = a.from_wh_inventory_id;
  -- line B: void (another picked-up Refill line with a reservation)
  SELECT rd.dispatch_id INTO b
    FROM refill_dispatching rd JOIN warehouse_inventory wi ON wi.wh_inventory_id = rd.from_wh_inventory_id
   WHERE rd.picked_up AND rd.include AND rd.delivered_at IS NULL AND NOT COALESCE(rd.item_added,false) AND NOT COALESCE(rd.returned,false)
     AND NOT COALESCE(rd.cancelled,false) AND rd.action = 'Refill' AND NOT COALESCE(rd.is_m2m,false)
     AND wi.consumer_stock >= 1 AND rd.dispatch_id <> a.dispatch_id AND rd.from_wh_inventory_id <> a.from_wh_inventory_id
   ORDER BY rd.dispatch_date DESC LIMIT 1;
  -- a shelf on A's machine whose pod maps to A's product, and one where it does not
  SELECT sc.shelf_code INTO s FROM shelf_configurations sc
    JOIN slot_lifecycle sl ON sl.shelf_id = sc.shelf_id AND sl.is_current AND NOT sl.archived
    JOIN product_mapping pm ON pm.pod_product_id = sl.pod_product_id AND pm.boonz_product_id = a.boonz_product_id AND pm.status = 'Active'
                            AND (pm.machine_id = a.machine_id OR pm.machine_id IS NULL)
   WHERE sc.machine_id = a.machine_id AND sc.shelf_id <> a.shelf_id AND NOT sc.is_phantom LIMIT 1;
  SELECT sc.shelf_code INTO bad FROM shelf_configurations sc
    JOIN slot_lifecycle sl ON sl.shelf_id = sc.shelf_id AND sl.is_current AND NOT sl.archived
   WHERE sc.machine_id = a.machine_id AND sc.shelf_id <> a.shelf_id AND NOT sc.is_phantom
     AND NOT EXISTS (SELECT 1 FROM product_mapping pm WHERE pm.pod_product_id = sl.pod_product_id AND pm.boonz_product_id = a.boonz_product_id AND pm.status = 'Active')
     AND NOT EXISTS (SELECT 1 FROM weimi_lane_now(sc.machine_id, sc.shelf_code) w JOIN product_mapping pm ON pm.pod_product_id = w.pod_product_id
                      WHERE pm.boonz_product_id = a.boonz_product_id AND pm.status = 'Active')
   LIMIT 1;

  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
  r_qty := public.amend_dispatch_after_pickup(a.dispatch_id, NULL, a.filled_quantity - 1, false, 'PRD-144 test qty, rolled back', NULL);
  SELECT warehouse_stock, consumer_stock INTO wh_after FROM warehouse_inventory WHERE wh_inventory_id = a.from_wh_inventory_id;
  r_void := public.amend_dispatch_after_pickup(b.dispatch_id, NULL, NULL, true, 'PRD-144 test void, rolled back', NULL);
  IF s.shelf_code IS NOT NULL THEN
    r_shelf := public.amend_dispatch_after_pickup(a.dispatch_id, s.shelf_code, NULL, false, 'PRD-144 test shelf, rolled back', NULL);
  END IF;
  BEGIN
    PERFORM public.amend_dispatch_after_pickup(a.dispatch_id, bad.shelf_code, NULL, false, 'PRD-144 test bad shelf', NULL);
  EXCEPTION WHEN OTHERS THEN e_map := SQLERRM; END;
  BEGIN
    PERFORM public.amend_dispatch_after_pickup(a.dispatch_id, NULL, 1, false, 'PRD-144 test actor', gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN e_actor := SQLERRM; END;
  SELECT quantity, filled_quantity, shelf_id INTO a_after FROM refill_dispatching WHERE dispatch_id = a.dispatch_id;
  SELECT include, quantity, returned INTO b_after FROM refill_dispatching WHERE dispatch_id = b.dispatch_id;
  SELECT count(*) INTO v_logs FROM refill_dispatching_edit_log WHERE dispatch_id IN (a.dispatch_id, b.dispatch_id) AND reason LIKE 'amend_dispatch_after_pickup:%';
  PERFORM set_config('request.jwt.claims', '{"sub":"bf32624e-3334-425d-b694-c5944b0c66f0","role":"authenticated"}', true);
  BEGIN
    PERFORM public.amend_dispatch_after_pickup(a.dispatch_id, NULL, NULL, true, 'PRD-144 test role', NULL);
  EXCEPTION WHEN OTHERS THEN e_role := SQLERRM; END;
  RAISE EXCEPTION 'PRD144_P1_2 % | qty: filled % -> % wh %/% -> %/% | void: include=% qty=% returned=% | shelf % -> %: % | bad shelf %: % | actor: % | warehouse: % | edit_log rows %',
    CASE WHEN wh_after.warehouse_stock = wh_before.warehouse_stock + 1 AND wh_after.consumer_stock = wh_before.consumer_stock - 1
              AND NOT b_after.include AND b_after.quantity = 0 AND b_after.returned
              AND e_map LIKE '%not mapped%' AND e_role LIKE '%operator_admin only%' AND e_actor LIKE '%p_actor%'
              AND (s.shelf_code IS NULL OR r_shelf->>'status' = 'ok') AND v_logs >= 2
         THEN 'PASS' ELSE 'FAIL' END,
    a.filled_quantity, a_after.filled_quantity, wh_before.warehouse_stock, wh_before.consumer_stock, wh_after.warehouse_stock, wh_after.consumer_stock,
    b_after.include, b_after.quantity, b_after.returned, s.shelf_code, a_after.shelf_id, r_shelf->>'status', bad.shelf_code, left(e_map, 120),
    left(e_actor, 80), left(e_role, 80), v_logs;
END $t$;
