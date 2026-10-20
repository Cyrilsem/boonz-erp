-- PRD-145 P3-2 test. Run after the migration in the same transaction; ends with RAISE so nothing persists.
-- PASS = 'PRD145_P3_2 PASS ...'. Fixture: the AMZ-1038-3001-O1 A12 Mountain Dew shape of 20 Oct at pack time
-- (1 unit on a 2027-06-10 lot, 2 on a 2027-07-04 lot), rebuilt three days ahead with a seeded 2027-06-10 lot.
-- The fixture machine-day has one line, so packing it auto-sets picked_up (tg_auto_pickup_on_machine_complete), as
-- every machine-day does once its last line is packed: the amend must work on that state.
DO $t$
DECLARE
  c_m   uuid := 'a75b847a-e920-4a94-bb2f-600280ff8b3c';
  c_bp  uuid := 'e257ce9b-f752-4556-b872-ade88f245c6e';
  c_wh  uuid := '4bebef68-9e36-4a5c-9c2c-142f8dbdae85';
  c_l0704 uuid := 'f07ce1b9-064e-4d5a-b0d1-fe1cf2cecf69';
  v_d   date := current_date + 3;
  v_sh  uuid; v_l0610 uuid; v_l0620 uuid; v_root uuid; v_child uuid; v_un uuid;
  r jsonb; g jsonb; v_s0704 numeric; v_s0620 numeric; v_logs int; v_byp int;
  ok1 boolean := false; ok2 boolean := false; ok3 boolean := false; ok4 boolean := false; ok5 boolean := false; ok6 boolean := false;
  e1 text; e2 text; e3 text; e4 text; e5 text; e6 text; v_lots text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
  SELECT shelf_id INTO v_sh FROM shelf_configurations WHERE machine_id = c_m AND shelf_code = 'A12';
  PERFORM set_config('app.provenance_reason', 'manual_adjust', true);
  PERFORM set_config('app.mutation_reason', 'PRD-145 P3-2 test seed (rolled back)', true);
  INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id)
  VALUES (c_bp, 1, DATE '2027-06-10', 'Active', 'RECOUNT-PRD145-TEST-0610', current_date, c_wh) RETURNING wh_inventory_id INTO v_l0610;

  -- 1. pack 3 over two lots: one line, two rows, total 3
  BEGIN
    r := public.add_dispatch_row(c_m, 'A12', c_bp, 3, 'Refill', v_d, 'wh', c_wh, NULL, 'operator_admin', 'PRD-145 P3-2 test', NULL, NULL);
    v_root := (r->>'dispatch_id')::uuid;
    PERFORM public.pack_dispatch_line(v_root, jsonb_build_array(
      jsonb_build_object('wh_inventory_id', v_l0610, 'qty', 1, 'boonz_product_id', c_bp),
      jsonb_build_object('wh_inventory_id', c_l0704, 'qty', 2, 'boonz_product_id', c_bp)), NULL);
    SELECT dispatch_id INTO v_child FROM refill_dispatching WHERE parent_dispatch_id = v_root;
    SELECT string_agg(format('%s@%s', filled_quantity, expiry_date), ' + ' ORDER BY expiry_date) INTO v_lots
      FROM refill_dispatching WHERE COALESCE(parent_dispatch_id, dispatch_id) = v_root AND include;
    ok1 := v_lots = '1@2027-06-10 + 2@2027-07-04';
    e1 := v_lots;
  EXCEPTION WHEN OTHERS THEN e1 := SQLERRM; END;
  g := jsonb_build_object('machine_id', c_m, 'shelf_id', v_sh, 'boonz_product_id', c_bp, 'action', 'Refill',
                          'source_kind', 'wh', 'root_dispatch_id', v_root);

  -- 2. lower the total to 2: the newest-expiry lot (2027-07-04) gives one unit back to that lot
  BEGIN
    SELECT warehouse_stock INTO v_s0704 FROM warehouse_inventory WHERE wh_inventory_id = c_l0704;
    r := public.amend_dispatch_line_total(g, 2, 'PRD-145 P3-2 test lower');
    SELECT string_agg(format('%s@%s', filled_quantity, expiry_date), ' + ' ORDER BY expiry_date) INTO v_lots
      FROM refill_dispatching WHERE COALESCE(parent_dispatch_id, dispatch_id) = v_root AND include;
    ok2 := r->>'status' = 'ok' AND v_lots = '1@2027-06-10 + 1@2027-07-04'
           AND (SELECT warehouse_stock FROM warehouse_inventory WHERE wh_inventory_id = c_l0704) = v_s0704 + 1
           AND (SELECT pack_outcome::text FROM refill_dispatching WHERE dispatch_id = v_root) = 'partial';
    e2 := format('%s lots %s', r->>'status', v_lots);
  EXCEPTION WHEN OTHERS THEN e2 := SQLERRM; END;

  -- 3. raise to 4 with a 2027-06-20 lot in stock: FEFO takes it, on a new lot row; the other rows keep their quantity
  BEGIN
    INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id)
    VALUES (c_bp, 5, DATE '2027-06-20', 'Active', 'RECOUNT-PRD145-TEST-0620', current_date, c_wh) RETURNING wh_inventory_id INTO v_l0620;
    r := public.amend_dispatch_line_total(g, 4, 'PRD-145 P3-2 test raise');
    SELECT string_agg(format('%s@%s', filled_quantity, expiry_date), ' + ' ORDER BY expiry_date) INTO v_lots
      FROM refill_dispatching WHERE COALESCE(parent_dispatch_id, dispatch_id) = v_root AND include;
    SELECT warehouse_stock INTO v_s0620 FROM warehouse_inventory WHERE wh_inventory_id = v_l0620;
    ok3 := r->>'status' = 'ok' AND v_lots = '1@2027-06-10 + 2@2027-06-20 + 1@2027-07-04' AND v_s0620 = 3
           AND (SELECT sum(quantity) FROM refill_dispatching WHERE COALESCE(parent_dispatch_id, dispatch_id) = v_root AND include) = 4
           AND (SELECT pack_outcome::text FROM refill_dispatching WHERE dispatch_id = v_root) = 'packed';
    e3 := format('%s lots %s 06-20 stock %s', r->>'status', v_lots, v_s0620);
  EXCEPTION WHEN OTHERS THEN e3 := SQLERRM; END;

  -- 4. every touched row has an edit-log row that passes state_coherence; no canonical-write bypass logged
  SELECT count(*) INTO v_logs FROM refill_dispatching_edit_log l
   WHERE l.reason LIKE 'amend_dispatch_line_total: PRD-145 P3-2 test%'
     AND l.dispatch_id IN (SELECT dispatch_id FROM refill_dispatching WHERE COALESCE(parent_dispatch_id, dispatch_id) = v_root);
  SELECT count(*) INTO v_byp FROM bypass_violation_log WHERE rpc_name = 'amend_dispatch_line_total';
  ok4 := v_logs = 2 AND v_byp = 0;  -- lower: 1 'qty'; raise: 1 'add'
  e4 := format('edit_log %s bypass %s', v_logs, v_byp);

  -- 5. an unpacked line: the total is the row's quantity
  BEGIN
    r := public.add_dispatch_row(c_m, 'A12', c_bp, 3, 'Refill', v_d + 1, 'wh', c_wh, NULL, 'operator_admin', 'PRD-145 P3-2 test', NULL, NULL);
    v_un := (r->>'dispatch_id')::uuid;
    r := public.amend_dispatch_line_total(g || jsonb_build_object('root_dispatch_id', v_un), 5, 'PRD-145 P3-2 test unpacked');
    ok5 := r->>'mode' = 'unpacked' AND (SELECT quantity FROM refill_dispatching WHERE dispatch_id = v_un) = 5;
    e5 := r::text;
  EXCEPTION WHEN OTHERS THEN e5 := SQLERRM; END;

  -- 6. a received line is refused (amend_dispatch_after_pickup owns it)
  BEGIN
    PERFORM public.receive_dispatch_line(v_child, 1, auth.uid(), NULL, true, 'PRD-145 P3-2 test');
    PERFORM public.amend_dispatch_line_total(g, 3, 'PRD-145 P3-2 test after receive');
    e6 := 'accepted';
  EXCEPTION WHEN OTHERS THEN ok6 := SQLERRM LIKE '%use amend_dispatch_after_pickup%'; e6 := SQLERRM; END;

  RAISE EXCEPTION 'PRD145_P3_2 % | pack_split %:% | lower_newest %:% | raise_fefo %:% | log %:% | unpacked %:% | after_receive %:%',
    CASE WHEN ok1 AND ok2 AND ok3 AND ok4 AND ok5 AND ok6 THEN 'PASS' ELSE 'FAIL' END,
    ok1, e1, ok2, e2, ok3, e3, ok4, e4, ok5, e5, ok6, e6;
END
$t$;
