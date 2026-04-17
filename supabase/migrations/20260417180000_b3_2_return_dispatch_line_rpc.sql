-- B3.2: return_dispatch_line RPC.
-- Atomic return flow: drains consumer_stock, restores to warehouse_stock on
-- the same batch (not a new RETURN row), flips returned=true, idempotent.
-- Replaces the legacy inline WH INSERT path in the dispatching page.

CREATE OR REPLACE FUNCTION public.return_dispatch_line(
  p_dispatch_id uuid,
  p_return_reason text DEFAULT NULL,
  p_returned_by uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_dispatch refill_dispatching%ROWTYPE;
  v_consumer_row warehouse_inventory%ROWTYPE;
  v_return_qty numeric;
BEGIN
  SELECT * INTO v_dispatch FROM refill_dispatching
  WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id;
  END IF;

  -- Idempotency: already returned = no-op, return success
  IF v_dispatch.returned = true THEN
    RETURN jsonb_build_object(
      'dispatch_id', p_dispatch_id,
      'status', 'already_returned',
      'message', 'This dispatch was already returned — no changes made'
    );
  END IF;

  -- Cannot return something already received into a pod
  IF v_dispatch.item_added = true THEN
    RAISE EXCEPTION 'Dispatch % already received (item_added=true) — cannot return', p_dispatch_id;
  END IF;

  v_return_qty := COALESCE(v_dispatch.filled_quantity, v_dispatch.quantity);

  PERFORM set_config('app.mutation_reason',
    format('B3.2 return: dispatch %s — returning %s units to WH (reason: %s)',
           p_dispatch_id, v_return_qty, COALESCE(p_return_reason, 'none')),
    true);

  -- Try B3 path first: find consumer_stock reserved for this machine+expiry
  IF v_return_qty > 0 THEN
    SELECT * INTO v_consumer_row FROM warehouse_inventory
    WHERE boonz_product_id = v_dispatch.boonz_product_id
      AND COALESCE(consumer_stock, 0) > 0
      AND (reserved_for_machine_id = v_dispatch.machine_id OR reserved_for_machine_id IS NULL)
      AND (expiration_date = v_dispatch.expiry_date OR v_dispatch.expiry_date IS NULL)
    ORDER BY
      (reserved_for_machine_id = v_dispatch.machine_id) DESC,
      consumer_stock DESC
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      -- B3 path: move consumer_stock back to warehouse_stock on the SAME row
      UPDATE warehouse_inventory
      SET consumer_stock  = GREATEST(COALESCE(consumer_stock, 0) - v_return_qty, 0),
          warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_qty,
          reserved_for_machine_id = CASE
            WHEN COALESCE(consumer_stock, 0) - v_return_qty <= 0
            THEN NULL ELSE reserved_for_machine_id END,
          reserved_at = CASE
            WHEN COALESCE(consumer_stock, 0) - v_return_qty <= 0
            THEN NULL ELSE reserved_at END
      WHERE wh_inventory_id = v_consumer_row.wh_inventory_id;
    ELSE
      -- B2 fallback: no consumer_stock found (legacy in-flight or already drained)
      -- Try to find the original batch by product+expiry and add stock back
      DECLARE v_wh_row warehouse_inventory%ROWTYPE;
      BEGIN
        -- First: try Active batch with matching expiry
        SELECT * INTO v_wh_row FROM warehouse_inventory
        WHERE boonz_product_id = v_dispatch.boonz_product_id
          AND (expiration_date = v_dispatch.expiry_date OR v_dispatch.expiry_date IS NULL)
          AND status = 'Active'
        ORDER BY created_at DESC LIMIT 1 FOR UPDATE;

        IF FOUND THEN
          UPDATE warehouse_inventory
          SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_qty
          WHERE wh_inventory_id = v_wh_row.wh_inventory_id;
        ELSE
          -- Try Inactive with matching expiry (auto_reactivate trigger will flip to Active)
          SELECT * INTO v_wh_row FROM warehouse_inventory
          WHERE boonz_product_id = v_dispatch.boonz_product_id
            AND (expiration_date = v_dispatch.expiry_date OR v_dispatch.expiry_date IS NULL)
          ORDER BY created_at DESC LIMIT 1 FOR UPDATE;

          IF FOUND THEN
            UPDATE warehouse_inventory
            SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_qty
            WHERE wh_inventory_id = v_wh_row.wh_inventory_id;
          ELSE
            -- Absolute fallback: create a RETURN row (last resort)
            INSERT INTO warehouse_inventory
              (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date)
            VALUES
              (v_dispatch.boonz_product_id, v_return_qty, v_dispatch.expiry_date,
               'Active', format('RETURN-%s', v_dispatch.dispatch_date), CURRENT_DATE);
          END IF;
        END IF;
      END;
    END IF;
  END IF;

  -- Flip dispatch flags
  UPDATE refill_dispatching
  SET returned = true,
      dispatched = true,
      filled_quantity = 0,
      return_reason = p_return_reason
  WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object(
    'dispatch_id', p_dispatch_id,
    'return_qty', v_return_qty,
    'return_reason', p_return_reason,
    'consumer_drained', v_consumer_row.wh_inventory_id IS NOT NULL,
    'status', 'returned'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.return_dispatch_line TO authenticated;

-- Bulk wrapper for "return all" scenarios
CREATE OR REPLACE FUNCTION public.return_all_dispatches_for_machine(
  p_machine_id uuid,
  p_dispatch_date date,
  p_return_reason text DEFAULT 'bulk_return'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_row refill_dispatching%ROWTYPE;
  v_results jsonb := '[]'::jsonb;
  v_one jsonb;
BEGIN
  FOR v_row IN
    SELECT * FROM refill_dispatching
    WHERE machine_id = p_machine_id
      AND dispatch_date = p_dispatch_date
      AND packed = true
      AND item_added = false
      AND returned = false
      AND include = true
    ORDER BY created_at
  LOOP
    v_one := public.return_dispatch_line(v_row.dispatch_id, p_return_reason);
    v_results := v_results || v_one;
  END LOOP;

  RETURN jsonb_build_object(
    'returned_count', jsonb_array_length(v_results),
    'results', v_results
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.return_all_dispatches_for_machine TO authenticated;
