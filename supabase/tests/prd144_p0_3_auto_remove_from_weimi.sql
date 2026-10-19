-- PRD-144 P0-3 test: auto-Remove legs come from WEIMI, not pod_inventory.
-- Case 1 (SAP B07): the pod row says a different product x9 (staged inside this transaction), WEIMI
--   says Smart Gourmet Hummus x4. The swap's Remove leg must be a Smart Gourmet Hummus variant x4.
-- Case 2: a lane WEIMI shows at 0 gets no Remove leg and the warning "lane empty per WEIMI".
-- Ends with RAISE, so nothing persists. PASS = 'PRD144_P0_3 PASS ...'.
DO $t$
DECLARE
  v_sap uuid := 'a6c02486-5d95-42ca-9adc-bc755c3019d3';
  v_b07 uuid; v_res jsonb; v_leg record; v_w record; e record; v_res2 jsonb; v_new_pod uuid; v_ok1 boolean; v_ok2 boolean;
BEGIN
  SELECT shelf_id INTO v_b07 FROM shelf_configurations WHERE machine_id = v_sap AND shelf_code = 'B07';
  SELECT * INTO v_w FROM weimi_lane_now(v_sap, 'B7');
  -- the "pod says Granola 9" side: a product that is not on the WEIMI pod's mapping
  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
  -- staged through the canonical writer; the final RAISE rolls it back
  PERFORM public.adjust_pod_inventory('SAP-2002-0000-R1', (now() AT TIME ZONE 'Asia/Dubai')::date,
    '[{"boonz_product_id":"dc368bf2-3da1-442e-82af-f2bb30cc9c96","new_qty":9,"shelf_code":"B07","expiration_date":"2027-01-01"}]'::jsonb,
    'PRD-144 P0-3 test fixture (rolled back)');
  SELECT pod_product_id INTO v_new_pod FROM pod_products WHERE pod_product_name <> v_w.product_name
     AND pod_product_id <> '1eaa0773-ddda-411a-9ba6-3d2d3e3c6584' ORDER BY pod_product_name LIMIT 1;

  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
  v_res := public.ensure_swap_remove_leg(v_sap, 'B7', v_new_pod, '2099-02-01'::date);
  SELECT rd.quantity, bp.boonz_product_name, pp.pod_product_name, rd.action INTO v_leg
    FROM refill_dispatching rd JOIN boonz_products bp ON bp.product_id = rd.boonz_product_id
    LEFT JOIN pod_products pp ON pp.pod_product_id = rd.pod_product_id
   WHERE rd.dispatch_id = (v_res->'remove_legs'->0->>'dispatch_id')::uuid;
  v_ok1 := v_leg.action = 'Remove' AND v_leg.quantity = v_w.current_stock
           AND EXISTS (SELECT 1 FROM product_mapping pm WHERE pm.pod_product_id = v_w.pod_product_id AND pm.status = 'Active'
                        AND pm.boonz_product_id = (SELECT boonz_product_id FROM refill_dispatching
                                                    WHERE dispatch_id = (v_res->'remove_legs'->0->>'dispatch_id')::uuid));

  -- case 2: any lane whose latest WEIMI row shows 0
  SELECT sc.machine_id, sc.shelf_code INTO e
    FROM shelf_configurations sc
    JOIN LATERAL weimi_lane_now(sc.machine_id, sc.shelf_code) w ON true
   WHERE w.current_stock = 0 AND w.snapshot_at > now() - interval '2 days' AND NOT sc.is_phantom
   LIMIT 1;
  v_res2 := public.ensure_swap_remove_leg(e.machine_id, e.shelf_code, v_new_pod, '2099-02-01'::date);
  v_ok2 := v_res2->>'status' = 'lane_empty' AND v_res2->>'warning' = 'lane empty per WEIMI'
           AND NOT EXISTS (SELECT 1 FROM refill_dispatching WHERE machine_id = e.machine_id AND dispatch_date = '2099-02-01' AND action = 'Remove');

  RAISE EXCEPTION 'PRD144_P0_3 % weimi=% x% leg=% x% (%) | empty_lane=% %',
    CASE WHEN v_ok1 AND v_ok2 THEN 'PASS' ELSE 'FAIL' END,
    v_w.product_name, v_w.current_stock, v_leg.boonz_product_name, v_leg.quantity, v_res->>'source',
    e.shelf_code, v_res2;
END
$t$;
