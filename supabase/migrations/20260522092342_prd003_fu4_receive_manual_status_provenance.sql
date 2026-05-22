-- ============================================================================
-- PRD-003 FU#4 — provenance wiring for 3 more canonical writers
--
-- Builds on:
--   20260521230813_prd003_wh_inventory_provenance_quarantine.sql (scaffolding)
--   20260522091624_prd003_fu1_audit_insert_and_po_receive_provenance.sql
--   20260522091958_prd003_fu3_dispatch_and_transfer_provenance.sql
--
-- This migration patches:
--   - receive_dispatch_line             → 'dispatch_receive', source = p_dispatch_id
--   - log_manual_refill                 → 'manual_adjust',    source = NULL (lax)
--   - confirm_warehouse_status_proposal → 'status_flip',      source = p_proposal_id
--
-- After this migration, 8 of the 11 canonical WH writers carry provenance:
--   ✅ receive_purchase_order             (FU#2)
--   ✅ pack_dispatch_line                 (FU#3)
--   ✅ return_dispatch_line               (FU#3)
--   ✅ adjust_warehouse_stock             (FU#3)
--   ✅ transfer_warehouse_stock           (FU#3)
--   ✅ receive_dispatch_line              (this migration)
--   ✅ log_manual_refill                  (this migration)
--   ✅ confirm_warehouse_status_proposal  (this migration)
--   ⏳ upsert_refill_stock_snapshot       (deferred)
--   ⏳ add_sanity_increment               (deferred)
--   ⏳ auto_sanity_check                  (deferred)
--   N/A swap_between_machines             (no WH writes per RPC_REGISTRY)
--   N/A return_all_dispatches_for_machine (calls return_dispatch_line — inherits)
--
-- Bodies retrieved from pg_proc via read-only Supabase MCP and re-emitted
-- minimally — only the GUC plumbing added.
-- ============================================================================

BEGIN;

-- ── receive_dispatch_line ───────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.receive_dispatch_line(
  p_dispatch_id uuid,
  p_filled_quantity numeric,
  p_received_by uuid DEFAULT NULL::uuid,
  p_batch_breakdown jsonb DEFAULT NULL::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_dispatch refill_dispatching%ROWTYPE;
  v_planned numeric;
  v_return_delta numeric;
  v_overfill numeric;
  v_consumer_row warehouse_inventory%ROWTYPE;
  v_wh_row warehouse_inventory%ROWTYPE;
  v_pod_id uuid;
  v_consumer_drawn numeric := 0;
  v_path text;
  v_default_wh uuid := '4bebef68-9e36-4a5c-9c2c-142f8dbdae85';
  v_target_wh uuid;
  v_pod_archived int := 0;
  v_breakdown_total numeric := 0;
  v_entry jsonb; v_entry_qty numeric; v_entry_expiry date; v_entry_wh_id uuid;
  v_existing_row warehouse_inventory%ROWTYPE;
  v_credit_summary jsonb := '[]'::jsonb;
  v_effective_expiry date;
  v_prior_active_merged int := 0;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'receive_dispatch_line', true);
  -- PRD-003 FU#4
  PERFORM set_config('app.provenance_reason', 'dispatch_receive', true);
  PERFORM set_config('app.source_event_id', p_dispatch_id::text, true);

  SELECT * INTO v_dispatch FROM refill_dispatching
  WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.item_added = true THEN RAISE EXCEPTION 'Dispatch % already received', p_dispatch_id; END IF;
  IF p_filled_quantity < 0 THEN RAISE EXCEPTION 'filled_quantity cannot be negative'; END IF;

  v_planned := v_dispatch.quantity;
  v_return_delta := GREATEST(v_planned - p_filled_quantity, 0);
  v_overfill := GREATEST(p_filled_quantity - v_planned, 0);
  v_path := 'b2_fallback';
  v_target_wh := COALESCE(v_dispatch.from_warehouse_id, v_default_wh);

  IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN
    SELECT expiration_date INTO v_effective_expiry
    FROM warehouse_inventory
    WHERE wh_inventory_id = v_dispatch.from_wh_inventory_id;
  ELSE
    v_effective_expiry := v_dispatch.expiry_date;
  END IF;

  PERFORM set_config('app.mutation_reason',
    format('B3 receive: dispatch %s — filled %s / planned %s by %s (breakdown=%s, effective_expiry=%s)',
           p_dispatch_id, p_filled_quantity, v_planned,
           COALESCE(p_received_by::text, 'system'),
           p_batch_breakdown IS NOT NULL,
           v_effective_expiry), true);

  IF v_dispatch.action IN ('Refill','Add New','Add') THEN
    IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN
      SELECT * INTO v_consumer_row FROM warehouse_inventory
      WHERE wh_inventory_id = v_dispatch.from_wh_inventory_id
      FOR UPDATE;
      IF FOUND AND COALESCE(v_consumer_row.consumer_stock, 0) > 0 THEN
        v_path := 'b3_consumer_pinned';
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
      ORDER BY (reserved_for_machine_id = v_dispatch.machine_id) DESC,
               consumer_stock DESC, reserved_at ASC
      LIMIT 1 FOR UPDATE;
      IF FOUND THEN v_path := 'b3_consumer_legacy'; END IF;
    END IF;

    IF v_consumer_row.wh_inventory_id IS NOT NULL THEN
      v_consumer_drawn := LEAST(p_filled_quantity, v_consumer_row.consumer_stock);
      UPDATE warehouse_inventory
      SET consumer_stock = GREATEST(COALESCE(consumer_stock, 0) - (v_consumer_drawn + v_return_delta), 0),
          warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_delta,
          reserved_for_machine_id = CASE
            WHEN COALESCE(consumer_stock, 0) - (v_consumer_drawn + v_return_delta) <= 0 THEN NULL
            ELSE reserved_for_machine_id END,
          reserved_at = CASE
            WHEN COALESCE(consumer_stock, 0) - (v_consumer_drawn + v_return_delta) <= 0 THEN NULL
            ELSE reserved_at END
      WHERE wh_inventory_id = v_consumer_row.wh_inventory_id;
    ELSE
      IF v_return_delta > 0 THEN
        SELECT * INTO v_wh_row FROM warehouse_inventory
        WHERE boonz_product_id = v_dispatch.boonz_product_id
          AND status = 'Active'
          AND (expiration_date = v_effective_expiry OR v_effective_expiry IS NULL)
        ORDER BY (expiration_date = v_effective_expiry) DESC NULLS LAST,
                 created_at DESC
        LIMIT 1 FOR UPDATE;

        IF FOUND THEN
          UPDATE warehouse_inventory
          SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_delta
          WHERE wh_inventory_id = v_wh_row.wh_inventory_id;
        ELSE
          SELECT * INTO v_wh_row FROM warehouse_inventory
          WHERE boonz_product_id = v_dispatch.boonz_product_id
            AND (expiration_date = v_effective_expiry OR v_effective_expiry IS NULL)
          ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory
            SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_delta
            WHERE wh_inventory_id = v_wh_row.wh_inventory_id;
          ELSE
            INSERT INTO warehouse_inventory
              (boonz_product_id, warehouse_stock, expiration_date, status,
               batch_id, snapshot_date, warehouse_id)
            VALUES
              (v_dispatch.boonz_product_id, v_return_delta, v_effective_expiry,
               'Active', format('RETURN-%s', v_dispatch.dispatch_date),
               CURRENT_DATE, v_target_wh);
          END IF;
        END IF;
      END IF;
    END IF;

    IF v_overfill > 0 THEN
      UPDATE warehouse_inventory
      SET warehouse_stock = COALESCE(warehouse_stock, 0) - v_overfill
      WHERE wh_inventory_id = (
        SELECT wh_inventory_id FROM warehouse_inventory
        WHERE boonz_product_id = v_dispatch.boonz_product_id
          AND status = 'Active'
          AND COALESCE(warehouse_stock, 0) >= v_overfill
          AND (expiration_date = v_effective_expiry OR v_effective_expiry IS NULL)
        ORDER BY expiration_date ASC NULLS LAST LIMIT 1 FOR UPDATE);
    END IF;

    IF p_filled_quantity > 0 THEN
      WITH archived AS (
        UPDATE pod_inventory
        SET status = 'Inactive',
            removal_reason = format('merged_into_dispatch_%s_%s',
                                     v_dispatch.dispatch_date, p_dispatch_id::text),
            snapshot_at = now()
        WHERE machine_id = v_dispatch.machine_id
          AND shelf_id = v_dispatch.shelf_id
          AND boonz_product_id = v_dispatch.boonz_product_id
          AND status = 'Active'
        RETURNING current_stock, expiration_date
      ),
      merge_stats AS (
        SELECT COALESCE(SUM(current_stock), 0)::numeric AS prior_qty,
               COUNT(*)::int AS prior_n,
               MIN(expiration_date) AS oldest_expiry
        FROM archived
      )
      INSERT INTO pod_inventory
        (machine_id, shelf_id, boonz_product_id, snapshot_date,
         current_stock, estimated_remaining, expiration_date,
         batch_id, status, snapshot_at, created_at)
      SELECT
        v_dispatch.machine_id, v_dispatch.shelf_id, v_dispatch.boonz_product_id,
        CURRENT_DATE,
        p_filled_quantity + ms.prior_qty,
        p_filled_quantity + ms.prior_qty,
        LEAST(v_effective_expiry, COALESCE(ms.oldest_expiry, v_effective_expiry)),
        CASE WHEN ms.prior_n > 0
             THEN format('MERGED-DISPATCH-%s', v_dispatch.dispatch_date)
             ELSE format('DISPATCH-%s', v_dispatch.dispatch_date)
        END,
        'Active', now(), now()
      FROM merge_stats ms
      RETURNING pod_inventory_id INTO v_pod_id;

      SELECT prior_n INTO v_prior_active_merged
      FROM (
        SELECT COUNT(*)::int AS prior_n
        FROM pod_inventory
        WHERE machine_id = v_dispatch.machine_id
          AND shelf_id = v_dispatch.shelf_id
          AND boonz_product_id = v_dispatch.boonz_product_id
          AND status = 'Inactive'
          AND removal_reason = format('merged_into_dispatch_%s_%s',
                                       v_dispatch.dispatch_date, p_dispatch_id::text)
      ) AS s;
    END IF;

  ELSIF v_dispatch.action = 'Remove' THEN
    v_path := 'remove_single_expiry';

    IF p_filled_quantity > 0 THEN
      IF p_batch_breakdown IS NOT NULL AND jsonb_typeof(p_batch_breakdown) = 'array' THEN
        v_path := 'remove_breakdown';
        SELECT COALESCE(SUM((e->>'qty')::numeric), 0) INTO v_breakdown_total
        FROM jsonb_array_elements(p_batch_breakdown) e;
        IF v_breakdown_total <> p_filled_quantity THEN
          RAISE EXCEPTION 'Breakdown total (%) must equal filled_quantity (%)',
            v_breakdown_total, p_filled_quantity;
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
              'qty', v_entry_qty);
            CONTINUE;
          END IF;

          IF v_entry_expiry IS NULL THEN
            RAISE EXCEPTION 'Breakdown entry must include expiry or wh_inventory_id (got %)', v_entry;
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
               'Active', format('REMOVE-RECEIVE-%s', v_dispatch.dispatch_date),
               CURRENT_DATE, v_target_wh)
            RETURNING wh_inventory_id INTO v_entry_wh_id;
            v_credit_summary := v_credit_summary || jsonb_build_object(
              'wh_inventory_id', v_entry_wh_id,
              'expiry', v_entry_expiry, 'qty', v_entry_qty, 'mode', 'inserted');
          END IF;
        END LOOP;

      ELSIF v_effective_expiry IS NOT NULL THEN
        SELECT * INTO v_existing_row FROM warehouse_inventory
        WHERE boonz_product_id = v_dispatch.boonz_product_id
          AND warehouse_id = v_target_wh
          AND status = 'Active'
          AND expiration_date = v_effective_expiry
        ORDER BY created_at ASC LIMIT 1 FOR UPDATE;
        IF FOUND THEN
          UPDATE warehouse_inventory
          SET warehouse_stock = COALESCE(warehouse_stock, 0) + p_filled_quantity
          WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
        ELSE
          INSERT INTO warehouse_inventory
            (boonz_product_id, warehouse_stock, expiration_date, status,
             batch_id, snapshot_date, warehouse_id)
          VALUES
            (v_dispatch.boonz_product_id, p_filled_quantity, v_effective_expiry,
             'Active', format('REMOVE-RECEIVE-%s', v_dispatch.dispatch_date),
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
          SET warehouse_stock = COALESCE(warehouse_stock, 0) + p_filled_quantity
          WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
        ELSE
          SELECT * INTO v_existing_row FROM warehouse_inventory
          WHERE boonz_product_id = v_dispatch.boonz_product_id
            AND warehouse_id = v_target_wh
            AND status = 'Active'
          ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory
            SET warehouse_stock = COALESCE(warehouse_stock, 0) + p_filled_quantity
            WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
          ELSE
            RAISE EXCEPTION
              'Cannot receive REMOVE dispatch %: effective_expiry is NULL and no Active warehouse_inventory row exists for boonz_product=%, warehouse=%. Pass p_batch_breakdown with explicit expiry.',
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

  END IF;

  UPDATE refill_dispatching
  SET filled_quantity = p_filled_quantity,
      item_added = true,
      dispatched = true,
      packed = true,
      picked_up = true
  WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object(
    'dispatch_id', p_dispatch_id,
    'action', v_dispatch.action,
    'filled_quantity', p_filled_quantity,
    'planned_quantity', v_planned,
    'return_delta', v_return_delta,
    'overfill', v_overfill,
    'pod_inventory_id', v_pod_id,
    'pod_archived', v_pod_archived,
    'prior_active_merged', v_prior_active_merged,
    'consumer_drained', v_consumer_drawn,
    'path', v_path,
    'effective_expiry', v_effective_expiry,
    'received_by', p_received_by,
    'credit_summary', v_credit_summary,
    'status', 'received'
  );
END;
$function$;

-- ── log_manual_refill ───────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.log_manual_refill(
  p_machine_name text,
  p_source_warehouse_id uuid,
  p_refill_date date,
  p_lines jsonb,
  p_reason text DEFAULT 'manual_refill_backlog'::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_role text;
  v_machine_id uuid;
  v_wh_name text;
  v_line jsonb;
  v_bpid uuid;
  v_qty numeric;
  v_exp date;
  v_shelf_code text;
  v_shelf_id uuid;
  v_product_name text;
  v_remaining numeric;
  v_src_row warehouse_inventory%ROWTYPE;
  v_pick numeric;
  v_pod_id uuid;
  v_lines_processed int := 0;
  v_total_units numeric := 0;
  v_wh_decremented numeric := 0;
  v_results jsonb := '[]'::jsonb;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'log_manual_refill', true);
  -- PRD-003 FU#4: manual refill is a manual_adjust on WH stock.
  PERFORM set_config('app.provenance_reason', 'manual_adjust', true);

  SELECT role INTO v_role FROM user_profiles WHERE id = auth.uid();
  IF v_role IS NULL OR v_role NOT IN ('warehouse', 'operator_admin', 'superadmin', 'manager') THEN
    RAISE EXCEPTION 'Unauthorized: role "%" cannot log manual refills', COALESCE(v_role, 'none');
  END IF;

  SELECT machine_id INTO v_machine_id FROM machines WHERE official_name = p_machine_name;
  IF v_machine_id IS NULL THEN
    RAISE EXCEPTION 'Machine "%" not found', p_machine_name;
  END IF;

  SELECT name INTO v_wh_name FROM warehouses WHERE warehouse_id = p_source_warehouse_id;
  IF v_wh_name IS NULL THEN
    RAISE EXCEPTION 'Warehouse % not found', p_source_warehouse_id;
  END IF;

  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'p_lines must be a non-empty JSON array';
  END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_bpid       := (v_line->>'boonz_product_id')::uuid;
    v_qty        := (v_line->>'qty')::numeric;
    v_exp        := (v_line->>'expiration_date')::date;
    v_shelf_code := v_line->>'shelf_code';

    IF v_bpid IS NULL THEN RAISE EXCEPTION 'boonz_product_id required in every line'; END IF;
    IF v_qty IS NULL OR v_qty <= 0 THEN RAISE EXCEPTION 'qty must be > 0'; END IF;
    IF v_shelf_code IS NULL THEN RAISE EXCEPTION 'shelf_code required in every line'; END IF;

    SELECT boonz_product_name INTO v_product_name
    FROM boonz_products WHERE product_id = v_bpid;
    IF v_product_name IS NULL THEN
      RAISE EXCEPTION 'boonz_product_id % not found', v_bpid;
    END IF;

    SELECT shelf_id INTO v_shelf_id
    FROM shelf_configurations
    WHERE machine_id = v_machine_id AND shelf_code = v_shelf_code;

    v_remaining := v_qty;

    FOR v_src_row IN
      SELECT * FROM warehouse_inventory
      WHERE boonz_product_id = v_bpid
        AND warehouse_id = p_source_warehouse_id
        AND status = 'Active'
        AND COALESCE(warehouse_stock, 0) > 0
      ORDER BY expiration_date ASC NULLS LAST, created_at ASC
      FOR UPDATE
    LOOP
      EXIT WHEN v_remaining <= 0;
      v_pick := LEAST(v_remaining, v_src_row.warehouse_stock);

      -- PRD-003 FU#4: pin source_event_id per source row so the audit trail
      -- ties back to the specific batch decremented.
      PERFORM set_config('app.source_event_id', v_src_row.wh_inventory_id::text, true);

      UPDATE warehouse_inventory
      SET warehouse_stock = COALESCE(warehouse_stock, 0) - v_pick
      WHERE wh_inventory_id = v_src_row.wh_inventory_id;

      INSERT INTO inventory_audit_log (
        wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason
      ) VALUES (
        v_src_row.wh_inventory_id, v_bpid, auth.uid(),
        v_src_row.warehouse_stock, v_src_row.warehouse_stock - v_pick,
        format('Manual refill OUT to %s/%s: %s units of %s — %s',
               p_machine_name, v_shelf_code, v_pick, v_product_name, p_reason)
      );

      v_remaining := v_remaining - v_pick;
      v_wh_decremented := v_wh_decremented + v_pick;
    END LOOP;

    INSERT INTO pod_inventory (
      machine_id, shelf_id, boonz_product_id,
      snapshot_date, current_stock, estimated_remaining,
      expiration_date, batch_id, status, snapshot_at
    ) VALUES (
      v_machine_id, v_shelf_id, v_bpid,
      p_refill_date, v_qty, v_qty,
      v_exp, format('MANUAL-REFILL-%s', p_refill_date),
      'Active', now()
    )
    RETURNING pod_inventory_id INTO v_pod_id;

    INSERT INTO pod_inventory_audit_log (
      pod_inventory_id, machine_id, shelf_id, boonz_product_id,
      expiration_date, source, operation,
      old_stock, new_stock, delta,
      old_status, new_status, actor,
      reference_id, notes
    ) VALUES (
      v_pod_id, v_machine_id, v_shelf_id, v_bpid,
      v_exp, 'refill', 'insert',
      0, v_qty, v_qty,
      NULL, 'Active', auth.uid(),
      format('manual-refill-%s-%s', p_machine_name, p_refill_date),
      format('%s: %s x %s on %s — %s', v_product_name, v_qty, v_shelf_code, p_refill_date, p_reason)
    );

    v_lines_processed := v_lines_processed + 1;
    v_total_units := v_total_units + v_qty;

    v_results := v_results || jsonb_build_object(
      'shelf_code', v_shelf_code,
      'product', v_product_name,
      'qty', v_qty,
      'pod_inventory_id', v_pod_id,
      'wh_decremented', v_qty - GREATEST(v_remaining, 0),
      'wh_shortfall', GREATEST(v_remaining, 0)
    );
  END LOOP;

  RETURN jsonb_build_object(
    'status', 'ok',
    'machine', p_machine_name,
    'source_warehouse', v_wh_name,
    'refill_date', p_refill_date,
    'lines_processed', v_lines_processed,
    'total_units_to_pod', v_total_units,
    'total_wh_decremented', v_wh_decremented,
    'shortfall_warning', CASE WHEN v_wh_decremented < v_total_units
      THEN format('WH had %s less than the %s refilled — physical count may be needed', v_total_units - v_wh_decremented, v_total_units)
      ELSE NULL END,
    'details', v_results
  );
END;
$function$;

-- ── confirm_warehouse_status_proposal ──────────────────────────────────────

CREATE OR REPLACE FUNCTION public.confirm_warehouse_status_proposal(
  p_proposal_id uuid,
  p_note text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_caller_role    text;
  v_caller_id      uuid;
  v_proposal       public.warehouse_inventory_status_proposal%ROWTYPE;
  v_current_status text;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'confirm_warehouse_status_proposal', true);
  -- PRD-003 FU#4
  PERFORM set_config('app.provenance_reason', 'status_flip', true);
  PERFORM set_config('app.source_event_id', p_proposal_id::text, true);

  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'No authenticated caller');
  END IF;

  SELECT role INTO v_caller_role
  FROM public.user_profiles
  WHERE id = v_caller_id;

  IF v_caller_role NOT IN ('warehouse', 'operator_admin', 'superadmin', 'manager') THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'error',  'Insufficient role — confirm requires warehouse / operator_admin / superadmin / manager'
    );
  END IF;

  IF p_proposal_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'p_proposal_id is required');
  END IF;

  SELECT * INTO v_proposal
  FROM public.warehouse_inventory_status_proposal
  WHERE proposal_id = p_proposal_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'Proposal not found', 'proposal_id', p_proposal_id);
  END IF;

  IF v_proposal.status <> 'pending' THEN
    RETURN jsonb_build_object(
      'status',         'error',
      'error',          'Proposal is not pending',
      'current_status', v_proposal.status,
      'decided_at',     v_proposal.decided_at
    );
  END IF;

  SELECT status INTO v_current_status
  FROM public.warehouse_inventory
  WHERE wh_inventory_id = v_proposal.wh_inventory_id
  FOR UPDATE;

  IF v_current_status IS NULL THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'error',  'warehouse_inventory row no longer exists',
      'wh_inventory_id', v_proposal.wh_inventory_id
    );
  END IF;

  IF v_current_status <> v_proposal.current_status THEN
    UPDATE public.warehouse_inventory_status_proposal
    SET status        = 'superseded',
        decided_by    = v_caller_id,
        decided_at    = now(),
        decision_note = COALESCE(p_note, '') ||
                        ' [auto-superseded: current status drifted from ' ||
                        v_proposal.current_status || ' to ' || v_current_status || ']'
    WHERE proposal_id = p_proposal_id;

    RETURN jsonb_build_object(
      'status',           'superseded',
      'reason',           'current_status_drifted',
      'expected',         v_proposal.current_status,
      'actual',           v_current_status,
      'proposal_id',      p_proposal_id
    );
  END IF;

  UPDATE public.warehouse_inventory
  SET status = v_proposal.proposed_status
  WHERE wh_inventory_id = v_proposal.wh_inventory_id;

  UPDATE public.warehouse_inventory_status_proposal
  SET status        = 'confirmed',
      decided_by    = v_caller_id,
      decided_at    = now(),
      decision_note = p_note
  WHERE proposal_id = p_proposal_id;

  RETURN jsonb_build_object(
    'status',           'ok',
    'proposal_id',      p_proposal_id,
    'wh_inventory_id',  v_proposal.wh_inventory_id,
    'old_status',       v_proposal.current_status,
    'new_status',       v_proposal.proposed_status,
    'reason',           v_proposal.reason,
    'proposer_name',    v_proposal.proposer_name,
    'confirmed_by',     v_caller_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'status', 'error',
    'error',  SQLERRM,
    'detail', SQLSTATE
  );
END;
$function$;

COMMIT;

-- ============================================================================
-- POST-APPLY: 8 of 11 canonical writers now annotate provenance.
-- Still deferred (snapshot-class writers):
--   upsert_refill_stock_snapshot, add_sanity_increment, auto_sanity_check.
-- Their provenance is 'snapshot' (lax — no single source event).
-- ============================================================================
