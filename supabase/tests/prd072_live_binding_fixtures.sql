-- PRD-072 test fixtures (a)-(e) + golden unchanged paths.
-- DRY-RUN pattern (PRD-016B lineage): one DO block builds synthetic rows against two real
-- Active machines, exercises pack_dispatch_line / credit_dispatch_remainder, accumulates
-- assertion results, then ALWAYS aborts via RAISE EXCEPTION so nothing persists.
-- Run via MCP execute_sql at gate time. Expected outcome: exception whose message starts
-- with 'DRY_TEST_REPORT' and contains no 'FAIL' lines.
-- NOTE: if warehouse_inventory writer guards block the synthetic setup INSERTs (service-role
-- block per the WH writer gate), prepend the warehouse-manager impersonation
-- (set_config('request.jwt.claims', ...sub=warehouse mgr bf32624e..., true)) per
-- reference_wh_available_def_and_writer_gate and re-run.
DO $$
DECLARE
  r text := E'DRY_TEST_REPORT\n';
  v_m1 uuid; v_m2 uuid;                -- two real Active machines (read-only use)
  v_bp uuid;                            -- a real boonz product
  v_wh uuid := '4bebef68-9e36-4a5c-9c2c-142f8dbdae85'; -- WH_CENTRAL
  v_shelves uuid[];
  b_stale uuid; b_fresh uuid; b_pin uuid; b_q uuid; b_inact uuid; b_part uuid;
  d_a uuid; d_b uuid; d_c uuid; d_d uuid; d_e uuid; d_g1 uuid; d_g2 uuid;
  res jsonb; v_row refill_dispatching%ROWTYPE; v_wi warehouse_inventory%ROWTYPE;
  v_stock numeric;
