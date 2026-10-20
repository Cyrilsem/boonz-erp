-- PRD-145 P3-7 test. Run after the migration in one transaction; ends with RAISE so nothing persists.
-- PASS = 'PRD145_P3_7 PASS ...'. Fixture: NOOK-1019-0200-B1 as it stood on 20 Oct after the refill (A12 now Krambals in
-- WEIMI, Popit rows still Active in pod_inventory) and AMZ-1038-3001-O1 with a line put in the van today.
DO $t$
DECLARE
  c_nook uuid := (SELECT machine_id FROM machines WHERE official_name = 'NOOK-1019-0200-B1');
  c_amz  uuid := (SELECT machine_id FROM machines WHERE official_name = 'AMZ-1038-3001-O1');
  c_bp   uuid := '525b317b-e390-4439-aa08-367e0cd6ea5c';
  c_wh   uuid := '4bebef68-9e36-4a5c-9c2c-142f8dbdae85';
  v_before int; v_after int; v_mapped_before int; v_mapped_after int; r jsonb; v_id uuid; v_lot uuid; v_n int;
  ok1 boolean := false; ok2 boolean := false; ok3 boolean := false; ok4 boolean := false; ok5 boolean := false;
  e1 text; e2 text; e3 text; e4 text; e5 text;
BEGIN
  -- 1. the 20 Oct NOOK A12 shape is reported: Popit rows on a lane WEIMI shows as Krambals
  SELECT count(*) INTO v_before FROM public.get_pod_orphan_rows(c_nook);
  SELECT count(*) INTO v_n FROM public.get_pod_orphan_rows(c_nook)
   WHERE shelf_code = 'A12' AND boonz_product_name LIKE 'Popit%' AND weimi_product_name = 'Krambals'
     AND reason = 'not_mapped_to_weimi_pod';
  ok1 := v_before > 0 AND v_n = 2;
  e1 := format('%s orphan rows, %s Popit on A12', v_before, v_n);

  -- 2. a warehouse user cannot clear
  PERFORM set_config('request.jwt.claims', '{"sub":"7f4ecaa4-1efe-4a32-b233-35f5516f6131","role":"authenticated"}', true);
  BEGIN
    PERFORM public.clear_pod_orphan_rows(c_nook, 'PRD-145 P3-7 test');
    e2 := 'accepted';
  EXCEPTION WHEN OTHERS THEN ok2 := SQLERRM LIKE '%operator_admin only%'; e2 := SQLERRM; END;

  -- 3. operator_admin clears NOOK: every orphan row goes to 0 through adjust_pod_inventory, mapped rows are untouched
  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
  BEGIN
    SELECT count(*) INTO v_mapped_before FROM pod_inventory WHERE machine_id = c_nook AND status = 'Active' AND current_stock > 0;
    r := public.clear_pod_orphan_rows(c_nook, 'PRD-145 P3-7 test');
    SELECT count(*) INTO v_after FROM public.get_pod_orphan_rows(c_nook);
    SELECT count(*) INTO v_mapped_after FROM pod_inventory WHERE machine_id = c_nook AND status = 'Active' AND current_stock > 0;
    SELECT count(*) INTO v_n FROM pod_inventory_audit_log
     WHERE machine_id = c_nook AND notes LIKE '%PRD-145 P3-7 pod rows off WEIMI%' AND new_stock = 0;
    ok3 := r->>'status' = 'ok' AND (r->>'rows')::int = v_before AND v_after = 0
           AND v_mapped_after = v_mapped_before - v_before AND v_n = v_before;
    e3 := format('%s cleared %s, left %s, active rows %s -> %s, audit %s', r->>'status', r->>'rows', v_after, v_mapped_before, v_mapped_after, v_n);
  EXCEPTION WHEN OTHERS THEN e3 := SQLERRM; END;

  -- 4. a refill in the van blocks the clear (a refill is never reverted)
  BEGIN
    r := public.add_dispatch_row(c_amz, 'A15', c_bp, 1, 'Refill', (now() AT TIME ZONE 'Asia/Dubai')::date, 'wh', c_wh, NULL, 'operator_admin', 'PRD-145 P3-7 test', NULL, NULL);
    v_id := (r->>'dispatch_id')::uuid;
    SELECT p.wh_inventory_id INTO v_lot FROM v_wh_pickable p WHERE p.boonz_product_id = c_bp AND p.warehouse_id = c_wh
     ORDER BY p.expiration_date LIMIT 1;
    PERFORM public.pack_dispatch_line(v_id, jsonb_build_array(jsonb_build_object('wh_inventory_id', v_lot, 'qty', 1, 'boonz_product_id', c_bp)), NULL);
    PERFORM public.clear_pod_orphan_rows(c_amz, 'PRD-145 P3-7 test');
    e4 := 'accepted';
  EXCEPTION WHEN OTHERS THEN ok4 := SQLERRM LIKE '%still in the van%'; e4 := SQLERRM; END;

  -- 5. the nightly count lands in monitoring_alerts and the Pending summary reads it back
  BEGIN
    PERFORM public.record_pod_orphan_counts();
    SELECT count(*) INTO v_n FROM public.get_pod_orphan_summary() WHERE nightly_rows IS NOT NULL AND nightly_rows = orphan_rows;
    ok5 := v_n > 0 AND EXISTS (SELECT 1 FROM monitoring_alerts WHERE source = 'pod_orphan_rows_nightly' AND created_at = now());
    e5 := format('%s machines with nightly = live', v_n);
  EXCEPTION WHEN OTHERS THEN e5 := SQLERRM; END;

  RAISE EXCEPTION 'PRD145_P3_7 % | nook_a12 %:% | warehouse_refused %:% | clear %:% | van_gate %:% | nightly %:%',
    CASE WHEN ok1 AND ok2 AND ok3 AND ok4 AND ok5 THEN 'PASS' ELSE 'FAIL' END, ok1, e1, ok2, e2, ok3, e3, ok4, e4, ok5, e5;
END
$t$;
