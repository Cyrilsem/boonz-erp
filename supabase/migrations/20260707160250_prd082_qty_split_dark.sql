-- PRD-082 (Cody PASS, revisions applied): flag-gated qty/filled split, shipped DARK.
-- pack_dispatch_line preserves planned quantity when qty_split_v1='on'; seeded 'off' so the
-- resolved body is byte-identical to current behaviour (CASE else = v_total_picked).
-- Full resolved body (auditable, not a runtime regexp). Family A untouched (8587be9a).
-- PARKED: enabling qty_split_v1 (FE reader-repoint quantity->filled_quantity + settlement
-- byte-diff re-check), the quantity=original_quantity backfill, edit_dispatch_qty block removal.
INSERT INTO refill_qa.feature_flag(flag,value) VALUES ('qty_split_v1','off') ON CONFLICT (flag) DO NOTHING;

CREATE OR REPLACE FUNCTION public.pack_dispatch_line(p_dispatch_id uuid, p_picks jsonb, p_packed_by uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_dispatch refill_dispatching%ROWTYPE;
  v_pick jsonb;
  v_wh_row warehouse_inventory%ROWTYPE;
  v_pick_qty numeric;
  v_pick_bpid uuid;
  v_total_picked numeric := 0;
  v_first_pick boolean := true;
  v_new_child_id uuid;
  v_picks_used jsonb := '[]'::jsonb;
  v_today date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  v_wh uuid;
  v_resolved jsonb := '[]'::jsonb;
  v_rebinds jsonb := '[]'::jsonb;
  v_sub_id uuid;
  v_fail_reason text;
  v_ok boolean;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'pack_dispatch_line', true);
  PERFORM set_config('app.provenance_reason', 'dispatch_pack', true);
  PERFORM set_config('app.source_event_id', p_dispatch_id::text, true);
  SELECT * INTO v_dispatch FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.skipped = true THEN
    RAISE EXCEPTION 'pack_dispatch_line: dispatch % is SKIPPED (skip_reason: %). Skipped lines cannot be packed; un-skip explicitly first.', p_dispatch_id, COALESCE(v_dispatch.skip_reason, 'no reason recorded');
  END IF;
  IF v_dispatch.cancelled = true THEN
    RAISE EXCEPTION 'pack_dispatch_line: dispatch % is CANCELLED (skip_reason: %). Cancelled lines cannot be packed.', p_dispatch_id, COALESCE(v_dispatch.skip_reason, 'no reason recorded');
  END IF;
  IF COALESCE(v_dispatch.include, true) = false THEN
    RAISE EXCEPTION 'pack_dispatch_line: dispatch % is EXCLUDED (include=false, skip_reason: %). Excluded lines cannot be packed.', p_dispatch_id, COALESCE(v_dispatch.skip_reason, 'no reason recorded');
  END IF;
  IF v_dispatch.packed = true THEN RAISE EXCEPTION 'Already packed'; END IF;
  IF v_dispatch.action NOT IN ('Refill','Add New','Add') THEN
    UPDATE refill_dispatching SET packed = true WHERE dispatch_id = p_dispatch_id;
    RETURN jsonb_build_object('status', 'packed_no_pick', 'dispatch_id', p_dispatch_id);
  END IF;
  SELECT COALESCE(SUM((p->>'qty')::numeric), 0) INTO v_total_picked FROM jsonb_array_elements(p_picks) p;
  IF v_total_picked < 1 THEN
    UPDATE refill_dispatching
       SET pack_outcome      = 'not_filled',
           filled_quantity   = 0,
           original_quantity = COALESCE(original_quantity, quantity), not_filled_reason = COALESCE(NULLIF((SELECT p->>'reason' FROM jsonb_array_elements(p_picks) p WHERE NULLIF(p->>'reason','') IS NOT NULL LIMIT 1), ''), 'not filled at pack time'),
           bind_fail_reason  = NULL,
           bind_fail_at      = NULL
     WHERE dispatch_id = p_dispatch_id;
    RETURN jsonb_build_object('status', 'not_filled', 'dispatch_id', p_dispatch_id,
                              'planned_quantity', v_dispatch.quantity, 'filled_quantity', 0,
                              'pack_outcome', 'not_filled');
  END IF;
  IF v_total_picked > v_dispatch.quantity THEN RAISE EXCEPTION 'Pick total (%) exceeds planned quantity (%)', v_total_picked, v_dispatch.quantity; END IF;
  PERFORM set_config('app.mutation_reason', format('B3 pack: dispatch %s picking %s units total (planned %s)', p_dispatch_id, v_total_picked, v_dispatch.quantity), true);

  v_wh := COALESCE(v_dispatch.from_warehouse_id, '4bebef68-9e36-4a5c-9c2c-142f8dbdae85'::uuid);
  FOR v_pick IN SELECT * FROM jsonb_array_elements(p_picks) LOOP
    v_pick_qty := (v_pick->>'qty')::numeric;
    IF v_pick_qty <= 0 THEN CONTINUE; END IF;
    IF NULLIF(v_pick->>'wh_inventory_id', '') IS NULL THEN
      RAISE EXCEPTION 'pack_dispatch_line: every pick must include from_wh_inventory_id (BUG-006 prevention). Dispatch %, pick payload: %',
        p_dispatch_id, v_pick;
    END IF;
    v_pick_bpid := COALESCE((v_pick->>'boonz_product_id')::uuid, v_dispatch.boonz_product_id);

    SELECT * INTO v_wh_row FROM warehouse_inventory
     WHERE wh_inventory_id = (v_pick->>'wh_inventory_id')::uuid FOR UPDATE;
    v_ok := FOUND
        AND v_wh_row.status = 'Active'
        AND NOT COALESCE(v_wh_row.quarantined, false)
        AND (v_wh_row.expiration_date IS NULL OR v_wh_row.expiration_date >= v_today)
        AND (v_wh_row.reserved_for_machine_id IS NULL OR v_wh_row.reserved_for_machine_id = v_dispatch.machine_id)
        AND COALESCE(v_wh_row.warehouse_stock, 0) >= v_pick_qty;

    IF NOT v_ok THEN
      SELECT p.wh_inventory_id INTO v_sub_id
      FROM v_wh_pickable p
      WHERE p.boonz_product_id = v_pick_bpid
        AND p.warehouse_id = v_wh
        AND (p.reserved_for_machine_id IS NULL OR p.reserved_for_machine_id = v_dispatch.machine_id)
        AND COALESCE(p.warehouse_stock, 0) >= v_pick_qty
        AND p.wh_inventory_id <> (v_pick->>'wh_inventory_id')::uuid
      ORDER BY p.expiration_date ASC NULLS LAST, p.warehouse_stock DESC
      LIMIT 1;

      IF v_sub_id IS NOT NULL THEN
        SELECT * INTO v_wh_row FROM warehouse_inventory WHERE wh_inventory_id = v_sub_id FOR UPDATE;
        IF v_wh_row.status = 'Active' AND NOT COALESCE(v_wh_row.quarantined, false)
           AND (v_wh_row.expiration_date IS NULL OR v_wh_row.expiration_date >= v_today)
           AND (v_wh_row.reserved_for_machine_id IS NULL OR v_wh_row.reserved_for_machine_id = v_dispatch.machine_id)
           AND COALESCE(v_wh_row.warehouse_stock, 0) >= v_pick_qty THEN
          v_rebinds := v_rebinds || jsonb_build_object(
            'from', v_pick->>'wh_inventory_id', 'to', v_sub_id, 'qty', v_pick_qty,
            'new_expiry', v_wh_row.expiration_date, 'boonz_product_id', v_pick_bpid);
          v_pick := jsonb_set(v_pick, '{wh_inventory_id}', to_jsonb(v_sub_id::text));
        ELSE
          v_sub_id := NULL;
        END IF;
      END IF;

      IF v_sub_id IS NULL THEN
        SELECT CASE
          WHEN EXISTS (SELECT 1 FROM warehouse_inventory w
                       WHERE w.boonz_product_id = v_pick_bpid AND w.warehouse_id = v_wh
                         AND w.status = 'Active' AND NOT COALESCE(w.quarantined,false)
                         AND (w.expiration_date IS NULL OR w.expiration_date >= v_today)
                         AND COALESCE(w.warehouse_stock,0) >= v_pick_qty
                         AND w.reserved_for_machine_id IS NOT NULL
                         AND w.reserved_for_machine_id <> v_dispatch.machine_id)
            THEN 'pinned_elsewhere'
          WHEN EXISTS (SELECT 1 FROM warehouse_inventory w
                       WHERE w.boonz_product_id = v_pick_bpid AND w.warehouse_id = v_wh
                         AND COALESCE(w.quarantined,false)
                         AND (w.expiration_date IS NULL OR w.expiration_date >= v_today)
                         AND COALESCE(w.warehouse_stock,0) > 0)
            THEN 'quarantined'
          WHEN EXISTS (SELECT 1 FROM warehouse_inventory w
                       WHERE w.boonz_product_id = v_pick_bpid AND w.warehouse_id = v_wh
                         AND w.status <> 'Active' AND NOT COALESCE(w.quarantined,false)
                         AND (w.expiration_date IS NULL OR w.expiration_date >= v_today)
                         AND COALESCE(w.warehouse_stock,0) > 0)
            THEN 'inactive_batch'
          ELSE 'no_stock'
        END INTO v_fail_reason;

        UPDATE refill_dispatching
           SET bind_fail_reason = v_fail_reason, bind_fail_at = now()
         WHERE dispatch_id = p_dispatch_id;
        RETURN jsonb_build_object('status', 'bind_failed', 'dispatch_id', p_dispatch_id,
                                  'bind_fail_reason', v_fail_reason,
                                  'stale_wh_inventory_id', v_pick->>'wh_inventory_id',
                                  'pick_qty', v_pick_qty, 'boonz_product_id', v_pick_bpid,
                                  'planned_quantity', v_dispatch.quantity);
      END IF;
    END IF;

    v_resolved := v_resolved || v_pick;
  END LOOP;

  FOR v_pick IN SELECT * FROM jsonb_array_elements(v_resolved) LOOP
    v_pick_qty := (v_pick->>'qty')::numeric;
    v_pick_bpid := COALESCE((v_pick->>'boonz_product_id')::uuid, v_dispatch.boonz_product_id);
    SELECT * INTO v_wh_row FROM warehouse_inventory WHERE wh_inventory_id = (v_pick->>'wh_inventory_id')::uuid FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'WH row % not found', v_pick->>'wh_inventory_id'; END IF;
    IF COALESCE(v_wh_row.warehouse_stock, 0) < v_pick_qty THEN RAISE EXCEPTION 'WH row % has only % units, cannot pick %', v_wh_row.wh_inventory_id, v_wh_row.warehouse_stock, v_pick_qty; END IF;
    UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) - v_pick_qty, consumer_stock = COALESCE(consumer_stock, 0) + v_pick_qty WHERE wh_inventory_id = v_wh_row.wh_inventory_id;
    IF v_first_pick THEN
      UPDATE refill_dispatching SET packed = false WHERE dispatch_id = p_dispatch_id;
      UPDATE refill_dispatching SET packed = true, expiry_date = v_wh_row.expiration_date, filled_quantity = v_pick_qty, boonz_product_id = v_pick_bpid, quantity = CASE WHEN refill_qa.flag('qty_split_v1')='on' THEN quantity ELSE v_total_picked END, from_wh_inventory_id = v_wh_row.wh_inventory_id, original_quantity = COALESCE(v_dispatch.original_quantity, v_dispatch.quantity), pack_outcome = (CASE WHEN v_total_picked < v_dispatch.quantity THEN 'partial' ELSE 'packed' END)::public.pack_outcome_enum, bind_fail_reason = NULL, bind_fail_at = NULL WHERE dispatch_id = p_dispatch_id;
      v_first_pick := false;
    ELSE
      INSERT INTO refill_dispatching (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action, quantity, filled_quantity, include, packed, picked_up, dispatched, returned, item_added, expiry_date, from_wh_inventory_id, pack_outcome) VALUES (v_dispatch.machine_id, v_dispatch.shelf_id, v_dispatch.pod_product_id, v_pick_bpid, v_dispatch.dispatch_date, v_dispatch.action, v_pick_qty, v_pick_qty, true, true, false, false, false, false, v_wh_row.expiration_date, v_wh_row.wh_inventory_id, 'packed') RETURNING dispatch_id INTO v_new_child_id;
    END IF;
    v_picks_used := v_picks_used || jsonb_build_object('wh_inventory_id', v_wh_row.wh_inventory_id, 'batch_id', v_wh_row.batch_id, 'expiry', v_wh_row.expiration_date, 'qty', v_pick_qty, 'boonz_product_id', v_pick_bpid, 'child_dispatch_id', v_new_child_id);
  END LOOP;
  RETURN jsonb_build_object('status', 'packed', 'dispatch_id', p_dispatch_id, 'total_picked', v_total_picked, 'planned_quantity', v_dispatch.quantity, 'pack_outcome', (CASE WHEN v_total_picked < v_dispatch.quantity THEN 'partial' ELSE 'packed' END), 'picks', v_picks_used, 'rebinds', v_rebinds);
END;
$function$;
