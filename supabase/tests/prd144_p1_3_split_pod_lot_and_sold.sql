-- PRD-144 P1-3 test: split_pod_lot and record_sold_since_planning. Ends with RAISE: nothing persists.
-- PASS = 'PRD144_P1_3 PASS ...'.
DO $t$
DECLARE
  l record; rem record; r_split jsonb; r_sold jsonb; v_sum numeric; v_rows int; e_cons text := 'not refused';
  e_role text := 'not refused'; v_after numeric; v_log int;
BEGIN
  SELECT pod_inventory_id, current_stock, expiration_date, machine_id, shelf_id, boonz_product_id INTO l
    FROM pod_inventory WHERE status = 'Active' AND current_stock >= 3 AND expiration_date IS NOT NULL AND shelf_id IS NOT NULL
   ORDER BY snapshot_at DESC LIMIT 1;
  SELECT dispatch_id, quantity INTO rem FROM refill_dispatching
   WHERE action = 'Remove' AND include AND NOT COALESCE(cancelled,false) AND NOT COALESCE(returned,false)
     AND NOT COALESCE(item_added,false) AND driver_confirmed_qty IS NULL AND quantity >= 2
   ORDER BY dispatch_date DESC LIMIT 1;
  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
  BEGIN
    PERFORM public.split_pod_lot(l.pod_inventory_id, 1, l.expiration_date + 40, l.current_stock, l.expiration_date + 41, 'PRD-144 test conservation');
  EXCEPTION WHEN OTHERS THEN e_cons := SQLERRM; END;
  r_split := public.split_pod_lot(l.pod_inventory_id, 1, l.expiration_date + 40, l.current_stock - 1, l.expiration_date, 'PRD-144 test split, rolled back');
  SELECT sum(current_stock), count(*) INTO v_sum, v_rows FROM pod_inventory
   WHERE machine_id = l.machine_id AND shelf_id = l.shelf_id AND boonz_product_id = l.boonz_product_id AND status = 'Active'
     AND expiration_date IN (l.expiration_date, l.expiration_date + 40);
  r_sold := public.record_sold_since_planning(rem.dispatch_id, 1, 'PRD-144 test');
  SELECT quantity INTO v_after FROM refill_dispatching WHERE dispatch_id = rem.dispatch_id;
  SELECT count(*) INTO v_log FROM refill_dispatching_edit_log WHERE dispatch_id = rem.dispatch_id AND after_state->>'event' = 'sales_correction';
  PERFORM set_config('request.jwt.claims', '{"sub":"bf32624e-3334-425d-b694-c5944b0c66f0","role":"authenticated"}', true);
  BEGIN
    PERFORM public.record_sold_since_planning(rem.dispatch_id, 1, 'PRD-144 test role');
  EXCEPTION WHEN OTHERS THEN e_role := SQLERRM; END;
  RAISE EXCEPTION 'PRD144_P1_3 % | split % x% -> %: active rows=% sum=% | bad sum: % | sold: % -> % (log %) | warehouse: %',
    CASE WHEN v_sum >= l.current_stock AND v_rows >= 2 AND e_cons LIKE '%must equal%' AND v_after = rem.quantity - 1 AND v_log = 1
              AND e_role LIKE '%forbidden%' THEN 'PASS' ELSE 'FAIL' END,
    l.expiration_date, l.current_stock, r_split->'parts', v_rows, v_sum, left(e_cons, 90), rem.quantity, v_after, v_log, left(e_role, 80);
END $t$;
