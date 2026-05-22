-- ============================================================================
-- PRD-003 FU#3 — provenance wiring for 4 more canonical writers
--
-- Builds on:
--   20260521230813_prd003_wh_inventory_provenance_quarantine.sql (scaffolding)
--   20260522091624_prd003_fu1_audit_insert_and_po_receive_provenance.sql
--
-- This migration adds the app.provenance_reason / app.source_event_id GUCs to:
--   - pack_dispatch_line          → 'dispatch_pack',   source = p_dispatch_id
--   - return_dispatch_line        → 'dispatch_return', source = p_dispatch_id
--   - adjust_warehouse_stock      → 'manual_adjust',   source = NULL (lax reason)
--   - transfer_warehouse_stock    → 'wh_transfer',     source = NULL (lax reason)
--
-- Bodies were retrieved from pg_proc via read-only Supabase MCP and re-emitted
-- with only the GUC plumbing added. Function signatures unchanged.
-- ============================================================================

BEGIN;

-- ── pack_dispatch_line ──────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.pack_dispatch_line(
  p_dispatch_id uuid,
  p_picks jsonb,
  p_packed_by uuid DEFAULT NULL::uuid
)
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
  -- PRD-003 FU#3
  PERFORM set_config('app.provenance_reason', 'dispatch_pack', true);
  PERFORM set_config('app.source_event_id', p_dispatch_id::text, true);

  SELECT * INTO v_dispatch FROM refill_dispatching
  WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.packed = true THEN RAISE EXCEPTION 'Already packed'; END IF;
  IF v_dispatch.action NOT IN ('Refill','Add New','Add') THEN
    UPDATE refill_dispatching SET packed = true WHERE dispatch_id = p_dispatch_id;
    RETURN jsonb_build_object('status', 'packed_no_pick', 'dispatch_id', p_dispatch_id);
  END IF;

  SELECT COALESCE(SUM((p->>'qty')::numeric), 0) INTO v_total_picked
  FROM jsonb_array_elements(p_picks) p;

  IF v_total_picked < 1 THEN
    RAISE EXCEPTION 'Total pick quantity must be at least 1 (got %)', v_total_picked;
  END IF;
  IF v_total_picked > v_dispatch.quantity THEN
    RAISE EXCEPTION 'Pick total (%) exceeds planned quantity (%)',
      v_total_picked, v_dispatch.quantity;
  END IF;

  PERFORM set_config('app.mutation_reason',
    format('B3 pack: dispatch %s picking %s units total (planned %s)',
           p_dispatch_id, v_total_picked, v_dispatch.quantity),
    true);

  FOR v_pick IN SELECT * FROM jsonb_array_elements(p_picks)
  LOOP
    v_pick_qty := (v_pick->>'qty')::numeric;
    IF v_pick_qty <= 0 THEN CONTINUE; END IF;

    v_pick_bpid := COALESCE(
      (v_pick->>'boonz_product_id')::uuid,
      v_dispatch.boonz_product_id
    );

    SELECT * INTO v_wh_row FROM warehouse_inventory
    WHERE wh_inventory_id = (v_pick->>'wh_inventory_id')::uuid
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'WH row % not found', v_pick->>'wh_inventory_id';
    END IF;
    IF COALESCE(v_wh_row.warehouse_stock, 0) < v_pick_qty THEN
      RAISE EXCEPTION 'WH row % has only % units, cannot pick %',
        v_wh_row.wh_inventory_id, v_wh_row.warehouse_stock, v_pick_qty;
    END IF;

    UPDATE warehouse_inventory
    SET warehouse_stock = COALESCE(warehouse_stock, 0) - v_pick_qty,
        consumer_stock  = COALESCE(consumer_stock, 0) + v_pick_qty,
        reserved_for_machine_id = COALESCE(reserved_for_machine_id, v_dispatch.machine_id),
        reserved_at = COALESCE(reserved_at, now())
    WHERE wh_inventory_id = v_wh_row.wh_inventory_id;

    IF v_first_pick THEN
      UPDATE refill_dispatching SET packed = false WHERE dispatch_id = p_dispatch_id;
      UPDATE refill_dispatching
      SET packed = true,
          expiry_date = v_wh_row.expiration_date,
          filled_quantity = v_pick_qty,
          boonz_product_id = v_pick_bpid,
          quantity = v_total_picked,
          from_wh_inventory_id = v_wh_row.wh_inventory_id  -- BUG-006 fix
      WHERE dispatch_id = p_dispatch_id;
      v_first_pick := false;
    ELSE
      INSERT INTO refill_dispatching (
        machine_id, shelf_id, pod_product_id, boonz_product_id,
        dispatch_date, action, quantity, filled_quantity, include,
        packed, picked_up, dispatched, returned, item_added, expiry_date,
        from_wh_inventory_id  -- BUG-006 fix
      ) VALUES (
        v_dispatch.machine_id, v_dispatch.shelf_id, v_dispatch.pod_product_id,
        v_pick_bpid,
        v_dispatch.dispatch_date, v_dispatch.action,
        v_pick_qty, v_pick_qty, true,
        true, false, false, false, false, v_wh_row.expiration_date,
        v_wh_row.wh_inventory_id
      ) RETURNING dispatch_id INTO v_new_child_id;
    END IF;

    v_picks_used := v_picks_used || jsonb_build_object(
      'wh_inventory_id', v_wh_row.wh_inventory_id,
      'batch_id', v_wh_row.batch_id,
      'expiry', v_wh_row.expiration_date,
      'qty', v_pick_qty,
      'boonz_product_id', v_pick_bpid,
      'child_dispatch_id', v_new_child_id
    );
  END LOOP;

  RETURN jsonb_build_object(
    'status', 'packed',
    'dispatch_id', p_dispatch_id,
    'total_picked', v_total_picked,
    'planned_quantity', v_dispatch.quantity,
    'picks', v_picks_used
  );
