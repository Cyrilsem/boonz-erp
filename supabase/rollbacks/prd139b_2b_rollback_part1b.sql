-- Rollback for prd139b_2b_role_checks_part1 (continued): receive_dispatch_line,
-- return_dispatch_line, driver_confirm_remove -- exact pre-change bodies.

CREATE OR REPLACE FUNCTION public.receive_dispatch_line(p_dispatch_id uuid, p_filled_quantity numeric, p_received_by uuid DEFAULT NULL::uuid, p_batch_breakdown jsonb DEFAULT NULL::jsonb, p_override boolean DEFAULT false, p_override_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_dispatch refill_dispatching%ROWTYPE;
  v_planned numeric; v_return_delta numeric; v_overfill numeric;
  v_consumer_row warehouse_inventory%ROWTYPE;
  v_wh_row warehouse_inventory%ROWTYPE;
  v_pod_id uuid; v_consumer_drawn numeric := 0; v_path text;
  v_target_wh uuid; v_pod_archived int := 0;
  v_breakdown_total numeric := 0;
  v_entry jsonb; v_entry_qty numeric; v_entry_expiry date; v_entry_wh_id uuid;
  v_existing_row warehouse_inventory%ROWTYPE;
  v_credit_summary jsonb := '[]'::jsonb;
  v_effective_expiry date;
  v_prior_active_merged int := 0;
  v_supply text;
  v_is_fill boolean;
  v_gate text;
  v_overfill_debits jsonb := '[]'::jsonb;
  v_fefo record;
  v_need numeric;
  v_take numeric;
  v_return_audit_ts timestamptz;
  v_wh_audit record;
  v_delta numeric;
  v_undo_total numeric := 0;
  v_undo_row warehouse_inventory%ROWTYPE;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'receive_dispatch_line', true);
  PERFORM set_config('app.provenance_reason', 'dispatch_receive', true);
  PERFORM set_config('app.source_event_id', p_dispatch_id::text, true);
  SELECT * INTO v_dispatch FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.item_added = true THEN RAISE EXCEPTION 'Dispatch % already received', p_dispatch_id; END IF;

  IF v_dispatch.returned = true THEN
    SELECT occurred_at INTO v_return_audit_ts FROM write_audit_log
     WHERE table_name = 'refill_dispatching' AND row_pk = p_dispatch_id::text AND rpc_name = 'return_dispatch_line'
     ORDER BY occurred_at DESC LIMIT 1;
    IF v_return_audit_ts IS NULL THEN
      RAISE EXCEPTION 'receive_dispatch_line: dispatch % is returned=true but no return_dispatch_line audit trail was found for it, refusing to auto-undo an unexplained return. Clear "returned" manually first if that is genuinely safe.', p_dispatch_id;
    END IF;

    FOR v_wh_audit IN
      SELECT row_pk AS wh_id,
             (payload -> 'old' ->> 'warehouse_stock')::numeric AS old_stock,
             (payload -> 'new' ->> 'warehouse_stock')::numeric AS new_stock
        FROM write_audit_log
       WHERE table_name = 'warehouse_inventory'
         AND rpc_name = 'return_dispatch_line'
         AND occurred_at = v_return_audit_ts
         AND (payload -> 'new' ->> 'boonz_product_id')::uuid = v_dispatch.boonz_product_id
    LOOP
      v_delta := v_wh_audit.new_stock - v_wh_audit.old_stock;
      IF v_delta IS NULL OR v_delta <= 0 THEN CONTINUE; END IF;
      SELECT * INTO v_undo_row FROM warehouse_inventory
       WHERE wh_inventory_id = v_wh_audit.wh_id::uuid AND status = 'Active' FOR UPDATE;
      IF NOT FOUND OR COALESCE(v_undo_row.warehouse_stock, 0) < v_delta THEN
        RAISE EXCEPTION 'receive_dispatch_line: cannot auto-undo dispatch %''s return, % unit(s) credited to warehouse_inventory row % are no longer available there (already picked, moved, or wasted since). Refusing to double-count; reconcile manually before receiving.', p_dispatch_id, v_delta, v_wh_audit.wh_id;
      END IF;
      UPDATE warehouse_inventory SET warehouse_stock = warehouse_stock - v_delta WHERE wh_inventory_id = v_wh_audit.wh_id::uuid;
      v_undo_total := v_undo_total + v_delta;
    END LOOP;

    IF v_undo_total = 0 THEN
      RAISE EXCEPTION 'receive_dispatch_line: dispatch % is returned=true but no warehouse_inventory credit could be found in its return_dispatch_line audit trail to undo, refusing to proceed blind.', p_dispatch_id;
    END IF;

    PERFORM set_config('app.mutation_reason',
      format('receive_dispatch_line UNDO: reversing %s unit(s) that return_dispatch_line credited at %s for dispatch %s, before re-receiving it now',
        v_undo_total, v_return_audit_ts, p_dispatch_id), true);
    UPDATE refill_dispatching SET returned = false, return_reason = NULL WHERE dispatch_id = p_dispatch_id;
    v_dispatch.returned := false;
    v_dispatch.return_reason := NULL;
  END IF;

  IF p_filled_quantity < 0 THEN RAISE EXCEPTION 'filled_quantity cannot be negative'; END IF;
  v_planned := v_dispatch.quantity;
  v_return_delta := GREATEST(v_planned - p_filled_quantity, 0);
  v_overfill := GREATEST(p_filled_quantity - v_planned, 0);
  v_path := 'b2_fallback';
  v_target_wh := COALESCE(
    v_dispatch.from_warehouse_id,
    (SELECT primary_warehouse_id FROM public.machines WHERE machine_id = v_dispatch.machine_id));
  IF v_target_wh IS NULL THEN
    RAISE EXCEPTION 'receive_dispatch_line: cannot resolve credit warehouse for dispatch % (from_warehouse_id NULL and machine % has no primary_warehouse_id). Refusing to silently credit WH_CENTRAL.', p_dispatch_id, v_dispatch.machine_id;
  END IF;
  IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN
    SELECT expiration_date INTO v_effective_expiry FROM warehouse_inventory WHERE wh_inventory_id = v_dispatch.from_wh_inventory_id;
  ELSE
    v_effective_expiry := v_dispatch.expiry_date;
    PERFORM public.log_expiry_entry_suspect('receive_dispatch_line', v_dispatch.dispatch_date,
      v_effective_expiry, jsonb_build_object('dispatch_id', p_dispatch_id, 'machine_id', v_dispatch.machine_id,
        'boonz_product_id', v_dispatch.boonz_product_id, 'action', v_dispatch.action));
  END IF;
  PERFORM set_config('app.mutation_reason', format('B3 receive: dispatch %s, filled %s / planned %s by %s (breakdown=%s, effective_expiry=%s)', p_dispatch_id, p_filled_quantity, v_planned, COALESCE(p_received_by::text, 'system'), p_batch_breakdown IS NOT NULL, v_effective_expiry), true);
  v_is_fill := v_dispatch.action IN ('Refill','Add New','Add') AND NOT COALESCE(v_dispatch.is_m2m, false);
  v_gate := COALESCE(refill_qa.flag('rc07_receive_gate'), 'off');
  IF v_is_fill AND v_gate = 'on'
     AND NOT (COALESCE(v_dispatch.packed, false) AND COALESCE(v_dispatch.picked_up, false)) THEN
    IF p_override IS TRUE AND COALESCE(NULLIF(btrim(p_override_reason), ''), '') <> '' THEN
      PERFORM set_config('app.receive_override_reason', p_override_reason, true);
      PERFORM set_config('app.mutation_reason',
        format('B4 receive OVERRIDE: dispatch %s force-received unpacked (packed=%s picked_up=%s) reason: %s',
               p_dispatch_id, COALESCE(v_dispatch.packed,false), COALESCE(v_dispatch.picked_up,false), p_override_reason), true);
    ELSE
      RAISE EXCEPTION 'receive_dispatch_line: dispatch % is not in a receivable state (packed=%, picked_up=%). A fill line must be PACKED and PICKED UP before receive. Pass p_override:=true with p_override_reason to force-receive (audited).',
        p_dispatch_id, COALESCE(v_dispatch.packed,false), COALESCE(v_dispatch.picked_up,false);
    END IF;
  END IF;
  IF v_dispatch.action IN ('Refill','Add New','Add') THEN
   IF NOT COALESCE(v_dispatch.is_m2m, false) THEN
    IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN
      SELECT * INTO v_consumer_row FROM warehouse_inventory WHERE wh_inventory_id = v_dispatch.from_wh_inventory_id FOR UPDATE;
      IF FOUND AND COALESCE(v_consumer_row.consumer_stock, 0) > 0 THEN v_path := 'b3_consumer_pinned'; ELSE v_consumer_row := NULL; END IF;
    END IF;
    IF v_consumer_row.wh_inventory_id IS NULL THEN
      SELECT * INTO v_consumer_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND COALESCE(consumer_stock, 0) > 0 AND (reserved_for_machine_id = v_dispatch.machine_id OR reserved_for_machine_id IS NULL) AND (expiration_date = v_effective_expiry OR v_effective_expiry IS NULL) ORDER BY (reserved_for_machine_id = v_dispatch.machine_id) DESC, consumer_stock DESC, reserved_at ASC LIMIT 1 FOR UPDATE;
      IF FOUND THEN v_path := 'b3_consumer_legacy'; END IF;
    END IF;
    IF v_consumer_row.wh_inventory_id IS NOT NULL THEN
      v_consumer_drawn := LEAST(p_filled_quantity, v_consumer_row.consumer_stock);
      UPDATE warehouse_inventory SET consumer_stock = GREATEST(COALESCE(consumer_stock, 0) - (v_consumer_drawn + v_return_delta), 0), warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_delta, reserved_for_machine_id = CASE WHEN COALESCE(consumer_stock, 0) - (v_consumer_drawn + v_return_delta) <= 0 THEN NULL ELSE reserved_for_machine_id END, reserved_at = CASE WHEN COALESCE(consumer_stock, 0) - (v_consumer_drawn + v_return_delta) <= 0 THEN NULL ELSE reserved_at END WHERE wh_inventory_id = v_consumer_row.wh_inventory_id;
    ELSE
      IF v_return_delta > 0 THEN
        SELECT * INTO v_wh_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND status = 'Active' AND (expiration_date = v_effective_expiry OR v_effective_expiry IS NULL) ORDER BY (expiration_date = v_effective_expiry) DESC NULLS LAST, created_at DESC LIMIT 1 FOR UPDATE;
        IF FOUND THEN
          UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_delta WHERE wh_inventory_id = v_wh_row.wh_inventory_id;
        ELSE
          SELECT * INTO v_wh_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND (expiration_date = v_effective_expiry OR v_effective_expiry IS NULL) ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_delta WHERE wh_inventory_id = v_wh_row.wh_inventory_id;
          ELSE
            PERFORM set_config('app.provenance_reason', CASE WHEN v_dispatch.wh_approved_at IS NOT NULL THEN 'dispatch_receive' ELSE 'dispatch_return_unverified' END, true);
            INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id) VALUES (v_dispatch.boonz_product_id, v_return_delta, v_effective_expiry, 'Active', format('RETURN-%s', v_dispatch.dispatch_date), CURRENT_DATE, v_target_wh);
            PERFORM set_config('app.provenance_reason','dispatch_receive', true);
          END IF;
        END IF;
      END IF;
    END IF;
    IF v_overfill > 0 THEN
      v_need := v_overfill;
      FOR v_fefo IN
        SELECT f.wh_inventory_id, f.warehouse_stock, f.batch_id, f.expiration_date
        FROM public.wh_fefo_for_line(
               v_dispatch.machine_id, v_dispatch.boonz_product_id,
               COALESCE(v_dispatch.dispatch_date, CURRENT_DATE),
               v_overfill, ARRAY[v_target_wh]) f
        ORDER BY f.pick_rank
      LOOP
        EXIT WHEN v_need <= 0;
        v_take := LEAST(v_need, GREATEST(COALESCE(v_fefo.warehouse_stock,0), 0));
        IF v_take <= 0 THEN CONTINUE; END IF;
        UPDATE warehouse_inventory
           SET warehouse_stock = COALESCE(warehouse_stock, 0) - v_take
         WHERE wh_inventory_id = v_fefo.wh_inventory_id;
        v_overfill_debits := v_overfill_debits || jsonb_build_object(
          'wh_inventory_id', v_fefo.wh_inventory_id, 'batch_id', v_fefo.batch_id,
          'expiry', v_fefo.expiration_date, 'qty', v_take);
        v_need := v_need - v_take;
      END LOOP;
      IF v_need > 0 THEN
        RAISE EXCEPTION 'receive_dispatch_line: overfill of % unit(s) for boonz_product=% cannot be debited, warehouse % is short by % unit(s) across all pickable FEFO batches. Refusing to silently debit an arbitrary/zero row.',
          v_overfill, v_dispatch.boonz_product_id, v_target_wh, v_need;
      END IF;
    END IF;
   ELSE
     v_path := 'add_m2m_no_wh_draw';
   END IF;
    IF p_filled_quantity > 0 THEN
      UPDATE pod_inventory
         SET current_stock = current_stock + p_filled_quantity,
             estimated_remaining = current_stock + p_filled_quantity,
             snapshot_at = now()
       WHERE machine_id = v_dispatch.machine_id AND shelf_id = v_dispatch.shelf_id
         AND boonz_product_id = v_dispatch.boonz_product_id AND status = 'Active'
         AND ((expiration_date = v_effective_expiry) OR (expiration_date IS NULL AND v_effective_expiry IS NULL))
       RETURNING pod_inventory_id INTO v_pod_id;
      IF NOT FOUND THEN
        INSERT INTO pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date,
          current_stock, estimated_remaining, expiration_date, batch_id, status, snapshot_at, created_at)
        VALUES (v_dispatch.machine_id, v_dispatch.shelf_id, v_dispatch.boonz_product_id, CURRENT_DATE,
          p_filled_quantity, p_filled_quantity, v_effective_expiry,
          format('DISPATCH-%s', v_dispatch.dispatch_date), 'Active', now(), now())
        RETURNING pod_inventory_id INTO v_pod_id;
      END IF;
      v_prior_active_merged := 0;
    END IF;
  ELSIF v_dispatch.action = 'Remove' THEN
    v_path := 'remove_single_expiry';
    SELECT source_of_supply INTO v_supply FROM public.product_mapping
     WHERE boonz_product_id = v_dispatch.boonz_product_id AND status = 'Active'
       AND (machine_id = v_dispatch.machine_id OR is_global_default)
     ORDER BY (machine_id = v_dispatch.machine_id) DESC, is_global_default ASC LIMIT 1;
    IF COALESCE(v_dispatch.is_m2m, false) THEN
      v_path := 'remove_m2m_no_wh_credit';
    ELSIF v_supply = 'venue_team' THEN
      v_path := 'remove_venue_team_no_wh_credit';
      INSERT INTO public.vox_return_log
        (dispatch_id, machine_id, boonz_product_id, qty, expiry_date, source_of_supply, received_by, reason)
      VALUES
        (p_dispatch_id, v_dispatch.machine_id, v_dispatch.boonz_product_id, p_filled_quantity,
         v_effective_expiry, v_supply, p_received_by,
         format('VOX venue_team REMOVE receipt; WH credit skipped (dispatch %s)', p_dispatch_id));
    ELSIF p_filled_quantity > 0 THEN
      IF p_batch_breakdown IS NOT NULL AND jsonb_typeof(p_batch_breakdown) = 'array' THEN
        v_path := 'remove_breakdown';
        SELECT COALESCE(SUM((e->>'qty')::numeric), 0) INTO v_breakdown_total FROM jsonb_array_elements(p_batch_breakdown) e;
        IF v_breakdown_total <> p_filled_quantity THEN RAISE EXCEPTION 'Breakdown total (%) must equal filled_quantity (%)', v_breakdown_total, p_filled_quantity; END IF;
        FOR v_entry IN SELECT * FROM jsonb_array_elements(p_batch_breakdown) LOOP
          v_entry_qty := (v_entry->>'qty')::numeric;
          IF v_entry_qty <= 0 THEN CONTINUE; END IF;
          v_entry_expiry := NULLIF(v_entry->>'expiry', '')::date;
          v_entry_wh_id := NULLIF(v_entry->>'wh_inventory_id', '')::uuid;
          IF v_entry_wh_id IS NOT NULL THEN
            SELECT * INTO v_existing_row FROM warehouse_inventory WHERE wh_inventory_id = v_entry_wh_id FOR UPDATE;
            IF NOT FOUND THEN RAISE EXCEPTION 'Breakdown row id % not found', v_entry_wh_id; END IF;
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_entry_qty, status = CASE WHEN status = 'Inactive' THEN 'Active' ELSE status END WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
            v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_existing_row.wh_inventory_id, 'expiry', v_existing_row.expiration_date, 'qty', v_entry_qty);
            CONTINUE;
          END IF;
          IF v_entry_expiry IS NULL THEN RAISE EXCEPTION 'Breakdown entry must include expiry or wh_inventory_id (got %)', v_entry; END IF;
          PERFORM public.log_expiry_entry_suspect('receive_dispatch_line_breakdown', v_dispatch.dispatch_date,
            v_entry_expiry, jsonb_build_object('dispatch_id', p_dispatch_id, 'machine_id', v_dispatch.machine_id,
              'boonz_product_id', v_dispatch.boonz_product_id));
          SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date = v_entry_expiry ORDER BY created_at ASC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_entry_qty WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
          ELSE
            PERFORM set_config('app.provenance_reason', CASE WHEN v_dispatch.wh_approved_at IS NOT NULL THEN 'dispatch_receive' ELSE 'dispatch_return_unverified' END, true);
            INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id) VALUES (v_dispatch.boonz_product_id, v_entry_qty, v_entry_expiry, 'Active', format('REMOVE-RECEIVE-%s', v_dispatch.dispatch_date), CURRENT_DATE, v_target_wh) RETURNING wh_inventory_id INTO v_entry_wh_id;
            PERFORM set_config('app.provenance_reason','dispatch_receive', true);
            v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_entry_wh_id, 'expiry', v_entry_expiry, 'qty', v_entry_qty, 'mode', 'inserted');
          END IF;
        END LOOP;
      ELSIF v_effective_expiry IS NOT NULL THEN
        SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date = v_effective_expiry ORDER BY created_at ASC LIMIT 1 FOR UPDATE;
        IF FOUND THEN
          UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + p_filled_quantity WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
        ELSE
          PERFORM set_config('app.provenance_reason', CASE WHEN v_dispatch.wh_approved_at IS NOT NULL THEN 'dispatch_receive' ELSE 'dispatch_return_unverified' END, true);
          INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id) VALUES (v_dispatch.boonz_product_id, p_filled_quantity, v_effective_expiry, 'Active', format('REMOVE-RECEIVE-%s', v_dispatch.dispatch_date), CURRENT_DATE, v_target_wh);
          PERFORM set_config('app.provenance_reason','dispatch_receive', true);
        END IF;
      ELSE
        v_path := 'remove_fefo_fallback';
        SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date IS NOT NULL ORDER BY expiration_date ASC LIMIT 1 FOR UPDATE;
        IF FOUND THEN
          UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + p_filled_quantity WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
        ELSE
          SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + p_filled_quantity WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
          ELSE
            RAISE EXCEPTION 'Cannot receive REMOVE dispatch %: effective_expiry is NULL and no Active warehouse_inventory row exists for boonz_product=%, warehouse=%. Pass p_batch_breakdown with explicit expiry.', p_dispatch_id, v_dispatch.boonz_product_id, v_target_wh;
          END IF;
        END IF;
      END IF;
    END IF;
    UPDATE pod_inventory SET status = 'Inactive', removal_reason = format('removed_via_dispatch_%s', p_dispatch_id) WHERE machine_id = v_dispatch.machine_id AND boonz_product_id = v_dispatch.boonz_product_id AND (shelf_id = v_dispatch.shelf_id OR v_dispatch.shelf_id IS NULL) AND status = 'Active';
    GET DIAGNOSTICS v_pod_archived = ROW_COUNT;
  END IF;
  UPDATE refill_dispatching
     SET filled_quantity = p_filled_quantity, item_added = true, dispatched = true, packed = true, picked_up = true,
         remainder_credited = true,
         pack_outcome = CASE
           WHEN v_dispatch.action IN ('Refill','Add New','Add') AND NOT COALESCE(v_dispatch.is_m2m, false)
             THEN (CASE WHEN p_filled_quantity < v_planned THEN 'partial' ELSE 'packed' END)::public.pack_outcome_enum
           ELSE pack_outcome
         END
   WHERE dispatch_id = p_dispatch_id;
  RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'action', v_dispatch.action, 'filled_quantity', p_filled_quantity, 'planned_quantity', v_planned, 'return_delta', v_return_delta, 'overfill', v_overfill, 'pod_inventory_id', v_pod_id, 'pod_archived', v_pod_archived, 'prior_active_merged', v_prior_active_merged, 'consumer_drained', v_consumer_drawn, 'path', v_path, 'effective_expiry', v_effective_expiry, 'received_by', p_received_by, 'credit_summary', v_credit_summary, 'overfill_debits', v_overfill_debits, 'wh_credit_skipped', CASE WHEN COALESCE(v_dispatch.is_m2m,false) THEN 'm2m' WHEN v_supply = 'venue_team' THEN 'venue_team' ELSE NULL END, 'status', 'received', 'undo_prior_return_qty', v_undo_total);
