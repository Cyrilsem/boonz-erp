-- PRD-144 P2-3 test: one case per source_kind. Fingerprint = every warehouse_inventory row of the product
-- (id, warehouse_stock, consumer_stock). Ends with RAISE: nothing persists. PASS = 'PRD144_P2_3 PASS ...'.
DO $t$
DECLARE
  fp_before text; fp_after_pack text; fp_after_recv text; r jsonb; l record; v_pick uuid; v_wh_b record; v_wh_a record;
  wh_ok boolean; venue_ok boolean; m2m_ok boolean; intra_ok boolean; dfc_left int; v_rem jsonb; v_add jsonb; f record; im record; v_im jsonb; v_im_add uuid;
  e_pack text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);

  -- wh: pack 1 unit from the bound/FEFO row, then receive it: that row's warehouse_stock -1, consumer back to start.
  SELECT rd.* INTO l FROM refill_dispatching rd
   WHERE rd.source_kind = 'wh' AND NOT rd.packed AND rd.include AND NOT COALESCE(rd.skipped,false) AND NOT COALESCE(rd.cancelled,false)
     AND rd.action IN ('Refill','Add New') AND rd.dispatch_date >= '2026-10-12'
     AND EXISTS (SELECT 1 FROM v_wh_pickable vp WHERE vp.boonz_product_id = rd.boonz_product_id AND vp.warehouse_stock >= 1
                   AND (vp.reserved_for_machine_id IS NULL OR vp.reserved_for_machine_id = rd.machine_id)) LIMIT 1;
  SELECT vp.wh_inventory_id INTO v_pick FROM v_wh_pickable vp WHERE vp.boonz_product_id = l.boonz_product_id AND vp.warehouse_stock >= 1
     AND (vp.reserved_for_machine_id IS NULL OR vp.reserved_for_machine_id = l.machine_id)
   ORDER BY (vp.wh_inventory_id = l.from_wh_inventory_id) DESC NULLS LAST, vp.expiration_date LIMIT 1;
  SELECT warehouse_stock, consumer_stock INTO v_wh_b FROM warehouse_inventory WHERE wh_inventory_id = v_pick;
  r := public.pack_dispatch_line(l.dispatch_id, jsonb_build_array(jsonb_build_object('wh_inventory_id', v_pick, 'qty', 1, 'boonz_product_id', l.boonz_product_id)), NULL);
  PERFORM public.receive_dispatch_line(l.dispatch_id, 1, auth.uid(), NULL, true, 'PRD-144 P2-3 test');
  SELECT warehouse_stock, consumer_stock INTO v_wh_a FROM warehouse_inventory WHERE wh_inventory_id = v_pick;
  wh_ok := r->>'status' = 'packed' AND v_wh_a.warehouse_stock = v_wh_b.warehouse_stock - 1 AND v_wh_a.consumer_stock = v_wh_b.consumer_stock;

  -- venue: pack 1 and receive 1: no warehouse_inventory row of the product changes.
  SELECT rd.* INTO l FROM refill_dispatching rd
   WHERE rd.source_kind = 'venue' AND NOT rd.packed AND rd.include AND NOT COALESCE(rd.skipped,false) AND NOT COALESCE(rd.cancelled,false)
     AND rd.action IN ('Refill','Add New') AND rd.dispatch_date >= '2026-10-12' LIMIT 1;
  SELECT md5(string_agg(wh_inventory_id || ':' || COALESCE(warehouse_stock,0) || ':' || COALESCE(consumer_stock,0), ',' ORDER BY wh_inventory_id)) INTO fp_before
    FROM warehouse_inventory WHERE boonz_product_id = l.boonz_product_id;
  r := public.pack_dispatch_line(l.dispatch_id, jsonb_build_array(jsonb_build_object('wh_inventory_id', l.dispatch_id, 'qty', 1, 'boonz_product_id', l.boonz_product_id)), NULL);
  SELECT md5(string_agg(wh_inventory_id || ':' || COALESCE(warehouse_stock,0) || ':' || COALESCE(consumer_stock,0), ',' ORDER BY wh_inventory_id)) INTO fp_after_pack
    FROM warehouse_inventory WHERE boonz_product_id = l.boonz_product_id;
  PERFORM public.receive_dispatch_line(l.dispatch_id, 1, auth.uid(), NULL, true, 'PRD-144 P2-3 test');
  SELECT md5(string_agg(wh_inventory_id || ':' || COALESCE(warehouse_stock,0) || ':' || COALESCE(consumer_stock,0), ',' ORDER BY wh_inventory_id)) INTO fp_after_recv
    FROM warehouse_inventory WHERE boonz_product_id = l.boonz_product_id;
  venue_ok := r->>'status' = 'packed' AND fp_after_pack = fp_before AND fp_after_recv = fp_before;

  -- m2m: a fresh pair (born packed), receive the destination leg: no warehouse_inventory change.
  SELECT s.machine_id src, scs.shelf_code src_shelf, d.machine_id dst, scd.shelf_code dst_shelf, s.boonz_product_id bp INTO f
    FROM pod_inventory s JOIN shelf_configurations scs ON scs.shelf_id = s.shelf_id
    JOIN pod_inventory d ON d.boonz_product_id = s.boonz_product_id AND d.machine_id <> s.machine_id AND d.status = 'Active'
    JOIN shelf_configurations scd ON scd.shelf_id = d.shelf_id
    JOIN slot_lifecycle sl ON sl.shelf_id = d.shelf_id AND sl.is_current AND NOT sl.archived
    JOIN product_mapping pm ON pm.pod_product_id = sl.pod_product_id AND pm.boonz_product_id = s.boonz_product_id AND pm.status = 'Active'
    JOIN slot_lifecycle sls ON sls.shelf_id = s.shelf_id AND sls.is_current AND NOT sls.archived AND sls.pod_product_id = sl.pod_product_id
    JOIN LATERAL weimi_lane_now(s.machine_id, scs.shelf_code) w ON w.current_stock >= 2 AND w.pod_product_id = sl.pod_product_id
   WHERE s.status = 'Active' AND s.current_stock > 3 LIMIT 1;
  v_rem := public.add_dispatch_row(f.src, f.src_shelf, f.bp, 2, 'Remove', '2099-03-04', 'unknown', NULL, NULL, 'operator_admin', 'P2-3 test');
  v_add := public.add_dispatch_row(f.dst, f.dst_shelf, f.bp, 2, 'Refill', '2099-03-04', 'm2m', NULL, f.src, 'operator_admin', 'P2-3 test', NULL, (v_rem->>'dispatch_id')::uuid);
  SELECT md5(string_agg(wh_inventory_id || ':' || COALESCE(warehouse_stock,0) || ':' || COALESCE(consumer_stock,0), ',' ORDER BY wh_inventory_id)) INTO fp_before
    FROM warehouse_inventory WHERE boonz_product_id = f.bp;
  PERFORM public.receive_dispatch_line((v_add->>'dispatch_id')::uuid, 2, auth.uid(), NULL, true, 'PRD-144 P2-3 test');
  SELECT md5(string_agg(wh_inventory_id || ':' || COALESCE(warehouse_stock,0) || ':' || COALESCE(consumer_stock,0), ',' ORDER BY wh_inventory_id)) INTO fp_after_recv
    FROM warehouse_inventory WHERE boonz_product_id = f.bp;
  m2m_ok := fp_after_recv = fp_before;

  -- intra_machine: a fresh move on the same shelves as a real one, receive the Add New leg: no warehouse_inventory change.
  SELECT a.machine_id, sa.shelf_code from_code, sb.shelf_code to_code, a.boonz_product_id INTO im
    FROM refill_dispatching a JOIN refill_dispatching b ON b.machine_id = a.machine_id AND b.dispatch_date = a.dispatch_date
     AND b.boonz_product_id = a.boonz_product_id AND b.source_kind = 'intra_machine' AND b.action = 'Add New'
    JOIN shelf_configurations sa ON sa.shelf_id = a.shelf_id JOIN shelf_configurations sb ON sb.shelf_id = b.shelf_id
   WHERE a.source_kind = 'intra_machine' AND a.action = 'Remove' LIMIT 1;
  v_im := public.add_intra_machine_move(im.machine_id, im.from_code, im.to_code, im.boonz_product_id, 1, '2099-03-05', 'PRD-144 P2-3 test');
  SELECT dispatch_id INTO v_im_add FROM refill_dispatching WHERE machine_id = im.machine_id AND dispatch_date = '2099-03-05'
     AND action = 'Add New' AND source_kind = 'intra_machine' LIMIT 1;
  SELECT md5(string_agg(wh_inventory_id || ':' || COALESCE(warehouse_stock,0) || ':' || COALESCE(consumer_stock,0), ',' ORDER BY wh_inventory_id)) INTO fp_before
    FROM warehouse_inventory WHERE boonz_product_id = im.boonz_product_id;
  BEGIN
    PERFORM public.receive_dispatch_line(v_im_add, 1, auth.uid(), NULL, true, 'PRD-144 P2-3 test');
  EXCEPTION WHEN OTHERS THEN e_pack := SQLERRM; END;
  SELECT md5(string_agg(wh_inventory_id || ':' || COALESCE(warehouse_stock,0) || ':' || COALESCE(consumer_stock,0), ',' ORDER BY wh_inventory_id)) INTO fp_after_recv
    FROM warehouse_inventory WHERE boonz_product_id = im.boonz_product_id;
  intra_ok := v_im_add IS NOT NULL AND e_pack IS NULL AND fp_after_recv = fp_before;

  SELECT count(*) INTO dfc_left FROM warehouse_inventory wi JOIN warehouses w USING (warehouse_id)
   WHERE w.name = 'WH_DFC' AND wi.status = 'Active' AND wi.expiration_date = '2029-09-27';

  RAISE EXCEPTION 'PRD144_P2_3 % | wh=% (row % -> %) | venue=% | m2m=% | intra_machine=% % | WH_DFC rows still 2029: %',
    CASE WHEN wh_ok AND venue_ok AND m2m_ok AND intra_ok AND dfc_left = 0 THEN 'PASS' ELSE 'FAIL' END,
    wh_ok, row_to_json(v_wh_b), row_to_json(v_wh_a), venue_ok, m2m_ok, intra_ok, COALESCE(left(e_pack, 100), ''), dfc_left;
END $t$;