END;
$function$;

-- ── return_dispatch_line ────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.return_dispatch_line(
  p_dispatch_id uuid,
  p_return_reason text DEFAULT NULL::text,
  p_returned_by uuid DEFAULT NULL::uuid,
  p_batch_breakdown jsonb DEFAULT NULL::jsonb
)
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
  -- PRD-003 FU#3
  PERFORM set_config('app.provenance_reason', 'dispatch_return', true);
  PERFORM set_config('app.source_event_id', p_dispatch_id::text, true);

  SELECT * INTO v_dispatch FROM refill_dispatching
  WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;

  IF v_dispatch.returned = true THEN
    RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'status', 'already_returned',
      'message', 'This dispatch was already returned, no changes made');
  END IF;

  IF v_dispatch.item_added = true THEN
    RAISE EXCEPTION 'Dispatch % already received (item_added=true), cannot return', p_dispatch_id;
  END IF;

  v_target_wh := COALESCE(v_dispatch.from_warehouse_id, v_default_wh);

  IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN
    SELECT expiration_date INTO v_effective_expiry
    FROM warehouse_inventory
    WHERE wh_inventory_id = v_dispatch.from_wh_inventory_id;
  ELSE
    v_effective_expiry := v_dispatch.expiry_date;
  END IF;

  IF v_dispatch.action = 'Remove' THEN
    v_return_qty := ABS(v_dispatch.quantity);
    v_path := 'remove';

    PERFORM set_config('app.mutation_reason',
      format('return_dispatch_line REMOVE: dispatch %s, %s units (reason: %s, by: %s, breakdown=%s, effective_expiry=%s)',
             p_dispatch_id, v_return_qty,
             COALESCE(p_return_reason, 'confirmed_removal'),
             COALESCE(p_returned_by::text, 'system'),
             p_batch_breakdown IS NOT NULL,
             v_effective_expiry), true);

    IF v_return_qty > 0 THEN
      IF p_batch_breakdown IS NOT NULL AND jsonb_typeof(p_batch_breakdown) = 'array' THEN
        v_path := 'remove_breakdown';
        SELECT COALESCE(SUM((e->>'qty')::numeric), 0) INTO v_breakdown_total
        FROM jsonb_array_elements(p_batch_breakdown) e;
        IF v_breakdown_total <> v_return_qty THEN
          RAISE EXCEPTION 'Breakdown total (%) must equal dispatch quantity (%)',
            v_breakdown_total, v_return_qty;
        END IF;

        FOR v_entry IN SELECT * FROM jsonb_array_elements(p_batch_breakdown)
        LOOP
          v_entry_qty := (v_entry->>'qty')::numeric;
          IF v_entry_qty <= 0 THEN CONTINUE; END IF;
          v_entry_expiry := NULLIF(v_entry->>'expiry', '')::date;
          v_entry_wh_id := NULLIF(v_entry->>'wh_inventory_id', '')::uuid;

          IF v_entry_wh_id IS NOT NULL THEN
            SELECT * INTO v_existing_row FROM warehouse_inventory
            WHERE wh_inventory_id = v_entry_wh_id FOR UPDATE;
            IF NOT FOUND THEN
              RAISE EXCEPTION 'Breakdown row id % not found', v_entry_wh_id;
            END IF;
            UPDATE warehouse_inventory
            SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_entry_qty,
                status = CASE WHEN status = 'Inactive' THEN 'Active' ELSE status END
            WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
            v_credit_summary := v_credit_summary || jsonb_build_object(
              'wh_inventory_id', v_existing_row.wh_inventory_id,
              'expiry', v_existing_row.expiration_date,
              'qty', v_entry_qty
            );
            CONTINUE;
          END IF;

          IF v_entry_expiry IS NULL THEN
            RAISE EXCEPTION 'Breakdown entry must include either expiry or wh_inventory_id (got %)', v_entry;
          END IF;

          SELECT * INTO v_existing_row FROM warehouse_inventory
          WHERE boonz_product_id = v_dispatch.boonz_product_id
            AND warehouse_id = v_target_wh
            AND status = 'Active'
            AND expiration_date = v_entry_expiry
          ORDER BY created_at ASC LIMIT 1 FOR UPDATE;

          IF FOUND THEN
            UPDATE warehouse_inventory
            SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_entry_qty
            WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
            v_credit_summary := v_credit_summary || jsonb_build_object(
              'wh_inventory_id', v_existing_row.wh_inventory_id,
              'expiry', v_entry_expiry, 'qty', v_entry_qty, 'mode', 'existing');
          ELSE
            INSERT INTO warehouse_inventory
              (boonz_product_id, warehouse_stock, expiration_date, status,
               batch_id, snapshot_date, warehouse_id)
            VALUES
              (v_dispatch.boonz_product_id, v_entry_qty, v_entry_expiry,
               'Active', format('REMOVE-RETURN-%s', v_dispatch.dispatch_date),
               CURRENT_DATE, v_target_wh)
            RETURNING wh_inventory_id INTO v_entry_wh_id;
            v_credit_summary := v_credit_summary || jsonb_build_object(
              'wh_inventory_id', v_entry_wh_id,
              'expiry', v_entry_expiry, 'qty', v_entry_qty, 'mode', 'inserted');
          END IF;
        END LOOP;

      ELSIF v_effective_expiry IS NOT NULL THEN
        v_path := 'remove_single_expiry';
        SELECT * INTO v_existing_row FROM warehouse_inventory
        WHERE boonz_product_id = v_dispatch.boonz_product_id
          AND warehouse_id = v_target_wh
          AND status = 'Active'
          AND expiration_date = v_effective_expiry
        ORDER BY created_at ASC LIMIT 1 FOR UPDATE;

        IF FOUND THEN
          UPDATE warehouse_inventory
          SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_qty
          WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
        ELSE
          INSERT INTO warehouse_inventory
            (boonz_product_id, warehouse_stock, expiration_date, status,
             batch_id, snapshot_date, warehouse_id)
          VALUES
            (v_dispatch.boonz_product_id, v_return_qty, v_effective_expiry,
             'Active', format('REMOVE-RETURN-%s', v_dispatch.dispatch_date),
             CURRENT_DATE, v_target_wh);
        END IF;

      ELSE
        v_path := 'remove_fefo_fallback';
        SELECT * INTO v_existing_row FROM warehouse_inventory
        WHERE boonz_product_id = v_dispatch.boonz_product_id
          AND warehouse_id = v_target_wh
          AND status = 'Active'
          AND expiration_date IS NOT NULL
        ORDER BY expiration_date ASC LIMIT 1 FOR UPDATE;

        IF FOUND THEN
          UPDATE warehouse_inventory
          SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_qty
          WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
        ELSE
          SELECT * INTO v_existing_row FROM warehouse_inventory
          WHERE boonz_product_id = v_dispatch.boonz_product_id
            AND warehouse_id = v_target_wh
            AND status = 'Active'
          ORDER BY created_at DESC LIMIT 1 FOR UPDATE;

          IF FOUND THEN
            UPDATE warehouse_inventory
            SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_qty
            WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
          ELSE
            RAISE EXCEPTION
              'Cannot return REMOVE dispatch %: effective_expiry is NULL and no Active warehouse_inventory row exists for boonz_product=%, warehouse=%. Pass p_batch_breakdown with explicit expiry.',
              p_dispatch_id, v_dispatch.boonz_product_id, v_target_wh;
          END IF;
        END IF;
      END IF;
    END IF;

    UPDATE pod_inventory
    SET status = 'Inactive',
        removal_reason = format('removed_via_dispatch_%s', p_dispatch_id)
    WHERE machine_id = v_dispatch.machine_id
      AND boonz_product_id = v_dispatch.boonz_product_id
      AND (shelf_id = v_dispatch.shelf_id OR v_dispatch.shelf_id IS NULL)
      AND status = 'Active';
    GET DIAGNOSTICS v_pod_archived = ROW_COUNT;

  ELSE
    v_return_qty := COALESCE(v_dispatch.filled_quantity, v_dispatch.quantity);

    PERFORM set_config('app.mutation_reason',
      format('return_dispatch_line: dispatch %s, %s units (reason: %s, by: %s, effective_expiry=%s)',
             p_dispatch_id, v_return_qty, COALESCE(p_return_reason, 'none'),
             COALESCE(p_returned_by::text, 'system'),
             v_effective_expiry), true);

    IF v_return_qty > 0 THEN
      IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN
        SELECT * INTO v_consumer_row FROM warehouse_inventory
        WHERE wh_inventory_id = v_dispatch.from_wh_inventory_id
        FOR UPDATE;
        IF FOUND AND COALESCE(v_consumer_row.consumer_stock, 0) > 0 THEN
          v_path := 'pinned';
        ELSE
          v_consumer_row := NULL;
        END IF;
      END IF;

      IF v_consumer_row.wh_inventory_id IS NULL THEN
        SELECT * INTO v_consumer_row FROM warehouse_inventory
        WHERE boonz_product_id = v_dispatch.boonz_product_id
          AND COALESCE(consumer_stock, 0) > 0
          AND (reserved_for_machine_id = v_dispatch.machine_id OR reserved_for_machine_id IS NULL)
          AND (expiration_date = v_effective_expiry OR v_effective_expiry IS NULL)
        ORDER BY (reserved_for_machine_id = v_dispatch.machine_id) DESC, consumer_stock DESC
        LIMIT 1 FOR UPDATE;
        IF FOUND THEN v_path := 'legacy'; END IF;
      END IF;

      IF v_consumer_row.wh_inventory_id IS NOT NULL THEN
        UPDATE warehouse_inventory
        SET consumer_stock  = GREATEST(COALESCE(consumer_stock, 0) - v_return_qty, 0),
            warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_qty,
            reserved_for_machine_id = CASE
              WHEN COALESCE(consumer_stock, 0) - v_return_qty <= 0 THEN NULL
              ELSE reserved_for_machine_id END,
            reserved_at = CASE
              WHEN COALESCE(consumer_stock, 0) - v_return_qty <= 0 THEN NULL
              ELSE reserved_at END
        WHERE wh_inventory_id = v_consumer_row.wh_inventory_id;
      END IF;
    END IF;
  END IF;

  UPDATE refill_dispatching
  SET returned = true,
      dispatched = true,
      filled_quantity = 0,
      return_reason = p_return_reason
  WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object(
    'dispatch_id', p_dispatch_id,
    'action', v_dispatch.action,
    'return_qty', v_return_qty,
    'return_reason', p_return_reason,
    'returned_by', p_returned_by,
    'consumer_drained', v_consumer_row.wh_inventory_id IS NOT NULL,
    'pod_archived', v_pod_archived,
    'path', v_path,
    'effective_expiry', v_effective_expiry,
    'credit_summary', v_credit_summary,
    'status', 'returned'
  );
