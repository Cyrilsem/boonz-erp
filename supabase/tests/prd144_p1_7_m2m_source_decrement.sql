-- PRD-144 P1-7 part 1 test. Fixture: AMZ-1029-3003-O1 A16 Vitamin Well - Care, two open M2M source legs from 6 Oct
-- with received destinations: d011c485 (0 units) and 4c118dac (3 units). approve_m2m_transfer receives each source
-- leg. Expect: the 0-unit close leaves the lane's Care stock unchanged (it used to archive every lot), the 3-unit
-- close takes exactly 3 off the lane earliest expiry first, and warehouse_inventory does not move.
-- Ends with RAISE: nothing persists. PASS = 'PRD144_P1_7_DECREMENT PASS ...'.
DO $t$
DECLARE
  c_m  uuid := 'f1a528fb-15e8-4f20-b4e2-ebb2e6852198';
  c_sh uuid := 'e96d1c31-13d0-4907-9438-428017586da8';
  c_bp uuid := '098c5852-1a9f-4b7a-a6de-578fb9a2d640';
  c_t0 uuid := 'd011c485-76bf-4757-a7f6-c3c5aad4d359';
  c_t3 uuid := '4c118dac-fd17-4e07-8cc0-bf366c7514aa';
  r0 jsonb; r3 jsonb; s0 numeric; s1 numeric; s2 numeric; fp_b text; fp_a text; e text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
  SELECT md5(string_agg(wh_inventory_id || ':' || COALESCE(warehouse_stock,0) || ':' || COALESCE(consumer_stock,0) || ':' || status, ',' ORDER BY wh_inventory_id))
    INTO fp_b FROM warehouse_inventory WHERE boonz_product_id = c_bp;
  SELECT COALESCE(SUM(current_stock), 0) INTO s0 FROM pod_inventory WHERE machine_id = c_m AND shelf_id = c_sh AND boonz_product_id = c_bp AND status = 'Active';
  BEGIN
    r0 := public.approve_m2m_transfer(c_t0, auth.uid());
    SELECT COALESCE(SUM(current_stock), 0) INTO s1 FROM pod_inventory WHERE machine_id = c_m AND shelf_id = c_sh AND boonz_product_id = c_bp AND status = 'Active';
    r3 := public.approve_m2m_transfer(c_t3, auth.uid());
    SELECT COALESCE(SUM(current_stock), 0) INTO s2 FROM pod_inventory WHERE machine_id = c_m AND shelf_id = c_sh AND boonz_product_id = c_bp AND status = 'Active';
  EXCEPTION WHEN OTHERS THEN e := SQLERRM; END;
  SELECT md5(string_agg(wh_inventory_id || ':' || COALESCE(warehouse_stock,0) || ':' || COALESCE(consumer_stock,0) || ':' || status, ',' ORDER BY wh_inventory_id))
    INTO fp_a FROM warehouse_inventory WHERE boonz_product_id = c_bp;
  RAISE EXCEPTION 'PRD144_P1_7_DECREMENT % | lane % -> % (0-unit close) -> % (3-unit close) | approve % / % | wh_unchanged % | err %',
    CASE WHEN e IS NULL AND r0->>'status' = 'approved' AND r3->>'status' = 'approved' AND s1 = s0 AND s2 = s0 - 3 AND fp_a = fp_b
         THEN 'PASS' ELSE 'FAIL' END,
    s0, s1, s2, r0->>'status', r3->>'status', fp_a = fp_b, COALESCE(left(e, 200), 'none');
END $t$;
