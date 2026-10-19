-- PRD-144 P1-5 test: Date read on a no-date lot merges into the existing lot with that date.
-- MINDSHARE-1009 A09 Loacker Creamkakao: no-date lot 11 + lot 6 on 2027-04-24 (staged by adjust_pod_inventory),
-- Date read 2027-04-24, expect one lot of 17. Also: a p_actor that is not the caller is refused.
-- Ends with RAISE: nothing persists. PASS = 'PRD144_P1_5 PASS ...'.
DO $t$
DECLARE v_m uuid := '9a09a89b-cb1b-4588-85f3-837c481e287e'; v_bp uuid; v_nodate uuid; v_n int; v_qty numeric; e_actor text := 'not refused'; v_other uuid;
BEGIN
  SELECT pi.boonz_product_id INTO v_bp FROM pod_inventory pi WHERE pi.pod_inventory_id = 'cc903822-0d1c-4d61-a08a-9c4ef22805a2';
  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
  PERFORM public.adjust_pod_inventory('MINDSHARE-1009-4500-O1', (now() AT TIME ZONE 'Asia/Dubai')::date,
    jsonb_build_array(jsonb_build_object('boonz_product_id', v_bp, 'new_qty', 6, 'shelf_code', 'A09', 'expiration_date', '2027-04-24'),
                      jsonb_build_object('boonz_product_id', v_bp, 'new_qty', 11, 'shelf_code', 'A09')), 'PRD-144 P1-5 fixture (rolled back)');
  SELECT pod_inventory_id INTO v_nodate FROM pod_inventory WHERE machine_id = v_m AND boonz_product_id = v_bp AND status = 'Active' AND expiration_date IS NULL;
  SELECT id INTO v_other FROM user_profiles WHERE id <> '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d' LIMIT 1;
  BEGIN PERFORM public.apply_expiry_check(v_nodate, 'date_read', NULL, '2027-04-24', v_other, false);
  EXCEPTION WHEN OTHERS THEN e_actor := SQLERRM; END;
  PERFORM public.apply_expiry_check(v_nodate, 'date_read', NULL, '2027-04-24', NULL, false);
  SELECT count(*), sum(current_stock) INTO v_n, v_qty FROM pod_inventory
   WHERE machine_id = v_m AND boonz_product_id = v_bp AND status = 'Active' AND expiration_date = '2027-04-24';
  RAISE EXCEPTION 'PRD144_P1_5 % | 2027-04-24 lots=% qty=% | actor=%',
    CASE WHEN v_n = 1 AND v_qty = 17 AND NOT EXISTS (SELECT 1 FROM pod_inventory WHERE pod_inventory_id = v_nodate AND status = 'Active')
              AND e_actor LIKE '%p_actor must be%' THEN 'PASS' ELSE 'FAIL' END, v_n, v_qty, left(e_actor, 70);
END $t$;