END;
$function$;

-- ── adjust_warehouse_stock ──────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.adjust_warehouse_stock(
  p_warehouse_id uuid,
  p_lines jsonb,
  p_snapshot_date date DEFAULT CURRENT_DATE,
  p_reason text DEFAULT 'physical_count_reconciliation'::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role text; v_caller_id uuid;
  v_line jsonb; v_boonz_id uuid; v_new_wh numeric; v_new_cs numeric;
  v_exp_date date; v_batch text; v_status_val text; v_wh_inv_id uuid;
  v_old_wh numeric; v_old_cs numeric; v_old_exp date;
  v_found boolean;
  v_updated int := 0; v_inserted int := 0; v_unchanged int := 0;
  v_details jsonb := '[]'::jsonb; v_wh_name text;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'adjust_warehouse_stock', true);
  -- PRD-003 FU#3: manual adjustments are lax-reason (no single source event)
  PERFORM set_config('app.provenance_reason', 'manual_adjust', true);

  SELECT role INTO v_caller_role FROM user_profiles WHERE id = auth.uid();
  v_caller_id := auth.uid();
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'adjust_warehouse_stock: forbidden for role %', COALESCE(v_caller_role,'anon');
  END IF;

  SELECT name INTO v_wh_name FROM warehouses WHERE warehouse_id = p_warehouse_id;
  IF v_wh_name IS NULL THEN RAISE EXCEPTION 'adjust_warehouse_stock: warehouse % not found', p_warehouse_id; END IF;
  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN RAISE EXCEPTION 'adjust_warehouse_stock: p_lines must be a non-empty array'; END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_boonz_id  := (v_line->>'boonz_product_id')::uuid;
    v_new_wh    := COALESCE((v_line->>'new_warehouse_stock')::numeric, 0);
    v_new_cs    := COALESCE((v_line->>'new_consumer_stock')::numeric, 0);
    v_exp_date  := (v_line->>'expiration_date')::date;
    v_batch     := v_line->>'batch_id';
    v_status_val:= COALESCE(v_line->>'status', 'Active');
    v_wh_inv_id := (v_line->>'wh_inventory_id')::uuid;
    v_found := false;

    IF v_wh_inv_id IS NOT NULL THEN
      SELECT warehouse_stock, consumer_stock, expiration_date INTO v_old_wh, v_old_cs, v_old_exp
      FROM warehouse_inventory WHERE wh_inventory_id = v_wh_inv_id AND warehouse_id = p_warehouse_id;
      IF FOUND THEN v_found := true; END IF;
    ELSE
      SELECT wh_inventory_id, warehouse_stock, consumer_stock, expiration_date
      INTO v_wh_inv_id, v_old_wh, v_old_cs, v_old_exp
      FROM warehouse_inventory
      WHERE warehouse_id = p_warehouse_id AND boonz_product_id = v_boonz_id
        AND expiration_date IS NOT DISTINCT FROM v_exp_date
      ORDER BY created_at ASC LIMIT 1;
      IF FOUND THEN v_found := true; END IF;
    END IF;

    IF v_found THEN
      IF v_old_wh = v_new_wh AND COALESCE(v_old_cs,0) = v_new_cs
         AND (v_exp_date IS NULL OR v_old_exp IS NOT DISTINCT FROM v_exp_date) THEN
        v_unchanged := v_unchanged + 1;
        v_details := v_details || jsonb_build_object('boonz_product_id',v_boonz_id,'wh_inventory_id',v_wh_inv_id,'action','unchanged');
        CONTINUE;
      END IF;

      -- PRD-003 FU#3: pin source_event_id to the wh_inventory_id being adjusted
      -- so the audit trail and provenance line up.
      PERFORM set_config('app.source_event_id', v_wh_inv_id::text, true);

      UPDATE warehouse_inventory
      SET warehouse_stock = v_new_wh, consumer_stock = v_new_cs, snapshot_date = p_snapshot_date,
          expiration_date = COALESCE(v_exp_date, expiration_date), batch_id = COALESCE(v_batch, batch_id),
          status = v_status_val
      WHERE wh_inventory_id = v_wh_inv_id;

      IF v_old_wh IS DISTINCT FROM v_new_wh THEN
        INSERT INTO inventory_audit_log (audit_id,wh_inventory_id,boonz_product_id,adjusted_by,old_qty,new_qty,reason,audited_at)
        VALUES (gen_random_uuid(),v_wh_inv_id,v_boonz_id,v_caller_id,v_old_wh,v_new_wh,p_reason||' [warehouse_stock]',now());
      END IF;
      IF COALESCE(v_old_cs,0) IS DISTINCT FROM v_new_cs THEN
        INSERT INTO inventory_audit_log (audit_id,wh_inventory_id,boonz_product_id,adjusted_by,old_qty,new_qty,reason,audited_at)
        VALUES (gen_random_uuid(),v_wh_inv_id,v_boonz_id,v_caller_id,COALESCE(v_old_cs,0),v_new_cs,p_reason||' [consumer_stock]',now());
      END IF;

      v_updated := v_updated + 1;
      v_details := v_details || jsonb_build_object('boonz_product_id',v_boonz_id,'wh_inventory_id',v_wh_inv_id,'action','updated','old_wh',v_old_wh,'new_wh',v_new_wh);
    ELSE
      v_wh_inv_id := gen_random_uuid();
      -- New row: source_event = the new wh_inventory_id (self-referential
      -- because manual_adjust has no upstream event to point at).
      PERFORM set_config('app.source_event_id', v_wh_inv_id::text, true);

      INSERT INTO warehouse_inventory (wh_inventory_id,boonz_product_id,snapshot_date,warehouse_stock,consumer_stock,expiration_date,batch_id,status,warehouse_id,created_at)
      VALUES (v_wh_inv_id,v_boonz_id,p_snapshot_date,v_new_wh,v_new_cs,v_exp_date,v_batch,v_status_val,p_warehouse_id,now());

      INSERT INTO inventory_audit_log (audit_id,wh_inventory_id,boonz_product_id,adjusted_by,old_qty,new_qty,reason,audited_at)
      VALUES (gen_random_uuid(),v_wh_inv_id,v_boonz_id,v_caller_id,0,v_new_wh,p_reason||' [new_row]',now());

      v_inserted := v_inserted + 1;
      v_details := v_details || jsonb_build_object('boonz_product_id',v_boonz_id,'wh_inventory_id',v_wh_inv_id,'action','inserted','warehouse_stock',v_new_wh,'expiration_date',v_exp_date);
    END IF;
  END LOOP;

  RETURN jsonb_build_object('status','ok','warehouse',v_wh_name,'warehouse_id',p_warehouse_id,
    'lines_processed',v_updated+v_inserted+v_unchanged,'lines_updated',v_updated,'lines_inserted',v_inserted,'lines_unchanged',v_unchanged,'reason',p_reason,'details',v_details);