BEGIN
  -- fixture GUCs (canonical-writer context for synthetic setup rows)
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','prd072_dry_test',true);
  PERFORM set_config('app.via_trigger','true',true);
  PERFORM set_config('app.mutation_reason','PRD-072 dry-run fixtures (always rolled back)',true);
  PERFORM set_config('app.provenance_reason','manual_adjust',true);

  -- 7 distinct shelves needed: prevent_duplicate_unstarted_dispatch blocks a second
  -- unstarted line per (machine, shelf, product, action, date), and the bind_failed /
  -- not_filled scenario lines stay unstarted.
  SELECT m.machine_id INTO v_m1 FROM machines m
   WHERE m.status='Active' AND (SELECT count(*) FROM shelf_configurations s WHERE s.machine_id = m.machine_id) >= 7
   ORDER BY m.official_name LIMIT 1;
  SELECT machine_id INTO v_m2 FROM machines WHERE status='Active' AND machine_id <> v_m1 ORDER BY official_name LIMIT 1;
  -- throwaway product: isolates the FEFO re-bind from real WH stock (rolled back with everything else)
  INSERT INTO boonz_products (boonz_product_name, physical_type)
  VALUES ('PRD072-DRY-TEST-PRODUCT', (SELECT physical_type FROM boonz_products LIMIT 1))
  RETURNING product_id INTO v_bp;
  SELECT array_agg(shelf_id) INTO v_shelves FROM (
    SELECT shelf_id FROM shelf_configurations WHERE machine_id = v_m1 LIMIT 7) s;

  -- ── (a) PO-after-bind: bound batch depleted, fresh batch landed later ──
  INSERT INTO warehouse_inventory (wh_inventory_id, boonz_product_id, warehouse_id, warehouse_stock, expiration_date, batch_id, status, snapshot_date)
  VALUES (gen_random_uuid(), v_bp, v_wh, 0,  current_date + 30, 'PRD072-A-STALE', 'Active', current_date) RETURNING wh_inventory_id INTO b_stale;
  INSERT INTO warehouse_inventory (wh_inventory_id, boonz_product_id, warehouse_id, warehouse_stock, expiration_date, batch_id, status, snapshot_date)
  VALUES (gen_random_uuid(), v_bp, v_wh, 50, current_date + 60, 'PRD072-A-FRESH', 'Active', current_date) RETURNING wh_inventory_id INTO b_fresh;
  INSERT INTO refill_dispatching (dispatch_id, machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity, include, from_warehouse_id, from_wh_inventory_id, source_origin)
  VALUES (gen_random_uuid(), v_m1, v_shelves[1], v_bp, current_date, 'Refill', 5, true, v_wh, b_stale, 'warehouse') RETURNING dispatch_id INTO d_a;

  res := pack_dispatch_line(d_a, jsonb_build_array(jsonb_build_object('wh_inventory_id', b_stale, 'qty', 5, 'boonz_product_id', v_bp)));
  SELECT * INTO v_row FROM refill_dispatching WHERE dispatch_id = d_a;
  SELECT * INTO v_wi  FROM warehouse_inventory WHERE wh_inventory_id = b_fresh;
  r := r || CASE WHEN res->>'status'='packed' AND v_row.from_wh_inventory_id = b_fresh
                  AND v_row.expiry_date = current_date + 60
                  AND jsonb_array_length(res->'rebinds') = 1
                  AND v_wi.warehouse_stock = 45 AND v_wi.consumer_stock >= 5
                  AND v_wi.reserved_for_machine_id IS NULL           -- no whole-remainder pin
             THEN 'PASS (a) PO-after-bind re-binds live, no pin' ELSE 'FAIL (a) got ' || res::text END || E'\n';

  -- ── (b) pinned-remainder sibling: only batch pinned to another machine ──
  INSERT INTO warehouse_inventory (wh_inventory_id, boonz_product_id, warehouse_id, warehouse_stock, expiration_date, batch_id, status, snapshot_date, reserved_for_machine_id)
  VALUES (gen_random_uuid(), v_bp, v_wh, 40, current_date + 40, 'PRD072-B-PIN', 'Active', current_date, v_m2) RETURNING wh_inventory_id INTO b_pin;
  -- isolate: drain the (a) leftovers so (b) sees only the pinned batch
  UPDATE warehouse_inventory SET warehouse_stock = 0 WHERE wh_inventory_id IN (b_stale, b_fresh);
  INSERT INTO refill_dispatching (dispatch_id, machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity, include, from_warehouse_id, from_wh_inventory_id, source_origin)
  VALUES (gen_random_uuid(), v_m1, v_shelves[2], v_bp, current_date, 'Refill', 4, true, v_wh, b_pin, 'warehouse') RETURNING dispatch_id INTO d_b;

  res := pack_dispatch_line(d_b, jsonb_build_array(jsonb_build_object('wh_inventory_id', b_pin, 'qty', 4, 'boonz_product_id', v_bp)));
  SELECT * INTO v_row FROM refill_dispatching WHERE dispatch_id = d_b;
  r := r || CASE WHEN res->>'status'='bind_failed' AND res->>'bind_fail_reason'='pinned_elsewhere'
                  AND v_row.bind_fail_reason='pinned_elsewhere' AND v_row.bind_fail_at IS NOT NULL
                  AND COALESCE(v_row.packed,false)=false
             THEN 'PASS (b) pinned sibling fails soft: pinned_elsewhere' ELSE 'FAIL (b) got ' || res::text END || E'\n';

  -- ── (c) quarantined-only stock ──
  UPDATE warehouse_inventory SET warehouse_stock = 0 WHERE wh_inventory_id = b_pin;
  -- quarantined is GENERATED from provenance_reason; flip the GUC so the provenance
  -- trigger stamps an unverified reason -> quarantined=true, then restore (PRD-016B leak lesson)
  PERFORM set_config('app.provenance_reason','dispatch_return_unverified',true);
  INSERT INTO warehouse_inventory (wh_inventory_id, boonz_product_id, warehouse_id, warehouse_stock, expiration_date, batch_id, status, snapshot_date)
  VALUES (gen_random_uuid(), v_bp, v_wh, 30, current_date + 40, 'PRD072-C-Q', 'Active', current_date) RETURNING wh_inventory_id INTO b_q;
  PERFORM set_config('app.provenance_reason','manual_adjust',true);
  INSERT INTO refill_dispatching (dispatch_id, machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity, include, from_warehouse_id, from_wh_inventory_id, source_origin)
  VALUES (gen_random_uuid(), v_m1, v_shelves[3], v_bp, current_date, 'Refill', 3, true, v_wh, b_q, 'warehouse') RETURNING dispatch_id INTO d_c;
  res := pack_dispatch_line(d_c, jsonb_build_array(jsonb_build_object('wh_inventory_id', b_q, 'qty', 3, 'boonz_product_id', v_bp)));
  r := r || CASE WHEN res->>'status'='bind_failed' AND res->>'bind_fail_reason'='quarantined'
             THEN 'PASS (c) quarantined-only fails soft: quarantined' ELSE 'FAIL (c) got ' || res::text END || E'\n';

  -- ── (d) Inactive-batch stock ──
  UPDATE warehouse_inventory SET warehouse_stock = 0 WHERE wh_inventory_id = b_q;  -- stays quarantined; 0 stock keeps it out of (d)'s classification
  INSERT INTO warehouse_inventory (wh_inventory_id, boonz_product_id, warehouse_id, warehouse_stock, expiration_date, batch_id, status, snapshot_date)
  VALUES (gen_random_uuid(), v_bp, v_wh, 20, current_date + 40, 'PRD072-D-INACT', 'Inactive', current_date) RETURNING wh_inventory_id INTO b_inact;
  INSERT INTO refill_dispatching (dispatch_id, machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity, include, from_warehouse_id, from_wh_inventory_id, source_origin)
  VALUES (gen_random_uuid(), v_m1, v_shelves[4], v_bp, current_date, 'Refill', 2, true, v_wh, b_inact, 'warehouse') RETURNING dispatch_id INTO d_d;
  res := pack_dispatch_line(d_d, jsonb_build_array(jsonb_build_object('wh_inventory_id', b_inact, 'qty', 2, 'boonz_product_id', v_bp)));
  r := r || CASE WHEN res->>'status'='bind_failed' AND res->>'bind_fail_reason'='inactive_batch'
             THEN 'PASS (d) inactive-only fails soft: inactive_batch' ELSE 'FAIL (d) got ' || res::text END || E'\n';

  -- ── (e) partial fill + remainder credit (proves dispatch_partial_remainder registered) ──
  INSERT INTO warehouse_inventory (wh_inventory_id, boonz_product_id, warehouse_id, warehouse_stock, expiration_date, batch_id, status, snapshot_date)
  VALUES (gen_random_uuid(), v_bp, v_wh, 3, current_date + 45, 'PRD072-E-PART', 'Active', current_date) RETURNING wh_inventory_id INTO b_part;
  INSERT INTO refill_dispatching (dispatch_id, machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity, include, from_warehouse_id, from_wh_inventory_id, source_origin)
  VALUES (gen_random_uuid(), v_m1, v_shelves[5], v_bp, current_date, 'Refill', 5, true, v_wh, b_part, 'warehouse') RETURNING dispatch_id INTO d_e;
  res := pack_dispatch_line(d_e, jsonb_build_array(jsonb_build_object('wh_inventory_id', b_part, 'qty', 3, 'boonz_product_id', v_bp)));
  r := r || CASE WHEN res->>'status'='packed' AND res->>'pack_outcome'='partial'
             THEN 'PASS (e1) partial pack' ELSE 'FAIL (e1) got ' || res::text END || E'\n';
  -- simulate receive: driver fit only 1 of the 3 packed units; line closed (item_added)
  UPDATE refill_dispatching SET item_added = true, filled_quantity = 1 WHERE dispatch_id = d_e;
  res := credit_dispatch_remainder(d_e);
  SELECT warehouse_stock INTO v_stock FROM warehouse_inventory WHERE wh_inventory_id = b_part;
  -- PRD-065 auto-credit trigger fires on the item_added flip, so the explicit call may
  -- see already_done; the stock delta (0 -> 2) is the real assertion either way.
  r := r || CASE WHEN res->>'status' IN ('credited','already_done') AND v_stock = 2
             THEN 'PASS (e2) remainder credit 2 units, provenance accepted' ELSE 'FAIL (e2) got ' || res::text || ' stock=' || v_stock END || E'\n';

  -- ── golden unchanged paths ──
  INSERT INTO refill_dispatching (dispatch_id, machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity, include, from_warehouse_id, source_origin)
  VALUES (gen_random_uuid(), v_m1, v_shelves[6], v_bp, current_date, 'Refill', 4, true, v_wh, 'warehouse') RETURNING dispatch_id INTO d_g1;
  res := pack_dispatch_line(d_g1, '[]'::jsonb);
  SELECT * INTO v_row FROM refill_dispatching WHERE dispatch_id = d_g1;
  r := r || CASE WHEN res->>'status'='not_filled' AND v_row.pack_outcome::text='not_filled' AND COALESCE(v_row.packed,false)=false
             THEN 'PASS (g1) empty-pick not_filled unchanged' ELSE 'FAIL (g1) got ' || res::text END || E'\n';

  INSERT INTO refill_dispatching (dispatch_id, machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity, include, skipped, skip_reason, source_origin)
  VALUES (gen_random_uuid(), v_m1, v_shelves[7], v_bp, current_date, 'Refill', 4, true, true, 'dry test', 'warehouse') RETURNING dispatch_id INTO d_g2;
  BEGIN
    res := pack_dispatch_line(d_g2, jsonb_build_array(jsonb_build_object('wh_inventory_id', b_part, 'qty', 1)));
    r := r || E'FAIL (g2) skipped line packed without exception\n';
  EXCEPTION WHEN others THEN
    r := r || CASE WHEN SQLERRM LIKE '%SKIPPED%' THEN 'PASS (g2) PRD-028 skip guard unchanged' ELSE 'FAIL (g2) unexpected: ' || SQLERRM END || E'\n';
  END;

  RAISE EXCEPTION '%', r;  -- always abort: nothing above persists
END $$;
