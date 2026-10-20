-- PRD-145 P3-5 test. Run after the migration in the same transaction; ends with RAISE so nothing persists.
-- PASS = 'PRD145_P3_5 PASS ...'. Fixture: AMZ-1038-3001-O1 A15 Al Ain Zero (warehouse stock in the hundreds), lines
-- written with add_dispatch_row three to five days ahead (one date per case: one unstarted row per lane and date).
DO $t$
DECLARE
  c_m   uuid := 'a75b847a-e920-4a94-bb2f-600280ff8b3c';
  c_bp  uuid := '525b317b-e390-4439-aa08-367e0cd6ea5c';
  c_wh  uuid := '4bebef68-9e36-4a5c-9c2c-142f8dbdae85';
  v_d   date := current_date + 3;
  r jsonb; rd record; v_id uuid; v_lot uuid; s0 numeric; s1 numeric; c0 numeric; c1 numeric; v_err text;
  ok1 boolean := false; ok2 boolean := false; ok2b boolean := false; ok3 boolean := false; ok4 boolean := false;
  ok5 boolean := false; ok6 boolean := false; ok7 boolean := false;
  e1 text; e2 text; e2b text; e3 text; e4 text; e5 text; e6 text; e7 text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
  SELECT p.wh_inventory_id INTO v_lot FROM v_wh_pickable p
   WHERE p.boonz_product_id = c_bp AND p.warehouse_id = c_wh AND p.reserved_for_machine_id IS NULL AND p.warehouse_stock >= 10
   ORDER BY p.expiration_date ASC NULLS LAST LIMIT 1;

  -- 1. pack with 0 picks: not_filled, filled 0, item_added false, packed stays false (pickup ignores it)
  BEGIN
    r := public.add_dispatch_row(c_m, 'A15', c_bp, 2, 'Refill', v_d, 'wh', c_wh, NULL, 'operator_admin', 'PRD-145 P3-5 test', NULL, NULL);
    v_id := (r->>'dispatch_id')::uuid;
    PERFORM public.pack_dispatch_line(v_id, '[{"qty":0,"reason":"PRD-145 test"}]'::jsonb, NULL);
    SELECT * INTO rd FROM refill_dispatching WHERE dispatch_id = v_id;
    ok1 := rd.pack_outcome = 'not_filled' AND rd.filled_quantity = 0 AND NOT rd.item_added AND NOT rd.packed AND NOT rd.picked_up;
    e1 := format('%s filled %s item_added %s packed %s', rd.pack_outcome, rd.filled_quantity, rd.item_added, rd.packed);
  EXCEPTION WHEN OTHERS THEN e1 := SQLERRM; END;

  -- 2. packed 2, picked up, driver receives 0: not_filled, item_added false, the 2 units back on the lot
  BEGIN
    r := public.add_dispatch_row(c_m, 'A15', c_bp, 2, 'Refill', v_d + 1, 'wh', c_wh, NULL, 'operator_admin', 'PRD-145 P3-5 test', NULL, NULL);
    v_id := (r->>'dispatch_id')::uuid;
    SELECT warehouse_stock, consumer_stock INTO s0, c0 FROM warehouse_inventory WHERE wh_inventory_id = v_lot;
    PERFORM public.pack_dispatch_line(v_id, jsonb_build_array(jsonb_build_object('wh_inventory_id', v_lot, 'qty', 2, 'boonz_product_id', c_bp)), NULL);
    PERFORM public.mark_picked_up(ARRAY[v_id]);
    r := public.receive_dispatch_line(v_id, 0, auth.uid(), NULL, false, NULL);
    SELECT * INTO rd FROM refill_dispatching WHERE dispatch_id = v_id;
    SELECT warehouse_stock, consumer_stock INTO s1, c1 FROM warehouse_inventory WHERE wh_inventory_id = v_lot;
    ok2 := rd.pack_outcome = 'not_filled' AND rd.filled_quantity = 0 AND NOT rd.item_added AND rd.picked_up
           AND rd.not_filled_reason = 'driver delivered 0' AND s1 = s0 AND c1 = c0;
    e2 := format('%s filled %s item_added %s picked_up %s stock %s->%s consumer %s->%s', rd.pack_outcome, rd.filled_quantity,
                 rd.item_added, rd.picked_up, s0, s1, c0, c1);
  EXCEPTION WHEN OTHERS THEN e2 := SQLERRM; END;

  -- 2b. a second receive is refused (no double credit)
  BEGIN
    PERFORM public.receive_dispatch_line(v_id, 0, auth.uid(), NULL, false, NULL);
    e2b := 'second receive accepted';
  EXCEPTION WHEN OTHERS THEN ok2b := SQLERRM LIKE '%already closed as not filled%'; e2b := SQLERRM; END;

  -- 3. driver not_done is accepted on the picked_up 0-filled row
  BEGIN
    r := public.driver_report_dispatch_outcome(v_id, 'not_done', NULL);
    SELECT * INTO rd FROM refill_dispatching WHERE dispatch_id = v_id;
    ok3 := r->>'status' = 'recorded' AND rd.driver_outcome = 'not_done';
    e3 := r->>'status';
  EXCEPTION WHEN OTHERS THEN e3 := SQLERRM; END;

  -- 4. amend void is accepted and credits nothing
  BEGIN
    r := public.amend_dispatch_after_pickup(v_id, NULL, NULL, true, 'PRD-145 P3-5 test void', NULL);
    SELECT * INTO rd FROM refill_dispatching WHERE dispatch_id = v_id;
    SELECT warehouse_stock, consumer_stock INTO s1, c1 FROM warehouse_inventory WHERE wh_inventory_id = v_lot;
    ok4 := r->>'status' = 'ok' AND NOT rd.include AND NOT COALESCE(rd.returned, false) AND s1 = s0 AND c1 = c0;
    e4 := format('%s include %s returned %s stock %s', r->>'status', rd.include, rd.returned, s1);
  EXCEPTION WHEN OTHERS THEN e4 := SQLERRM; END;

  -- 5. the 20 Oct shape (ea944182): item_added true, partial, filled 0, picked_up. Driver and void both have an exit.
  BEGIN
    r := public.add_dispatch_row(c_m, 'A15', c_bp, 1, 'Refill', v_d + 2, 'wh', c_wh, NULL, 'operator_admin', 'PRD-145 P3-5 test', NULL, NULL);
    v_id := (r->>'dispatch_id')::uuid;
    PERFORM set_config('app.via_rpc', 'true', true);
    UPDATE refill_dispatching SET packed = true, picked_up = true, dispatched = true, item_added = true, filled_quantity = 0,
           pack_outcome = 'partial', remainder_credited = true WHERE dispatch_id = v_id;
    SELECT warehouse_stock, consumer_stock INTO s0, c0 FROM warehouse_inventory WHERE wh_inventory_id = v_lot;
    r := public.driver_report_dispatch_outcome(v_id, 'no_stock_on_truck', NULL);
    ok5 := r->>'status' = 'recorded';
    r := public.amend_dispatch_after_pickup(v_id, NULL, NULL, true, 'PRD-145 P3-5 test void', NULL);
    SELECT * INTO rd FROM refill_dispatching WHERE dispatch_id = v_id;
    SELECT warehouse_stock, consumer_stock INTO s1, c1 FROM warehouse_inventory WHERE wh_inventory_id = v_lot;
    ok5 := ok5 AND r->>'status' = 'ok' AND NOT rd.include AND s1 = s0 AND c1 = c0;
    e5 := format('void %s include %s stock %s->%s', r->>'status', rd.include, s0, s1);
  EXCEPTION WHEN OTHERS THEN e5 := SQLERRM; END;

  -- 6. a returned not_filled fill line is not in the warehouse return-ack queue
  BEGIN
    PERFORM set_config('app.via_rpc', 'true', true);
    UPDATE refill_dispatching SET include = true, returned = true, quantity = 1, pack_outcome = 'not_filled' WHERE dispatch_id = v_id;
    ok6 := NOT EXISTS (SELECT 1 FROM v_wm_confirmations WHERE dispatch_id = v_id);
    UPDATE refill_dispatching SET pack_outcome = 'partial' WHERE dispatch_id = v_id;
    ok6 := ok6 AND EXISTS (SELECT 1 FROM v_wm_confirmations WHERE dispatch_id = v_id);  -- control: a partial return still shows
    e6 := 'queue checked';
  EXCEPTION WHEN OTHERS THEN e6 := SQLERRM; END;

  -- 7. the sweep closed every partial 0-filled undelivered row since 1 Oct
  SELECT count(*) = 0, format('%s left', count(*)) INTO ok7, e7 FROM refill_dispatching
   WHERE dispatch_date >= DATE '2026-10-01' AND dispatch_date < current_date + 1
     AND pack_outcome = 'partial' AND filled_quantity = 0 AND driver_outcome IS NULL AND delivered_at IS NULL;

  RAISE EXCEPTION 'PRD145_P3_5 % | pack0 %:% | receive0 %:% | no_double %:% | driver_not_done %:% | void %:% | ea944182_shape %:% | wm_queue %:% | sweep %:%',
    CASE WHEN ok1 AND ok2 AND ok2b AND ok3 AND ok4 AND ok5 AND ok6 AND ok7 THEN 'PASS' ELSE 'FAIL' END,
    ok1, e1, ok2, e2, ok2b, e2b, ok3, e3, ok4, e4, ok5, e5, ok6, e6, ok7, e7;
END
$t$;