END;
$function$;

-- ── transfer_warehouse_stock ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.transfer_warehouse_stock(
  p_source_warehouse_id uuid,
  p_dest_warehouse_id uuid,
  p_lines jsonb,
  p_transfer_date date DEFAULT CURRENT_DATE,
  p_reason text DEFAULT 'inter_warehouse_transfer'::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_role text;
  v_line jsonb;
  v_bpid uuid;
  v_qty numeric;
  v_exp date;
  v_remaining numeric;
  v_src_row warehouse_inventory%ROWTYPE;
  v_pick numeric;
  v_dest_row warehouse_inventory%ROWTYPE;
  v_src_wh_name text;
  v_dest_wh_name text;
  v_dest_cold boolean;
  v_product_temp text;
  v_product_name text;
  v_lines_processed int := 0;
  v_total_units numeric := 0;
  v_audit_details jsonb := '[]'::jsonb;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'transfer_warehouse_stock', true);
  -- PRD-003 FU#3
  PERFORM set_config('app.provenance_reason', 'wh_transfer', true);

  SELECT role INTO v_role FROM user_profiles WHERE id = auth.uid();
  IF v_role IS NULL OR v_role NOT IN ('warehouse', 'operator_admin', 'superadmin', 'manager') THEN
    RAISE EXCEPTION 'Unauthorized: role "%" cannot transfer stock', COALESCE(v_role, 'none');
  END IF;

  SELECT name INTO v_src_wh_name FROM warehouses WHERE warehouse_id = p_source_warehouse_id;
  IF v_src_wh_name IS NULL THEN
    RAISE EXCEPTION 'Source warehouse % not found', p_source_warehouse_id;
  END IF;

  SELECT name, allows_cold_storage INTO v_dest_wh_name, v_dest_cold
  FROM warehouses WHERE warehouse_id = p_dest_warehouse_id;
  IF v_dest_wh_name IS NULL THEN
    RAISE EXCEPTION 'Destination warehouse % not found', p_dest_warehouse_id;
  END IF;

  IF p_source_warehouse_id = p_dest_warehouse_id THEN
    RAISE EXCEPTION 'Source and destination warehouse cannot be the same';
  END IF;

  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'p_lines must be a non-empty JSON array';
  END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_bpid := (v_line->>'boonz_product_id')::uuid;
    v_qty  := (v_line->>'qty')::numeric;
    v_exp  := (v_line->>'expiration_date')::date;

    IF v_bpid IS NULL THEN RAISE EXCEPTION 'boonz_product_id is required in every line'; END IF;
    IF v_qty IS NULL OR v_qty <= 0 THEN RAISE EXCEPTION 'qty must be > 0'; END IF;

    SELECT bp.storage_temp_requirement, bp.boonz_product_name
    INTO v_product_temp, v_product_name
    FROM boonz_products bp WHERE bp.product_id = v_bpid;

    IF v_product_name IS NULL THEN
      RAISE EXCEPTION 'boonz_product_id % not found', v_bpid;
    END IF;

    IF v_product_temp = 'cold' AND v_dest_cold = false THEN
      RAISE EXCEPTION 'Cannot transfer cold product "%" to % (no cold storage)',
        v_product_name, v_dest_wh_name;
    END IF;

    v_remaining := v_qty;

    FOR v_src_row IN
      SELECT * FROM warehouse_inventory
      WHERE boonz_product_id = v_bpid
        AND warehouse_id = p_source_warehouse_id
        AND status = 'Active'
        AND COALESCE(warehouse_stock, 0) > 0
        AND (v_exp IS NULL OR expiration_date = v_exp)
      ORDER BY expiration_date ASC NULLS LAST, created_at ASC
      FOR UPDATE
    LOOP
      EXIT WHEN v_remaining <= 0;
      v_pick := LEAST(v_remaining, v_src_row.warehouse_stock);

      -- PRD-003 FU#3: pin source_event_id to the source wh_inventory_id so
      -- both legs of the transfer are joinable via the same event reference.
      PERFORM set_config('app.source_event_id', v_src_row.wh_inventory_id::text, true);

      UPDATE warehouse_inventory
      SET warehouse_stock = COALESCE(warehouse_stock, 0) - v_pick
      WHERE wh_inventory_id = v_src_row.wh_inventory_id;

      INSERT INTO inventory_audit_log (
        wh_inventory_id, boonz_product_id, adjusted_by,
        old_qty, new_qty, reason
      ) VALUES (
        v_src_row.wh_inventory_id, v_bpid, auth.uid(),
        v_src_row.warehouse_stock,
        v_src_row.warehouse_stock - v_pick,
        format('Transfer OUT to %s: %s units of %s (exp %s) — %s',
               v_dest_wh_name, v_pick, v_product_name,
               COALESCE(v_src_row.expiration_date::text, 'no-exp'), p_reason)
      );

      SELECT * INTO v_dest_row FROM warehouse_inventory
      WHERE boonz_product_id = v_bpid
        AND warehouse_id = p_dest_warehouse_id
        AND (expiration_date = v_src_row.expiration_date
             OR (expiration_date IS NULL AND v_src_row.expiration_date IS NULL))
      ORDER BY created_at DESC LIMIT 1
      FOR UPDATE;

      IF FOUND THEN
        UPDATE warehouse_inventory
        SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_pick, status = 'Active'
        WHERE wh_inventory_id = v_dest_row.wh_inventory_id;

        INSERT INTO inventory_audit_log (
          wh_inventory_id, boonz_product_id, adjusted_by,
          old_qty, new_qty, reason
        ) VALUES (
          v_dest_row.wh_inventory_id, v_bpid, auth.uid(),
          COALESCE(v_dest_row.warehouse_stock, 0),
          COALESCE(v_dest_row.warehouse_stock, 0) + v_pick,
          format('Transfer IN from %s: %s units of %s (exp %s) — %s',
                 v_src_wh_name, v_pick, v_product_name,
                 COALESCE(v_src_row.expiration_date::text, 'no-exp'), p_reason)
        );
      ELSE
        INSERT INTO warehouse_inventory (
          boonz_product_id, warehouse_id, warehouse_stock, consumer_stock,
          expiration_date, batch_id, snapshot_date, status
        ) VALUES (
          v_bpid, p_dest_warehouse_id, v_pick, 0,
          v_src_row.expiration_date,
          format('TRANSFER-%s-%s', p_transfer_date, v_src_wh_name),
          p_transfer_date, 'Active'
        );
      END IF;

      v_remaining := v_remaining - v_pick;
      v_total_units := v_total_units + v_pick;

      v_audit_details := v_audit_details || jsonb_build_object(
        'product', v_product_name,
        'qty_transferred', v_pick,
        'expiration_date', v_src_row.expiration_date,
        'source_batch', v_src_row.wh_inventory_id,
        'remaining_at_source', v_src_row.warehouse_stock - v_pick
      );
    END LOOP;

    IF v_remaining > 0 THEN
      RAISE EXCEPTION 'Insufficient stock for "%": need % more units in % (after FIFO pick)',
        v_product_name, v_remaining, v_src_wh_name;
    END IF;

    v_lines_processed := v_lines_processed + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'status', 'ok',
    'lines_processed', v_lines_processed,
    'total_units_transferred', v_total_units,
    'source_warehouse', v_src_wh_name,
    'dest_warehouse', v_dest_wh_name,
    'transfer_date', p_transfer_date,
    'details', v_audit_details
  );
END;
$function$;

COMMIT;

-- ============================================================================
-- POST-APPLY VERIFICATION
--   For each patched RPC, query pg_get_functiondef and confirm the new
--   PERFORM set_config('app.provenance_reason', ...) call is present at the
--   top of the body.
--
--   End-to-end: run a small pack→return cycle and confirm the rows end up
--   with provenance_reason='dispatch_pack' (on the pack-time consumer_stock
--   movement) and 'dispatch_return' (on the return), source_event_id =
--   dispatch_id in both cases. quarantined should be false throughout.
--
-- STILL DEFERRED — 5 writers remain unpatched:
--   receive_dispatch_line, log_manual_refill, upsert_refill_stock_snapshot,
--   confirm_warehouse_status_proposal, add_sanity_increment, auto_sanity_check.
--   Mechanical follow-up — fetch body via pg_proc, add two PERFORM set_config
--   calls, ship as a follow-up migration.
-- ============================================================================
