-- PRD-144 P1-7 test. Fixture: AMZ-1029-3003-O1 A16 Vitamin Well - Care, two open M2M source legs from 6 Oct whose
-- destinations are received: d011c485 (0 units) and 4c118dac (3 units). The shelf holds Active Care lots.
-- 1. get_open_m2m_transfers lists both transfers.
-- 2. close_m2m_transfer as the warehouse manager is refused (operator_admin only).
-- 3. Closing the 0-unit transfer leaves the source lane's Care stock unchanged (it used to archive every lot).
-- 4. Closing the 3-unit transfer takes exactly 3 off the lane, earliest expiry first; warehouse_inventory unchanged.
-- 5. Closing it again is refused (no open source leg).
-- Ends with RAISE: nothing persists. PASS = 'PRD144_P1_7 PASS ...'.
DO $t$
DECLARE
  c_m   uuid := 'f1a528fb-15e8-4f20-b4e2-ebb2e6852198';
  c_sh  uuid := 'e96d1c31-13d0-4907-9438-428017586da8';
  c_bp  uuid := '098c5852-1a9f-4b7a-a6de-578fb9a2d640';
  c_t0  uuid := 'd011c485-76bf-4757-a7f6-c3c5aad4d359';
  c_t3  uuid := '4c118dac-fd17-4e07-8cc0-bf366c7514aa';
  r jsonb; n int;
  s0 numeric; s1 numeric; s2 numeric; fp_b text; fp_a text;
  ok_list boolean := false; ok_role boolean := false; ok_zero boolean := false; ok_three boolean := false; ok_again boolean := false;
  e_list text; e_role text; e_zero text; e_three text; e_again text;
BEGIN
  SELECT md5(string_agg(wh_inventory_id || ':' || COALESCE(warehouse_stock,0) || ':' || COALESCE(consumer_stock,0) || ':' || status, ',' ORDER BY wh_inventory_id))
    INTO fp_b FROM warehouse_inventory WHERE boonz_product_id = c_bp;
  SELECT COALESCE(SUM(current_stock), 0) INTO s0 FROM pod_inventory
   WHERE machine_id = c_m AND shelf_id = c_sh AND boonz_product_id = c_bp AND status = 'Active';

  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
  r := public.get_open_m2m_transfers(30);
  SELECT count(*) INTO n FROM jsonb_array_elements(r) x WHERE (x->>'transfer_id')::uuid IN (c_t0, c_t3);
  ok_list := n = 2;
  e_list := format('%s open transfers, fixture %s/2', jsonb_array_length(r), n);

  PERFORM set_config('request.jwt.claims', '{"sub":"bf32624e-3334-425d-b694-c5944b0c66f0","role":"authenticated"}', true);
  BEGIN
    r := public.close_m2m_transfer(c_t0, 'PRD-144 P1-7 test');
    e_role := 'not refused';
  EXCEPTION WHEN OTHERS THEN ok_role := SQLERRM LIKE '%operator_admin only%'; e_role := left(SQLERRM, 80);
  END;

  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
  BEGIN
    r := public.close_m2m_transfer(c_t0, 'PRD-144 P1-7 test');
    SELECT COALESCE(SUM(current_stock), 0) INTO s1 FROM pod_inventory
     WHERE machine_id = c_m AND shelf_id = c_sh AND boonz_product_id = c_bp AND status = 'Active';
    ok_zero := r->>'status' = 'approved' AND s1 = s0;
    e_zero := format('%s lane %s -> %s', r->>'status', s0, s1);
  EXCEPTION WHEN OTHERS THEN e_zero := left(SQLERRM, 200);
  END;

  BEGIN
    r := public.close_m2m_transfer(c_t3, 'PRD-144 P1-7 test');
    SELECT COALESCE(SUM(current_stock), 0) INTO s2 FROM pod_inventory
     WHERE machine_id = c_m AND shelf_id = c_sh AND boonz_product_id = c_bp AND status = 'Active';
    SELECT md5(string_agg(wh_inventory_id || ':' || COALESCE(warehouse_stock,0) || ':' || COALESCE(consumer_stock,0) || ':' || status, ',' ORDER BY wh_inventory_id))
      INTO fp_a FROM warehouse_inventory WHERE boonz_product_id = c_bp;
    ok_three := r->>'status' = 'approved' AND s2 = s0 - 3 AND fp_a = fp_b;
    e_three := format('%s lane %s -> %s wh_unchanged %s', r->>'status', s0, s2, fp_a = fp_b);
  EXCEPTION WHEN OTHERS THEN e_three := left(SQLERRM, 200);
  END;

  BEGIN
    r := public.close_m2m_transfer(c_t3, 'PRD-144 P1-7 test');
    e_again := 'not refused';
  EXCEPTION WHEN OTHERS THEN ok_again := SQLERRM LIKE '%no open source Remove leg%'; e_again := left(SQLERRM, 100);
  END;

  RAISE EXCEPTION 'PRD144_P1_7 % | list %:% | role %:% | zero_leg %:% | three_leg %:% | again %:%',
    CASE WHEN ok_list AND ok_role AND ok_zero AND ok_three AND ok_again THEN 'PASS' ELSE 'FAIL' END,
    ok_list, e_list, ok_role, e_role, ok_zero, e_zero, ok_three, e_three, ok_again, e_again;
END
$t$;
