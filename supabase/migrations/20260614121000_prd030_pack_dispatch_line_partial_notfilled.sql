-- PRD-030 step 2: pack_dispatch_line allows a confirmed zero (not_filled) or partial pick.
-- Conserve-safe: quantity stays = total_picked (conserve_split_dispatch_quantity untouched);
-- planned is snapshotted into original_quantity. Empty picks => not_filled (no WH debit, no
-- from_wh required, packed stays false). BUG-006 from_wh guard kept for real picks. Cody-reviewed.
-- Rollback md5 (v before): 63454d3d3f51d6a56e8a4852dc5c703c.

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
  -- PRD-030: a zero / empty pick is a confirmed "not filled" outcome (planned, attempted,
  -- no valid WH stock at pack time). It does NOT raise: pack_outcome=not_filled, filled=0,
  -- packed stays FALSE (never counted packed), planned qty preserved into original_quantity,
  -- NO warehouse debit and no from_wh_inventory_id required. This is what lets an OOS line
  -- travel with the machine instead of darkening it.
  IF v_total_picked < 1 THEN
    UPDATE refill_dispatching
       SET pack_outcome      = 'not_filled',
           filled_quantity   = 0,
           original_quantity = COALESCE(original_quantity, quantity)
     WHERE dispatch_id = p_dispatch_id;
    RETURN jsonb_build_object('status', 'not_filled', 'dispatch_id', p_dispatch_id,
                              'planned_quantity', v_dispatch.quantity, 'filled_quantity', 0,
                              'pack_outcome', 'not_filled');
  END IF;
  IF v_total_picked > v_dispatch.quantity THEN RAISE EXCEPTION 'Pick total (%) exceeds planned quantity (%)', v_total_picked, v_dispatch.quantity; END IF;
  PERFORM set_config('app.mutation_reason', format('B3 pack: dispatch %s picking %s units total (planned %s)', p_dispatch_id, v_total_picked, v_dispatch.quantity), true);
  FOR v_pick IN SELECT * FROM jsonb_array_elements(p_picks) LOOP
    v_pick_qty := (v_pick->>'qty')::numeric;
    IF v_pick_qty <= 0 THEN CONTINUE; END IF;
    -- PRD-Phase-G P2 A.1: every pick must include from_wh_inventory_id (BUG-006 prevention).
    IF NULLIF(v_pick->>'wh_inventory_id', '') IS NULL THEN
      RAISE EXCEPTION 'pack_dispatch_line: every pick must include from_wh_inventory_id (BUG-006 prevention). Dispatch %, pick payload: %',
        p_dispatch_id, v_pick;
    END IF;
    v_pick_bpid := COALESCE((v_pick->>'boonz_product_id')::uuid, v_dispatch.boonz_product_id);
    SELECT * INTO v_wh_row FROM warehouse_inventory WHERE wh_inventory_id = (v_pick->>'wh_inventory_id')::uuid FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'WH row % not found', v_pick->>'wh_inventory_id'; END IF;
    IF COALESCE(v_wh_row.warehouse_stock, 0) < v_pick_qty THEN RAISE EXCEPTION 'WH row % has only % units, cannot pick %', v_wh_row.wh_inventory_id, v_wh_row.warehouse_stock, v_pick_qty; END IF;
    UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) - v_pick_qty, consumer_stock  = COALESCE(consumer_stock, 0) + v_pick_qty, reserved_for_machine_id = COALESCE(reserved_for_machine_id, v_dispatch.machine_id), reserved_at = COALESCE(reserved_at, now()) WHERE wh_inventory_id = v_wh_row.wh_inventory_id;
    IF v_first_pick THEN
      UPDATE refill_dispatching SET packed = false WHERE dispatch_id = p_dispatch_id;
      UPDATE refill_dispatching SET packed = true, expiry_date = v_wh_row.expiration_date, filled_quantity = v_pick_qty, boonz_product_id = v_pick_bpid, quantity = v_total_picked, from_wh_inventory_id = v_wh_row.wh_inventory_id, original_quantity = COALESCE(v_dispatch.original_quantity, v_dispatch.quantity), pack_outcome = (CASE WHEN v_total_picked < v_dispatch.quantity THEN 'partial' ELSE 'packed' END)::public.pack_outcome_enum WHERE dispatch_id = p_dispatch_id;
      v_first_pick := false;
    ELSE
      INSERT INTO refill_dispatching (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action, quantity, filled_quantity, include, packed, picked_up, dispatched, returned, item_added, expiry_date, from_wh_inventory_id, pack_outcome) VALUES (v_dispatch.machine_id, v_dispatch.shelf_id, v_dispatch.pod_product_id, v_pick_bpid, v_dispatch.dispatch_date, v_dispatch.action, v_pick_qty, v_pick_qty, true, true, false, false, false, false, v_wh_row.expiration_date, v_wh_row.wh_inventory_id, 'packed') RETURNING dispatch_id INTO v_new_child_id;
    END IF;
    v_picks_used := v_picks_used || jsonb_build_object('wh_inventory_id', v_wh_row.wh_inventory_id, 'batch_id', v_wh_row.batch_id, 'expiry', v_wh_row.expiration_date, 'qty', v_pick_qty, 'boonz_product_id', v_pick_bpid, 'child_dispatch_id', v_new_child_id);
  END LOOP;
  RETURN jsonb_build_object('status', 'packed', 'dispatch_id', p_dispatch_id, 'total_picked', v_total_picked, 'planned_quantity', v_dispatch.quantity, 'pack_outcome', (CASE WHEN v_total_picked < v_dispatch.quantity THEN 'partial' ELSE 'packed' END), 'picks', v_picks_used);
END;
$function$;