END;
$function$;

CREATE OR REPLACE FUNCTION public.return_dispatch_line(p_dispatch_id uuid, p_return_reason text DEFAULT NULL::text, p_returned_by uuid DEFAULT NULL::uuid, p_batch_breakdown jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_dispatch refill_dispatching%ROWTYPE;
  v_consumer_row warehouse_inventory%ROWTYPE;
  v_return_qty numeric;
  v_target_wh uuid;
  v_pod_archived int := 0;
  v_path text := 'unknown';
  v_breakdown_total numeric := 0;
  v_entry jsonb;
  v_entry_qty numeric;
  v_entry_expiry date;
  v_entry_wh_id uuid;
  v_existing_row warehouse_inventory%ROWTYPE;
  v_credit_summary jsonb := '[]'::jsonb;
  v_effective_expiry date;
  v_origin_credited boolean := false;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'return_dispatch_line', true);
  PERFORM set_config('app.provenance_reason', 'dispatch_return', true);
  PERFORM set_config('app.source_event_id', p_dispatch_id::text, true);
  SELECT * INTO v_dispatch FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.returned = true THEN RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'status', 'already_returned', 'message', 'This dispatch was already returned, no changes made'); END IF;
  IF v_dispatch.action = 'Remove'
     AND COALESCE(public.is_internal_move_dispatch(p_dispatch_id), false) THEN
    RETURN jsonb_build_object(
      'dispatch_id', p_dispatch_id,
      'status',      'refused',
      'reason',      'internal_move_return_blocked',
      'machine_id',  v_dispatch.machine_id,
      'shelf_id',    v_dispatch.shelf_id,
      'message',     'This leg is an in-machine move: the units go to another shelf of this '
                  || 'same machine and never reach the warehouse. Crediting them would create '
                  || 'phantom warehouse stock. If it really is a warehouse return, call '
                  || 'clear_internal_move_flag(dispatch_id, reason) first.');
  END IF;
  IF COALESCE(v_dispatch.is_m2m, false) = true THEN
    RETURN jsonb_build_object(
      'dispatch_id', p_dispatch_id,
      'status', 'refused',
      'reason', 'm2m_return_blocked',
      'm2m_transfer_id', v_dispatch.m2m_transfer_id,
      'sibling_leg_dispatch_id',
        (SELECT r2.dispatch_id FROM public.refill_dispatching r2
          WHERE r2.m2m_transfer_id = v_dispatch.m2m_transfer_id
            AND r2.dispatch_id <> p_dispatch_id
          ORDER BY r2.dispatch_id LIMIT 1),
      'message', 'This is a machine-to-machine (M2M) transfer leg. Returning it here would mint warehouse stock for units physically at the partner machine. Unwind the transfer PAIR via the M2M flow (PRD-056), not return_dispatch_line.');
  END IF;
  IF v_dispatch.item_added = true THEN
    RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'status', 'refused', 'reason', 'already_received',
      'message', format('Dispatch %s already received (item_added=true); nothing to return.', p_dispatch_id));
  END IF;
  IF (v_dispatch.skipped = true OR v_dispatch.cancelled = true OR COALESCE(v_dispatch.include, true) = false)
     AND v_dispatch.packed = false AND v_dispatch.picked_up = false THEN
    RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'status', 'refused', 'reason', 'never_physical',
      'state', CASE WHEN v_dispatch.skipped THEN 'SKIPPED' WHEN v_dispatch.cancelled THEN 'CANCELLED' ELSE 'EXCLUDED' END,
      'skip_reason', COALESCE(v_dispatch.skip_reason, 'no reason recorded'),
      'message', format('Dispatch %s is %s and was never packed or picked up. Nothing physical to return.',
        p_dispatch_id, CASE WHEN v_dispatch.skipped THEN 'SKIPPED' WHEN v_dispatch.cancelled THEN 'CANCELLED' ELSE 'EXCLUDED (include=false)' END));
  END IF;
  IF p_returned_by IS NULL AND v_dispatch.packed = false AND v_dispatch.picked_up = false THEN
    RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'status', 'refused', 'reason', 'no_actor_non_physical',
      'message', format('Dispatch %s has no actor (system call) and was never packed or picked up. Refusing system return of a non-physical line.', p_dispatch_id));
  END IF;
  IF p_return_reason IS NULL OR length(trim(p_return_reason)) = 0 THEN
    RAISE EXCEPTION 'return_dispatch_line: p_return_reason is required for dispatch %', p_dispatch_id;
  END IF;
  v_target_wh := COALESCE(
    v_dispatch.from_warehouse_id,
    (SELECT primary_warehouse_id FROM public.machines WHERE machine_id = v_dispatch.machine_id));
  IF v_target_wh IS NULL THEN
    RAISE EXCEPTION 'return_dispatch_line: cannot resolve credit warehouse for dispatch % (from_warehouse_id NULL and machine % has no primary_warehouse_id). Refusing to silently credit WH_CENTRAL.', p_dispatch_id, v_dispatch.machine_id;
  END IF;
  IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN
    SELECT expiration_date INTO v_effective_expiry FROM warehouse_inventory WHERE wh_inventory_id = v_dispatch.from_wh_inventory_id;
  ELSE
    v_effective_expiry := v_dispatch.expiry_date;
  END IF;
  IF v_dispatch.action = 'Remove' THEN
    IF p_return_reason = 'Could not remove' THEN
      v_return_qty := 0;
      v_path := 'could_not_remove';
    ELSE
    v_return_qty := ABS(v_dispatch.quantity);
    v_path := 'remove';
    PERFORM set_config('app.mutation_reason', format('return_dispatch_line REMOVE: dispatch %s, %s units (reason: %s, by: %s, breakdown=%s, effective_expiry=%s)', p_dispatch_id, v_return_qty, COALESCE(p_return_reason, 'confirmed_removal'), COALESCE(p_returned_by::text, 'system'), p_batch_breakdown IS NOT NULL, v_effective_expiry), true);
    IF v_return_qty > 0 THEN
      IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN
        SELECT * INTO v_existing_row FROM warehouse_inventory WHERE wh_inventory_id = v_dispatch.from_wh_inventory_id FOR UPDATE;
        IF FOUND THEN
          v_path := 'remove_reactivate_origin';
          UPDATE warehouse_inventory
             SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_qty,
                 status = CASE WHEN status = 'Inactive' THEN 'Active' ELSE status END
           WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
          v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_existing_row.wh_inventory_id, 'expiry', v_existing_row.expiration_date, 'qty', v_return_qty, 'mode', 'reactivated_origin');
          v_origin_credited := true;
        END IF;
      END IF;
      IF NOT v_origin_credited THEN
      IF p_batch_breakdown IS NOT NULL AND jsonb_typeof(p_batch_breakdown) = 'array' THEN
        v_path := 'remove_breakdown';
        SELECT COALESCE(SUM((e->>'qty')::numeric), 0) INTO v_breakdown_total FROM jsonb_array_elements(p_batch_breakdown) e;
        IF v_breakdown_total <> v_return_qty THEN RAISE EXCEPTION 'Breakdown total (%) must equal dispatch quantity (%)', v_breakdown_total, v_return_qty; END IF;
        FOR v_entry IN SELECT * FROM jsonb_array_elements(p_batch_breakdown) LOOP
          v_entry_qty := (v_entry->>'qty')::numeric;
          IF v_entry_qty <= 0 THEN CONTINUE; END IF;
          v_entry_expiry := NULLIF(v_entry->>'expiry', '')::date;
          v_entry_wh_id := NULLIF(v_entry->>'wh_inventory_id', '')::uuid;
          IF v_entry_wh_id IS NOT NULL THEN
            SELECT * INTO v_existing_row FROM warehouse_inventory WHERE wh_inventory_id = v_entry_wh_id FOR UPDATE;
            IF NOT FOUND THEN RAISE EXCEPTION 'Breakdown row id % not found', v_entry_wh_id; END IF;
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_entry_qty, status = CASE WHEN status = 'Inactive' THEN 'Active' ELSE status END WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
            v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_existing_row.wh_inventory_id, 'expiry', v_existing_row.expiration_date, 'qty', v_entry_qty);
            CONTINUE;
          END IF;
          IF v_entry_expiry IS NULL THEN RAISE EXCEPTION 'Breakdown entry must include either expiry or wh_inventory_id (got %)', v_entry; END IF;
          SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date = v_entry_expiry ORDER BY created_at ASC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_entry_qty WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
            v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_existing_row.wh_inventory_id, 'expiry', v_entry_expiry, 'qty', v_entry_qty, 'mode', 'existing');
          ELSE
            PERFORM set_config('app.provenance_reason','dispatch_return_unverified', true);
            INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id) VALUES (v_dispatch.boonz_product_id, v_entry_qty, v_entry_expiry, 'Active', format('REMOVE-RETURN-%s', v_dispatch.dispatch_date), CURRENT_DATE, v_target_wh) RETURNING wh_inventory_id INTO v_entry_wh_id;
            PERFORM set_config('app.provenance_reason','dispatch_return', true);
            v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_entry_wh_id, 'expiry', v_entry_expiry, 'qty', v_entry_qty, 'mode', 'inserted');
          END IF;
        END LOOP;
      ELSIF v_effective_expiry IS NOT NULL THEN
        v_path := 'remove_single_expiry';
        SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date = v_effective_expiry ORDER BY created_at ASC LIMIT 1 FOR UPDATE;
        IF FOUND THEN
          UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_qty WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
        ELSE
          PERFORM set_config('app.provenance_reason','dispatch_return_unverified', true);
          INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id) VALUES (v_dispatch.boonz_product_id, v_return_qty, v_effective_expiry, 'Active', format('REMOVE-RETURN-%s', v_dispatch.dispatch_date), CURRENT_DATE, v_target_wh);
          PERFORM set_config('app.provenance_reason','dispatch_return', true);
        END IF;
      ELSE
        v_path := 'remove_fefo_fallback';
        SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date IS NOT NULL ORDER BY expiration_date ASC LIMIT 1 FOR UPDATE;
        IF FOUND THEN
          UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_qty WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
        ELSE
          SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_qty WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
          ELSE
            RAISE EXCEPTION 'Cannot return REMOVE dispatch %: effective_expiry is NULL and no Active warehouse_inventory row exists for boonz_product=%, warehouse=%. Pass p_batch_breakdown with explicit expiry.', p_dispatch_id, v_dispatch.boonz_product_id, v_target_wh;
          END IF;
        END IF;
      END IF;
      END IF;
    END IF;
    UPDATE pod_inventory SET status = 'Inactive', removal_reason = format('removed_via_dispatch_%s', p_dispatch_id) WHERE machine_id = v_dispatch.machine_id AND boonz_product_id = v_dispatch.boonz_product_id AND (shelf_id = v_dispatch.shelf_id OR v_dispatch.shelf_id IS NULL) AND status = 'Active';
    GET DIAGNOSTICS v_pod_archived = ROW_COUNT;
    END IF;
  ELSE
    v_return_qty := COALESCE(v_dispatch.filled_quantity, v_dispatch.quantity);
    PERFORM set_config('app.mutation_reason', format('return_dispatch_line: dispatch %s, %s units (reason: %s, by: %s, effective_expiry=%s)', p_dispatch_id, v_return_qty, COALESCE(p_return_reason, 'none'), COALESCE(p_returned_by::text, 'system'), v_effective_expiry), true);
    IF v_return_qty > 0 THEN
      IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN
        SELECT * INTO v_consumer_row FROM warehouse_inventory WHERE wh_inventory_id = v_dispatch.from_wh_inventory_id FOR UPDATE;
        IF FOUND AND COALESCE(v_consumer_row.consumer_stock, 0) > 0 THEN v_path := 'pinned'; ELSE v_consumer_row := NULL; END IF;
      END IF;
      IF v_consumer_row.wh_inventory_id IS NULL THEN
        SELECT * INTO v_consumer_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND COALESCE(consumer_stock, 0) > 0 AND (reserved_for_machine_id = v_dispatch.machine_id OR reserved_for_machine_id IS NULL) AND (expiration_date = v_effective_expiry OR v_effective_expiry IS NULL) ORDER BY (reserved_for_machine_id = v_dispatch.machine_id) DESC, consumer_stock DESC LIMIT 1 FOR UPDATE;
        IF FOUND THEN v_path := 'legacy'; END IF;
      END IF;
      IF v_consumer_row.wh_inventory_id IS NOT NULL THEN
        UPDATE warehouse_inventory SET consumer_stock  = GREATEST(COALESCE(consumer_stock, 0) - v_return_qty, 0), warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_qty, reserved_for_machine_id = CASE WHEN COALESCE(consumer_stock, 0) - v_return_qty <= 0 THEN NULL ELSE reserved_for_machine_id END, reserved_at = CASE WHEN COALESCE(consumer_stock, 0) - v_return_qty <= 0 THEN NULL ELSE reserved_at END WHERE wh_inventory_id = v_consumer_row.wh_inventory_id;
      END IF;
    END IF;
  END IF;
  UPDATE refill_dispatching SET returned = true, dispatched = true, filled_quantity = 0, return_reason = p_return_reason,
         pack_outcome = 'returned'::public.pack_outcome_enum
   WHERE dispatch_id = p_dispatch_id;
  RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'action', v_dispatch.action, 'return_qty', v_return_qty, 'return_reason', p_return_reason, 'returned_by', p_returned_by, 'consumer_drained', v_consumer_row.wh_inventory_id IS NOT NULL, 'pod_archived', v_pod_archived, 'path', v_path, 'effective_expiry', v_effective_expiry, 'credit_summary', v_credit_summary, 'status', 'returned');
