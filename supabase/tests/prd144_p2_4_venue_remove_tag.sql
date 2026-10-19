-- PRD-144 P2-4 test: one case per writer of a Remove leg on a venue-sourced lane, plus receive.
-- Fixture: VOXMCC-1005-0201-B0 A05 Pepsi Black. product_mapping says 'boonz' (the post-flip state), the lane's last
-- delivered fill was vox_at_venue. The test first sets every Active mapping of the lane's product and pod to 'boonz'
-- (the state after docs/prds/PRD-144-P2-3-mapping-flip.sql), so no case can pass on the mapping tag. Control: a lane whose last delivered fill was warehouse keeps source_kind 'wh'.
-- Ends with RAISE: nothing persists. PASS = 'PRD144_P2_4 PASS ...'.
DO $t$
DECLARE
  c_m    uuid := '148c4fcf-b794-43f0-a2a8-e6f17605b045';
  c_sh   uuid := '70d9ca73-d690-4439-b568-53e3d169e9f0';
  c_code text := 'A05';
  c_bp   uuid := '4ecb8127-ccf2-4d2f-9560-8b3b825244f3';
  c_pod  uuid := '4901aaf4-a2f4-4d62-a089-d68178aa6c7f';
  c_pod_in uuid := '11b11bda-d277-4ab0-8105-595a209750ce';
  v_d date := current_date + 1;
  v_mname text; v_pname text; v_bname text;
  r jsonb; rd record; ctl record; v_rpo record; v_prp record; v_leg uuid; v_adr uuid;
  fp_b text; fp_a text;
  ok_adr boolean := false; ok_ctl boolean := false; ok_swap boolean := false; ok_wrp boolean := false;
  ok_push boolean := false; ok_fin boolean := false; ok_recv boolean := false;
  e_adr text; e_ctl text; e_swap text; e_wrp text; e_push text; e_fin text; e_recv text;
  d_push text; d_recv text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
  SELECT official_name INTO v_mname FROM machines WHERE machine_id = c_m;
  SELECT pod_product_name INTO v_pname FROM pod_products WHERE pod_product_id = c_pod;
  SELECT boonz_product_name INTO v_bname FROM boonz_products WHERE product_id = c_bp;
  UPDATE product_mapping SET source_of_supply = 'boonz'
   WHERE status = 'Active' AND (boonz_product_id = c_bp OR pod_product_id = c_pod) AND (machine_id = c_m OR machine_id IS NULL);

  -- 1. add_dispatch_row Remove (source_kind passed as 'unknown', as ensure_swap_remove_leg does)
  BEGIN
    r := public.add_dispatch_row(c_m, c_code, c_bp, 1, 'Remove', v_d, 'unknown', NULL, NULL, 'operator_admin', 'PRD-144 P2-4 test', NULL, NULL);
    v_adr := (r->>'dispatch_id')::uuid;
    SELECT * INTO rd FROM refill_dispatching WHERE dispatch_id = v_adr;
    ok_adr := rd.source_kind = 'venue' AND rd.source_origin::text = 'vox_at_venue' AND rd.source_warehouse_id IS NULL AND rd.from_warehouse_id IS NULL;
    e_adr := format('%s/%s', rd.source_kind, rd.source_origin);
  EXCEPTION WHEN OTHERS THEN e_adr := SQLERRM; END;

  -- 1b. control: add_dispatch_row Remove 'wh' on a lane last filled from the warehouse stays 'wh'
  BEGIN
    SELECT q.* INTO ctl FROM (
      SELECT DISTINCT ON (x.shelf_id) sc.shelf_code, x.boonz_product_id, x.from_warehouse_id, x.source_origin::text so
        FROM refill_dispatching x JOIN shelf_configurations sc ON sc.shelf_id = x.shelf_id
       WHERE x.machine_id = c_m AND x.action IN ('Refill','Add New') AND COALESCE(x.item_added,false) AND NOT COALESCE(x.cancelled,false)
       ORDER BY x.shelf_id, x.dispatch_date DESC, x.created_at DESC) q
     WHERE q.so = 'warehouse' AND q.from_warehouse_id IS NOT NULL LIMIT 1;
    r := public.add_dispatch_row(c_m, ctl.shelf_code, ctl.boonz_product_id, 1, 'Remove', v_d, 'wh', ctl.from_warehouse_id, NULL, 'operator_admin', 'PRD-144 P2-4 test control', NULL, NULL);
    SELECT * INTO rd FROM refill_dispatching WHERE dispatch_id = (r->>'dispatch_id')::uuid;
    ok_ctl := rd.source_kind = 'wh' AND rd.source_origin::text = 'warehouse' AND rd.source_warehouse_id = ctl.from_warehouse_id;
    e_ctl := format('%s %s/%s', ctl.shelf_code, rd.source_kind, rd.source_origin);
  EXCEPTION WHEN OTHERS THEN e_ctl := SQLERRM; END;

  -- 2. add_dispatch_row swap_remove: ensure_swap_remove_leg (lane swapped to Aquafina) writes the auto Remove
  BEGIN
    r := public.ensure_swap_remove_leg(c_m, c_code, c_pod_in, v_d);
    v_leg := (r->'remove_legs'->0->>'dispatch_id')::uuid;
    SELECT * INTO rd FROM refill_dispatching WHERE dispatch_id = v_leg;
    ok_swap := r->>'status' = 'created' AND rd.source_kind = 'venue' AND rd.source_origin::text = 'vox_at_venue';
    e_swap := format('%s %s/%s', r->>'status', rd.source_kind, rd.source_origin);
  EXCEPTION WHEN OTHERS THEN e_swap := SQLERRM; END;

  -- 3. engine_swap_pod -> engine_finalize_pod: the swap's REMOVE row in pod_refill_plan is vox_at_venue
  --    (runs before the plan cases: the engine refuses a machine-day with an approved plan row)
  BEGIN
    INSERT INTO pod_swaps(plan_date, machine_id, shelf_id, pod_product_id_out, pod_product_id_in, qty_out, qty_in, reason, substitute_source, reasoning)
    VALUES (v_d, c_m, c_sh, c_pod, c_pod_in, 1, 1, 'rotate_out', 'driver_recommendation', '{"source":"prd144_p2_4_test"}'::jsonb)
    ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id_out) DO UPDATE SET pod_product_id_in = EXCLUDED.pod_product_id_in;
    r := public.engine_finalize_pod(v_d, ARRAY[c_m]);
    SELECT * INTO v_prp FROM pod_refill_plan WHERE plan_date = v_d AND machine_id = c_m AND shelf_id = c_sh AND pod_product_id = c_pod AND action = 'REMOVE';
    ok_fin := v_prp.source_origin::text = 'vox_at_venue';
    e_fin := COALESCE(v_prp.source_origin::text, left(r::text, 300));
  EXCEPTION WHEN OTHERS THEN e_fin := SQLERRM; END;

  -- 4. write_refill_plan: a Remove line sent as source_origin 'warehouse' is stored vox_at_venue
  BEGIN
    r := public.write_refill_plan(v_d, jsonb_build_array(jsonb_build_object(
           'machine_name', v_mname, 'shelf_code', c_code, 'pod_product_name', v_pname, 'boonz_product_name', v_bname,
           'action', 'Remove', 'quantity', 1, 'source_origin', 'warehouse', 'comment', 'PRD-144 P2-4 test')));
    SELECT * INTO v_rpo FROM refill_plan_output
     WHERE plan_date = v_d AND machine_name = v_mname AND shelf_code = c_code AND action = 'Remove' AND comment LIKE 'PRD-144 P2-4 test%' LIMIT 1;
    ok_wrp := r->>'status' = 'ok' AND v_rpo.source_origin::text = 'vox_at_venue';
    e_wrp := format('%s %s', r->>'status', COALESCE(v_rpo.source_origin::text, left(r::text, 300)));
  EXCEPTION WHEN OTHERS THEN e_wrp := SQLERRM; END;

  -- 5. push_plan_to_dispatch: the same plan row forced back to 'warehouse' and approved still lands as a venue Remove
  BEGIN
    UPDATE refill_plan_output SET source_origin = 'warehouse', operator_status = 'approved' WHERE id = v_rpo.id;
    SELECT * INTO v_rpo FROM refill_plan_output WHERE id = v_rpo.id;
    IF NOT v_rpo.dispatched THEN
      r := public.push_plan_to_dispatch(v_d, v_mname);
      SELECT * INTO v_rpo FROM refill_plan_output WHERE id = v_rpo.id;
    END IF;
    SELECT * INTO rd FROM refill_dispatching WHERE dispatch_id = v_rpo.dispatch_id;
    ok_push := rd.source_kind = 'venue' AND rd.source_origin::text = 'vox_at_venue' AND rd.source_warehouse_id IS NULL;
    e_push := format('%s/%s', rd.source_kind, rd.source_origin);
    d_push := left(COALESCE(r::text, 'pushed by the approval trigger'), 200);
  EXCEPTION WHEN OTHERS THEN e_push := SQLERRM; END;

  -- 6. receive_dispatch_line: the venue Remove from case 1, packed and received, credits no warehouse row
  BEGIN
    SELECT md5(string_agg(wh_inventory_id || ':' || COALESCE(warehouse_stock,0) || ':' || COALESCE(consumer_stock,0), ',' ORDER BY wh_inventory_id)) INTO fp_b
      FROM warehouse_inventory WHERE boonz_product_id = c_bp;
    PERFORM public.pack_dispatch_line(v_adr, jsonb_build_array(jsonb_build_object('wh_inventory_id', v_adr, 'qty', 1, 'boonz_product_id', c_bp)), NULL);
    UPDATE refill_dispatching SET picked_up = true WHERE dispatch_id = v_adr;
    r := public.receive_dispatch_line(v_adr, 1, auth.uid(), NULL, true, 'PRD-144 P2-4 test');
    SELECT md5(string_agg(wh_inventory_id || ':' || COALESCE(warehouse_stock,0) || ':' || COALESCE(consumer_stock,0), ',' ORDER BY wh_inventory_id)) INTO fp_a
      FROM warehouse_inventory WHERE boonz_product_id = c_bp;
    ok_recv := fp_a = fp_b AND r->>'wh_credit_skipped' IS NOT NULL;
    e_recv := format('path %s skipped %s wh_unchanged %s', r->>'path', r->>'wh_credit_skipped', fp_a = fp_b);
  EXCEPTION WHEN OTHERS THEN e_recv := SQLERRM; END;

  RAISE EXCEPTION 'PRD144_P2_4 % | add_dispatch_row %:% | control_wh %:% | swap_remove %:% | write_refill_plan %:% | push %:% (%) | engine_finalize_pod %:% | receive %:%',
    CASE WHEN ok_adr AND ok_ctl AND ok_swap AND ok_wrp AND ok_push AND ok_fin AND ok_recv THEN 'PASS' ELSE 'FAIL' END,
    ok_adr, e_adr, ok_ctl, e_ctl, ok_swap, e_swap, ok_wrp, e_wrp, ok_push, e_push, d_push, ok_fin, e_fin, ok_recv, e_recv;
END
$t$;
