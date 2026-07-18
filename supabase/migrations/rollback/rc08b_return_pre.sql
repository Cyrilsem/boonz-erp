-- VERBATIM pre-B live body of return_dispatch_line (captured 2026-07-18). Included by rc08b_rollback.sql.
-- Restores the v_default_wh = '4bebef68...' (WH_CENTRAL) silent fallback.
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
  v_default_wh uuid := '4bebef68-9e36-4a5c-9c2c-142f8dbdae85';
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
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'return_dispatch_line', true);
  PERFORM set_config('app.provenance_reason', 'dispatch_return', true);
  PERFORM set_config('app.source_event_id', p_dispatch_id::text, true);
  SELECT * INTO v_dispatch FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.returned = true THEN RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'status', 'already_returned', 'message', 'This dispatch was already returned, no changes made'); END IF;
  IF v_dispatch.item_added = true THEN RAISE EXCEPTION 'Dispatch % already received (item_added=true), cannot return', p_dispatch_id; END IF;
  IF (v_dispatch.skipped = true OR v_dispatch.cancelled = true OR COALESCE(v_dispatch.include, true) = false)
     AND v_dispatch.packed = false AND v_dispatch.picked_up = false THEN
    RAISE EXCEPTION 'return_dispatch_line: dispatch % is % (skip_reason: %) and was never packed or picked up. Nothing physical to return.',
      p_dispatch_id,
      CASE WHEN v_dispatch.skipped THEN 'SKIPPED' WHEN v_dispatch.cancelled THEN 'CANCELLED' ELSE 'EXCLUDED (include=false)' END,
      COALESCE(v_dispatch.skip_reason, 'no reason recorded');
  END IF;
  IF p_returned_by IS NULL AND v_dispatch.packed = false AND v_dispatch.picked_up = false THEN
    RAISE EXCEPTION 'return_dispatch_line: dispatch % has no actor (system call) and was never packed or picked up. Refusing system return of a non-physical line.', p_dispatch_id;
  END IF;

  v_target_wh := COALESCE(v_dispatch.from_warehouse_id, v_default_wh);
  IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN
    SELECT expiration_date INTO v_effective_expiry FROM warehouse_inventory WHERE wh_inventory_id = v_dispatch.from_wh_inventory_id;
  ELSE
    v_effective_expiry := v_dispatch.expiry_date;
  END IF;
  IF v_dispatch.action = 'Remove' THEN
    v_return_qty := ABS(v_dispatch.quantity);
    v_path := 'remove';
    PERFORM set_config('app.mutation_reason', format('return_dispatch_line REMOVE: dispatch %s, %s units (reason: %s, by: %s, breakdown=%s, effective_expiry=%s)', p_dispatch_id, v_return_qty, COALESCE(p_return_reason, 'confirmed_removal'), COALESCE(p_returned_by::text, 'system'), p_batch_breakdown IS NOT NULL, v_effective_expiry), true);
    IF v_return_qty > 0 THEN
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
    UPDATE pod_inventory SET status = 'Inactive', removal_reason = format('removed_via_dispatch_%s', p_dispatch_id) WHERE machine_id = v_dispatch.machine_id AND boonz_product_id = v_dispatch.boonz_product_id AND (shelf_id = v_dispatch.shelf_id OR v_dispatch.shelf_id IS NULL) AND status = 'Active';
    GET DIAGNOSTICS v_pod_archived = ROW_COUNT;
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
  UPDATE refill_dispatching SET returned = true, dispatched = true, filled_quantity = 0, return_reason = p_return_reason WHERE dispatch_id = p_dispatch_id;
  RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'action', v_dispatch.action, 'return_qty', v_return_qty, 'return_reason', p_return_reason, 'returned_by', p_returned_by, 'consumer_drained', v_consumer_row.wh_inventory_id IS NOT NULL, 'pod_archived', v_pod_archived, 'path', v_path, 'effective_expiry', v_effective_expiry, 'credit_summary', v_credit_summary, 'status', 'returned');
END;
$function$;
