-- PRD-144 P2-2 test: M2M legs from WEIMI. Source SAP-2002 B07 (WEIMI: Smart Gourmet Hummus x4),
-- destination MINDSHARE-1009 A14. Fixtures are staged through canonical writers; ends with RAISE.
-- PASS = 'PRD144_P2_2 PASS ...'.
DO $t$
DECLARE
  v_sap uuid := 'a6c02486-5d95-42ca-9adc-bc755c3019d3'; v_ms uuid := '9a09a89b-cb1b-4588-85f3-837c481e287e';
  v_bp uuid; v_w record; r1 jsonb; r2 jsonb; e_ok text := 'no error'; e_over text := 'not refused';
  v_alerts_before int; v_alerts_after int; v_push jsonb; v_push_qty numeric; e_push text := 'no error'; v_capped int;
BEGIN
  SELECT * INTO v_w FROM weimi_lane_now(v_sap, 'B07');
  SELECT product_id INTO v_bp FROM boonz_products WHERE boonz_product_name = 'Smart Gourmet - Truffle Hummus and Pretzels';
  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
  -- pod says 0 on the source lane, WEIMI says 4 (the McVities 4-vs-7 shape)
  PERFORM public.adjust_pod_inventory('SAP-2002-0000-R1', (now() AT TIME ZONE 'Asia/Dubai')::date,
    (SELECT jsonb_agg(jsonb_build_object('boonz_product_id', pi.boonz_product_id, 'new_qty', 0, 'shelf_code', 'B07', 'expiration_date', pi.expiration_date))
       FROM pod_inventory pi JOIN shelf_configurations sc ON sc.shelf_id = pi.shelf_id
      WHERE pi.machine_id = v_sap AND sc.shelf_code = 'B07' AND pi.status = 'Active'), 'PRD-144 P2-2 fixture (rolled back)');
  SELECT count(*) INTO v_alerts_before FROM monitoring_alerts WHERE source = 'm2m_pod_weimi_drift';
  BEGIN
    r1 := public.add_dispatch_row(v_sap, 'B07', v_bp, 3, 'Remove', '2099-03-01', 'unknown', NULL, NULL, 'operator_admin', 'P2-2 test');
    r2 := public.add_dispatch_row(v_ms, 'A14', v_bp, 3, 'Refill', '2099-03-01', 'm2m', NULL, v_sap, 'operator_admin', 'P2-2 test', NULL, (r1->>'dispatch_id')::uuid);
  EXCEPTION WHEN OTHERS THEN e_ok := SQLERRM; END;
  SELECT count(*) INTO v_alerts_after FROM monitoring_alerts WHERE source = 'm2m_pod_weimi_drift';
  BEGIN
    r1 := public.add_dispatch_row(v_sap, 'B07', v_bp, 5, 'Remove', '2099-03-02', 'unknown', NULL, NULL, 'operator_admin', 'P2-2 test');
    PERFORM public.add_dispatch_row(v_ms, 'A14', v_bp, 5, 'Refill', '2099-03-02', 'm2m', NULL, v_sap, 'operator_admin', 'P2-2 test', NULL, (r1->>'dispatch_id')::uuid);
  EXCEPTION WHEN OTHERS THEN e_over := SQLERRM; END;
  -- push: a plan transfer of 6 when WEIMI shows 4
  BEGIN
    INSERT INTO refill_plan_output (plan_date, machine_name, shelf_code, pod_product_name, boonz_product_name, action, quantity, operator_status,
                                    machine_id, shelf_id, pod_product_id, boonz_product_id, source_origin, from_machine_id)
    SELECT '2099-03-03', 'SAP-2002-0000-R1', 'B07', 'Smart Gourmet Hummus', 'Smart Gourmet - Truffle Hummus and Pretzels', 'Remove', 6, 'approved',
           v_sap, sc.shelf_id, v_w.pod_product_id, v_bp, 'internal_transfer', NULL
      FROM shelf_configurations sc WHERE sc.machine_id = v_sap AND sc.shelf_code = 'B07';
    INSERT INTO refill_plan_output (plan_date, machine_name, shelf_code, pod_product_name, boonz_product_name, action, quantity, operator_status,
                                    machine_id, shelf_id, pod_product_id, boonz_product_id, source_origin, from_machine_id)
    SELECT '2099-03-03', 'MINDSHARE-1009-4500-O1', 'A14', 'Smart Gourmet Hummus', 'Smart Gourmet - Truffle Hummus and Pretzels', 'Refill', 6, 'approved',
           v_ms, sc.shelf_id, v_w.pod_product_id, v_bp, 'internal_transfer', v_sap
      FROM shelf_configurations sc WHERE sc.machine_id = v_ms AND sc.shelf_code = 'A14';
    v_push := public.push_plan_to_dispatch('2099-03-03', 'MINDSHARE-1009-4500-O1');
    SELECT quantity INTO v_push_qty FROM refill_dispatching WHERE dispatch_date = '2099-03-03' AND machine_id = v_sap AND action = 'Remove' AND is_m2m;
    SELECT count(*) INTO v_capped FROM monitoring_alerts WHERE source = 'm2m_push_capped_to_weimi' AND payload->>'plan_date' = '2099-03-03';
  EXCEPTION WHEN OTHERS THEN e_push := SQLERRM; END;
  RAISE EXCEPTION 'PRD144_P2_2 % | weimi=% x% | adr pod0/weimi4: % drift_alerts +% | adr qty5: % | push remove qty=% capped_alerts=% err=%',
    CASE WHEN e_ok = 'no error' AND v_alerts_after > v_alerts_before AND e_over LIKE '%exceeds the 4 WEIMI%'
              AND v_push_qty = 4 AND v_capped = 1 THEN 'PASS' ELSE 'FAIL' END,
    v_w.product_name, v_w.current_stock, left(e_ok, 120), v_alerts_after - v_alerts_before, left(e_over, 110), v_push_qty, v_capped, left(e_push, 160);
END $t$;
