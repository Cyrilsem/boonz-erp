-- PRD-144 P0-4 regression: the warehouse metadata-edit payload against adjust_warehouse_stock.
-- Runs as the warehouse manager and always ends with RAISE, so nothing persists.
-- Old FE payload (p_snapshot_date NULL, no new_consumer_stock) must fail with the snapshot_date error;
-- the fixed payload must succeed and leave consumer_stock unchanged.
-- PASS = 'PRD144_P0_4 PASS ...'.
DO $t$
DECLARE r record; e1 text := 'no error'; e2 text := 'no error'; cs_after numeric; res2 jsonb;
BEGIN
  SELECT wh_inventory_id, warehouse_id, boonz_product_id, warehouse_stock, consumer_stock, status INTO r
    FROM warehouse_inventory WHERE status = 'Active' AND consumer_stock > 0 AND warehouse_stock > 0 LIMIT 1;
  PERFORM set_config('request.jwt.claims', '{"sub":"bf32624e-3334-425d-b694-c5944b0c66f0","role":"authenticated"}', true);
  BEGIN
    PERFORM public.adjust_warehouse_stock(r.warehouse_id,
      jsonb_build_array(jsonb_build_object('boonz_product_id', r.boonz_product_id, 'wh_inventory_id', r.wh_inventory_id,
        'new_warehouse_stock', r.warehouse_stock, 'status', r.status, 'wh_location', 'PRD144-TEST')), NULL, 'prd144 p0-4 old payload');
  EXCEPTION WHEN OTHERS THEN e1 := SQLERRM; END;
  BEGIN
    res2 := public.adjust_warehouse_stock(r.warehouse_id,
      jsonb_build_array(jsonb_build_object('boonz_product_id', r.boonz_product_id, 'wh_inventory_id', r.wh_inventory_id,
        'new_warehouse_stock', r.warehouse_stock, 'new_consumer_stock', r.consumer_stock, 'status', r.status, 'wh_location', 'PRD144-TEST')),
      (now() AT TIME ZONE 'Asia/Dubai')::date, 'prd144 p0-4 fixed payload');
    SELECT consumer_stock INTO cs_after FROM warehouse_inventory WHERE wh_inventory_id = r.wh_inventory_id;
  EXCEPTION WHEN OTHERS THEN e2 := SQLERRM; END;
  RAISE EXCEPTION 'PRD144_P0_4 % old_payload_error=% | fixed_error=% consumer_stock % -> %',
    CASE WHEN e1 LIKE '%snapshot_date%' AND e2 = 'no error' AND cs_after = r.consumer_stock THEN 'PASS' ELSE 'FAIL' END,
    e1, e2, r.consumer_stock, cs_after;
END $t$;
