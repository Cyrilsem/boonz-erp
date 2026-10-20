-- PRD-145 P3-4 test. Run after the migration in one transaction; ends with RAISE so nothing persists.
-- PASS = 'PRD145_P3_4 PASS ...'. Fixture: AMZ-1038-3001-O1 A12 Mountain Dew (the 20 Oct ghost-lot lane) on dates three
-- to five days ahead, with seeded lots: a 2-unit tail lot next to a 40-unit lot (38 once case 1 packs 2 from it).
DO $t$
DECLARE
  c_m   uuid := 'a75b847a-e920-4a94-bb2f-600280ff8b3c';
  c_bp  uuid := 'e257ce9b-f752-4556-b872-ade88f245c6e';
  c_wh  uuid := '4bebef68-9e36-4a5c-9c2c-142f8dbdae85';
  c_op  text := '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}';
  c_whm text := '{"sub":"7f4ecaa4-1efe-4a32-b233-35f5516f6131","role":"authenticated"}';
  v_d   date := current_date + 3;
  v_small uuid; v_big uuid; v_ghost uuid; v_id uuid; r jsonb; rd record; v_pod text; v_n int; v_expected uuid;
  ok1 boolean := false; ok2 boolean := false; ok3 boolean := false; ok4 boolean := false; ok5 boolean := false;
  e1 text; e2 text; e3 text; e4 text; e5 text;
