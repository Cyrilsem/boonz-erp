-- PRD-144 P1-6 test. Fixture: MINDSHARE-1009-4500-O1 A14 to SAP-2002-0000-R1 B15 Hunter Ridge legs, 19 Oct.
--   source Remove legs: 5044aa0a Sour Cream & Onion, 1d07bc75 Hot N Sweet, 5923b79d Himalayan Pink Salt
--   destination legs:   9dd96a7c (3),            b33c0a4d (2),          c733dd38 (1)
-- 1. receive_dispatch_line on a source Remove leg is refused; warehouse_inventory unchanged.
-- 2. wh_approve_remove_receipt on it is refused.
-- 3. v_wm_confirmations lists no is_m2m / m2m / intra_machine dispatch row.
-- 4. receive_all_dispatches_for_machine skips the M2M legs instead of aborting.
-- 5. Mirror: the source legs put back to the driver's 0/0/6 and the destination legs un-received; receiving the
--    destination at 3/2/1 sets the source legs (quantity and driver confirmation) to 3/2/1.
-- 6. approve_m2m_transfer still closes the pair with no warehouse movement.
-- Ends with RAISE: nothing persists. PASS = 'PRD144_P1_6 PASS ...'.
DO $t$
DECLARE
  c_mind uuid := '9a09a89b-cb1b-4588-85f3-837c481e287e';
  c_src uuid[] := ARRAY['5044aa0a-da38-4873-b501-92306222b01a','1d07bc75-cfe5-4494-9dd9-ed4798f080c3','5923b79d-9032-49b6-8085-5e6249afa164']::uuid[];
  c_dst uuid[] := ARRAY['9dd96a7c-8a7e-4fc4-885e-5077f7be75b0','b33c0a4d-287c-419c-b2e9-525840b4d3d2','c733dd38-3791-48ad-9f0d-ca0ec26ea949']::uuid[];
  c_tid uuid := '2df5029c-7093-4d2a-b48b-ba411e490fe9';
  v_bps uuid[];
  r jsonb; n int; i int;
  fp_b text; fp_a text; fp_c text;
  ok_recv boolean := false; ok_wh boolean := false; ok_view boolean := false; ok_all boolean := false;
  ok_mirror boolean := false; ok_close boolean := false; ok_fp boolean := false;
  e_recv text; e_wh text; e_view text; e_all text; e_mirror text; e_close text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
  SELECT array_agg(DISTINCT boonz_product_id) INTO v_bps FROM refill_dispatching WHERE dispatch_id = ANY (c_src);
  SELECT md5(string_agg(wh_inventory_id || ':' || COALESCE(warehouse_stock,0) || ':' || COALESCE(consumer_stock,0) || ':' || status, ',' ORDER BY wh_inventory_id))
    INTO fp_b FROM warehouse_inventory WHERE boonz_product_id = ANY (v_bps);

  -- 1. receive on the source Remove leg
  BEGIN
    r := public.receive_dispatch_line(c_src[1], 3, auth.uid(), NULL);
    e_recv := 'not refused: ' || left(r::text, 200);
  EXCEPTION WHEN OTHERS THEN
    ok_recv := SQLERRM LIKE '%machine-to-machine transfer leg%';
    e_recv := left(SQLERRM, 160);
  END;

  -- 2. wh_approve_remove_receipt on the same leg
  BEGIN
    r := public.wh_approve_remove_receipt(c_src[1], 3, NULL, auth.uid(), 'PRD-144 P1-6 test');
    e_wh := 'not refused: ' || left(r::text, 200);
  EXCEPTION WHEN OTHERS THEN
    ok_wh := SQLERRM LIKE '%M2M transfer leg%';
    e_wh := left(SQLERRM, 120);
  END;

  -- 3. the Warehouse Confirmations view
  SELECT count(*) INTO n FROM v_wm_confirmations v JOIN refill_dispatching rd ON rd.dispatch_id = v.dispatch_id
   WHERE COALESCE(rd.is_m2m, false) OR rd.source_kind IN ('m2m', 'intra_machine');
  ok_view := n = 0;
  e_view := format('%s m2m/intra rows in queue', n);

  -- 4. bulk receive on the source machine skips the M2M legs
  BEGIN
    r := public.receive_all_dispatches_for_machine(c_mind, DATE '2026-10-19', true);
    SELECT count(*) INTO n FROM refill_dispatching WHERE dispatch_id = ANY (c_src) AND item_added;
    ok_all := n = 0 AND (r->>'skipped_internal_moves')::int >= 3;
    e_all := format('received %s skipped %s, m2m legs received %s', r->>'received_count', r->>'skipped_internal_moves', n);
  EXCEPTION WHEN OTHERS THEN e_all := left(SQLERRM, 200);
  END;

  -- 5. mirror: back to the driver's 0/0/6 at the source and an un-received destination, then receive 3/2/1
  BEGIN
    UPDATE refill_dispatching SET driver_confirmed_qty = (ARRAY[0,0,6])[array_position(c_src, dispatch_id)]
     WHERE dispatch_id = ANY (c_src);
    UPDATE refill_dispatching SET item_added = false, filled_quantity = NULL, delivered_at = NULL
     WHERE dispatch_id = ANY (c_dst);
    FOR i IN 1 .. 3 LOOP
      PERFORM public.receive_dispatch_line(c_dst[i], (ARRAY[3,2,1])[i], auth.uid(), NULL);
    END LOOP;
    SELECT string_agg(format('%s/%s', quantity, driver_confirmed_qty), ' ' ORDER BY array_position(c_src, dispatch_id)) INTO e_mirror
      FROM refill_dispatching WHERE dispatch_id = ANY (c_src);
    ok_mirror := e_mirror = '3/3 2/2 1/1';
  EXCEPTION WHEN OTHERS THEN e_mirror := left(SQLERRM, 200);
  END;

  -- 6. the transfer closer still works, with no warehouse movement
  BEGIN
    SELECT md5(string_agg(wh_inventory_id || ':' || COALESCE(warehouse_stock,0) || ':' || COALESCE(consumer_stock,0) || ':' || status, ',' ORDER BY wh_inventory_id))
      INTO fp_c FROM warehouse_inventory WHERE boonz_product_id = ANY (v_bps);
    r := public.approve_m2m_transfer(c_tid, auth.uid());
    SELECT md5(string_agg(wh_inventory_id || ':' || COALESCE(warehouse_stock,0) || ':' || COALESCE(consumer_stock,0) || ':' || status, ',' ORDER BY wh_inventory_id))
      INTO fp_a FROM warehouse_inventory WHERE boonz_product_id = ANY (v_bps);
    SELECT count(*) INTO n FROM refill_dispatching WHERE dispatch_id = c_src[1] AND item_added;
    ok_close := r->>'status' = 'approved' AND n = 1 AND fp_a = fp_c;
    e_close := format('%s source_legs %s wh_delta %s', r->>'status', r->>'source_legs_received', r->>'wh_delta');
  EXCEPTION WHEN OTHERS THEN e_close := left(SQLERRM, 200);
  END;

  ok_fp := fp_c = fp_b;  -- steps 1 to 5 left warehouse_inventory untouched

  RAISE EXCEPTION 'PRD144_P1_6 % | receive_refused %:% | wh_approve_refused %:% | view %:% | bulk_receive %:% | mirror %:% | approve_m2m %:% | wh_unchanged %',
    CASE WHEN ok_recv AND ok_wh AND ok_view AND ok_all AND ok_mirror AND ok_close AND ok_fp THEN 'PASS' ELSE 'FAIL' END,
    ok_recv, e_recv, ok_wh, e_wh, ok_view, e_view, ok_all, e_all, ok_mirror, e_mirror, ok_close, e_close, ok_fp;
END
$t$;