END;
$function$;

CREATE OR REPLACE FUNCTION public.driver_confirm_remove(p_dispatch_id uuid, p_qty_removed numeric, p_batch_breakdown jsonb DEFAULT NULL::jsonb, p_driver_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_dispatch refill_dispatching%ROWTYPE;
  v_today date := (now() AT TIME ZONE 'Asia/Dubai')::date;
BEGIN
  SELECT * INTO v_dispatch FROM refill_dispatching
  WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.action <> 'Remove' THEN
    RAISE EXCEPTION 'driver_confirm_remove only works for action=Remove (got %)', v_dispatch.action;
  END IF;
  IF NOT v_dispatch.packed THEN RAISE EXCEPTION 'Dispatch not yet packed'; END IF;
  IF NOT v_dispatch.picked_up THEN RAISE EXCEPTION 'Dispatch not yet picked up'; END IF;
  IF v_dispatch.driver_confirmed_at IS NOT NULL THEN
    RAISE EXCEPTION 'Dispatch already driver-confirmed at % with qty %',
      v_dispatch.driver_confirmed_at, v_dispatch.driver_confirmed_qty;
  END IF;
  IF v_dispatch.item_added OR v_dispatch.returned THEN
    RAISE EXCEPTION 'Dispatch already terminal (item_added=% returned=%)',
      v_dispatch.item_added, v_dispatch.returned;
  END IF;
  IF p_qty_removed IS NULL OR p_qty_removed < 0 THEN
    RAISE EXCEPTION 'p_qty_removed must be >= 0 (use return_dispatch_line if no items removed)';
  END IF;
  IF COALESCE(jsonb_array_length(p_batch_breakdown), 0) = 0
     AND (v_dispatch.expiry_date IS NULL OR v_dispatch.expiry_date <= v_today + 7) THEN
    RAISE EXCEPTION 'driver_confirm_remove: this line''s bound expiry is % (or missing) - enter the expiry and quantity read off the pack for each variant via p_batch_breakdown before confirming',
      COALESCE(v_dispatch.expiry_date::text, 'NULL');
  END IF;
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'driver_confirm_remove', true);
  PERFORM set_config('app.mutation_reason',
    format('driver_confirm_remove by %s: %s units removed%s',
      COALESCE(p_driver_id::text, 'driver'), p_qty_removed,
      CASE WHEN p_notes IS NOT NULL THEN ' - ' || p_notes ELSE '' END), true);
  UPDATE refill_dispatching SET
    driver_confirmed_qty = p_qty_removed,
    driver_confirmed_at = now(),
    driver_confirmed_by = p_driver_id,
    driver_confirmed_breakdown = p_batch_breakdown,
    dispatched = true,
    comment = COALESCE(comment, '') ||
              CASE WHEN p_notes IS NOT NULL THEN E'\n[Driver: ' || p_notes || ']' ELSE '' END
  WHERE dispatch_id = p_dispatch_id;
  RETURN jsonb_build_object(
    'status', 'driver_confirmed_pending_wh_approval',
    'dispatch_id', p_dispatch_id,
    'qty_removed', p_qty_removed,
    'driver_id', p_driver_id,
    'next_step', 'WH manager reviews in Inventory tab and calls wh_approve_remove_receipt or wh_approve_remove_receipt_multivariant'
  );
END;
$function$;