BEGIN
  PERFORM set_config('request.jwt.claims', c_op, true);
  PERFORM set_config('app.provenance_reason', 'manual_adjust', true);
  INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id)
  VALUES (c_bp, 2, DATE '2027-06-01', 'Active', 'RECOUNT-PRD145-TEST-SMALL', current_date, c_wh) RETURNING wh_inventory_id INTO v_small;
  INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id)
  VALUES (c_bp, 40, DATE '2027-08-01', 'Active', 'RECOUNT-PRD145-TEST-BIG', current_date, c_wh) RETURNING wh_inventory_id INTO v_big;

  -- 1. pack from a lot that is not the pinned one: the row's lot and expiry follow the pick; a second lot's child row
  --    carries the line's source_kind
  BEGIN
    r := public.add_dispatch_row(c_m, 'A12', c_bp, 3, 'Refill', v_d, 'wh', c_wh, NULL, 'operator_admin', 'PRD-145 P3-4 test', NULL, NULL);
    v_id := (r->>'dispatch_id')::uuid;
    PERFORM set_config('app.via_rpc', 'true', true);
    PERFORM set_config('app.rpc_name', 'add_dispatch_row', true);
    UPDATE refill_dispatching SET from_wh_inventory_id = v_small, expiry_date = DATE '2027-06-01' WHERE dispatch_id = v_id;
    PERFORM public.pack_dispatch_line(v_id, jsonb_build_array(
      jsonb_build_object('wh_inventory_id', v_big, 'qty', 2, 'boonz_product_id', c_bp),
      jsonb_build_object('wh_inventory_id', 'f07ce1b9-064e-4d5a-b0d1-fe1cf2cecf69', 'qty', 1, 'boonz_product_id', c_bp)), NULL);
    SELECT * INTO rd FROM refill_dispatching WHERE dispatch_id = v_id;
    SELECT count(*) INTO v_n FROM refill_dispatching WHERE parent_dispatch_id = v_id AND source_kind = 'wh'
       AND from_wh_inventory_id = 'f07ce1b9-064e-4d5a-b0d1-fe1cf2cecf69' AND expiry_date = DATE '2027-07-04';
    ok1 := rd.from_wh_inventory_id = v_big AND rd.expiry_date = DATE '2027-08-01' AND v_n = 1;
    e1 := format('row lot big %s expiry %s, wh child rows %s', rd.from_wh_inventory_id = v_big, rd.expiry_date, v_n);
  EXCEPTION WHEN OTHERS THEN e1 := SQLERRM; END;

  -- 2. the warehouse counts the pinned lot to 0: the unpacked line moves to the FEFO live lot that covers it, logged
  BEGIN
    r := public.add_dispatch_row(c_m, 'A12', c_bp, 3, 'Refill', v_d + 1, 'wh', c_wh, NULL, 'operator_admin', 'PRD-145 P3-4 test', NULL, NULL);
    v_id := (r->>'dispatch_id')::uuid;
    PERFORM set_config('app.via_rpc', 'true', true);
    PERFORM set_config('app.rpc_name', 'add_dispatch_row', true);
    UPDATE refill_dispatching SET from_wh_inventory_id = v_small, expiry_date = DATE '2027-06-01' WHERE dispatch_id = v_id;
    SELECT p.wh_inventory_id INTO v_expected FROM v_wh_pickable p
     WHERE p.boonz_product_id = c_bp AND p.warehouse_id = c_wh AND p.wh_inventory_id <> v_small AND p.warehouse_stock >= 3
     ORDER BY p.expiration_date ASC NULLS LAST, p.warehouse_stock DESC LIMIT 1;
    PERFORM set_config('request.jwt.claims', c_whm, true);
    PERFORM public.adjust_warehouse_stock(c_wh, jsonb_build_array(jsonb_build_object(
      'wh_inventory_id', v_small, 'boonz_product_id', c_bp, 'new_warehouse_stock', 0, 'new_consumer_stock', 0,
      'expiration_date', '2027-06-01', 'status', 'Active')), current_date, 'PRD-145 P3-4 test count');
    PERFORM set_config('request.jwt.claims', c_op, true);
    SELECT * INTO rd FROM refill_dispatching WHERE dispatch_id = v_id;
    SELECT count(*) INTO v_n FROM refill_dispatching_edit_log
     WHERE dispatch_id = v_id AND edit_kind = 'repin' AND before_state->>'from_wh_inventory_id' = v_small::text;
    ok2 := rd.from_wh_inventory_id = v_expected AND v_n = 1;
    e2 := format('repinned to expected %s, expiry %s, repin log %s', rd.from_wh_inventory_id = v_expected, rd.expiry_date, v_n);
  EXCEPTION WHEN OTHERS THEN e2 := SQLERRM; END;

  -- 3. a 2-unit lot next to a 40-unit lot is a ghost candidate
  INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id)
  VALUES (c_bp, 2, DATE '2027-05-20', 'Active', 'RECOUNT-PRD145-TEST-GHOST', current_date, c_wh) RETURNING wh_inventory_id INTO v_ghost;
  SELECT count(*) INTO v_n FROM public.get_ghost_lot_candidates() WHERE wh_inventory_id = v_ghost AND big_lot_id = v_big;
  ok3 := v_n = 1;
  e3 := format('candidate rows %s', v_n);

  -- 4. the pin preview flags a plan line that would pin the tail lot
  BEGIN
    SELECT pp.pod_product_name INTO v_pod FROM slot_lifecycle sl JOIN pod_products pp USING (pod_product_id)
     WHERE sl.machine_id = c_m AND sl.shelf_id = (SELECT shelf_id FROM shelf_configurations WHERE machine_id = c_m AND shelf_code = 'A12')
       AND sl.is_current AND NOT sl.archived LIMIT 1;
    r := public.write_refill_plan(v_d + 2, jsonb_build_array(jsonb_build_object(
           'machine_name', 'AMZ-1038-3001-O1', 'shelf_code', 'A12', 'pod_product_name', v_pod,
           'boonz_product_name', (SELECT boonz_product_name FROM boonz_products WHERE product_id = c_bp),
           'action', 'Refill', 'quantity', 2, 'source_origin', 'warehouse', 'comment', 'PRD-145 P3-4 test')));
    SELECT count(*) INTO v_n FROM public.get_plan_pin_preview(v_d + 2)
     WHERE machine_name = 'AMZ-1038-3001-O1' AND shelf_code = 'A12' AND wh_inventory_id = v_ghost AND tail_lot AND bigger_lot_id = v_big;
    ok4 := v_n = 1;
    e4 := format('%s; flagged rows %s', r->>'status', v_n);
  EXCEPTION WHEN OTHERS THEN e4 := SQLERRM; END;

  -- 5. Zero: refused for operator_admin; the warehouse manager zeroes it through adjust_warehouse_stock
  BEGIN
    BEGIN
      PERFORM public.zero_ghost_lot(v_ghost, 'PRD-145 P3-4 test');
      e5 := 'operator accepted';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE '%warehouse manager only%' THEN
        PERFORM set_config('request.jwt.claims', c_whm, true);
        r := public.zero_ghost_lot(v_ghost, 'PRD-145 P3-4 test');
        -- zero_ghost_lot passes status back unchanged; the existing propose_inactivate_on_zero_stock rule then marks
        -- every lot that reaches 0 Inactive (auto-confirmed proposal), as it does for any count to 0.
        SELECT count(*) INTO v_n FROM warehouse_inventory w WHERE w.wh_inventory_id = v_ghost AND w.warehouse_stock = 0
           AND EXISTS (SELECT 1 FROM warehouse_inventory_status_proposal sp WHERE sp.wh_inventory_id = v_ghost
                        AND sp.proposer_name = 'propose_inactivate_on_zero_stock');
        ok5 := r->>'status' = 'ok' AND v_n = 1
               AND NOT EXISTS (SELECT 1 FROM public.get_ghost_lot_candidates() WHERE wh_inventory_id = v_ghost);
        e5 := format('%s, zeroed %s (now %s)', r->>'status', v_n,
                     (SELECT format('stock %s status %s', warehouse_stock, status) FROM warehouse_inventory WHERE wh_inventory_id = v_ghost));
      ELSE
        e5 := SQLERRM;
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN e5 := SQLERRM; END;

  RAISE EXCEPTION 'PRD145_P3_4 % | pack_moves_lot %:% | repin_on_zero %:% | ghost_list %:% | pin_preview %:% | zero %:%',
    CASE WHEN ok1 AND ok2 AND ok3 AND ok4 AND ok5 THEN 'PASS' ELSE 'FAIL' END, ok1, e1, ok2, e2, ok3, e3, ok4, e4, ok5, e5;
END
$t$;
