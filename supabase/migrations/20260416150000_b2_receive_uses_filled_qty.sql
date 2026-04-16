-- ========================================================================
-- Phase B2: Receive flow uses filled_quantity; returns delta to WH
-- ========================================================================

CREATE OR REPLACE FUNCTION public.receive_dispatch_line(
  p_dispatch_id uuid,
  p_filled_quantity numeric,
  p_received_by uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_dispatch refill_dispatching%ROWTYPE;
  v_wh_row warehouse_inventory%ROWTYPE;
  v_return_delta numeric;
  v_pod_id uuid;
BEGIN
  SELECT * INTO v_dispatch FROM refill_dispatching WHERE dispatch_id = p_dispatch_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id;
  END IF;

  IF v_dispatch.item_added = true THEN
    RAISE EXCEPTION 'Dispatch % already received (item_added=true)', p_dispatch_id;
  END IF;

  IF p_filled_quantity < 0 THEN
    RAISE EXCEPTION 'filled_quantity cannot be negative';
  END IF;

  v_return_delta := GREATEST(v_dispatch.quantity - p_filled_quantity, 0);

  -- Return unused units to WH if underfill
  IF v_return_delta > 0 AND v_dispatch.action IN ('Refill','Add New','Add') THEN
    PERFORM set_config('app.mutation_reason',
      format('B2 receive: return %s units (dispatch %s, planned %s, filled %s)',
             v_return_delta, p_dispatch_id, v_dispatch.quantity, p_filled_quantity),
      true);

    -- Prefer exact-expiry batch; else newest active
    SELECT * INTO v_wh_row FROM warehouse_inventory
    WHERE boonz_product_id = v_dispatch.boonz_product_id
      AND status = 'Active'
      AND (expiration_date = v_dispatch.expiry_date OR v_dispatch.expiry_date IS NULL)
    ORDER BY
      (expiration_date = v_dispatch.expiry_date) DESC NULLS LAST,
      created_at DESC
    LIMIT 1;

    IF FOUND THEN
      UPDATE warehouse_inventory
      SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_delta
      WHERE wh_inventory_id = v_wh_row.wh_inventory_id;
    ELSE
      -- No matching active batch — create a new WH row for returned stock
      INSERT INTO warehouse_inventory
        (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date)
      VALUES
        (v_dispatch.boonz_product_id, v_return_delta, v_dispatch.expiry_date,
         'Active', format('RETURN-%s', v_dispatch.dispatch_date), CURRENT_DATE);
    END IF;
  END IF;

  -- Write pod_inventory row for Refill/Add New/Add; Remove has its own flow
  IF v_dispatch.action IN ('Refill','Add New','Add') AND p_filled_quantity > 0 THEN
    INSERT INTO pod_inventory
      (machine_id, shelf_id, boonz_product_id, snapshot_date,
       current_stock, estimated_remaining, expiration_date, batch_id,
       status, snapshot_at, created_at)
    VALUES
      (v_dispatch.machine_id, v_dispatch.shelf_id, v_dispatch.boonz_product_id, CURRENT_DATE,
       p_filled_quantity, p_filled_quantity, v_dispatch.expiry_date,
       format('DISPATCH-%s', v_dispatch.dispatch_date),
       'Active', now(), now())
    RETURNING pod_inventory_id INTO v_pod_id;
  END IF;

  -- Flip dispatch row to received
  UPDATE refill_dispatching
  SET filled_quantity = p_filled_quantity,
      item_added = true,
      dispatched = true,
      packed = COALESCE(packed, true),
      picked_up = COALESCE(picked_up, true)
  WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object(
    'dispatch_id', p_dispatch_id,
    'filled_quantity', p_filled_quantity,
    'planned_quantity', v_dispatch.quantity,
    'return_delta', v_return_delta,
    'pod_inventory_id', v_pod_id,
    'status', 'received'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.receive_dispatch_line TO authenticated;

-- Bulk wrapper for admin "Confirm all received"
CREATE OR REPLACE FUNCTION public.receive_all_dispatches_for_machine(
  p_machine_id uuid,
  p_dispatch_date date,
  p_use_filled_as_received boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row refill_dispatching%ROWTYPE;
  v_results jsonb := '[]'::jsonb;
  v_one jsonb;
  v_qty numeric;
BEGIN
  FOR v_row IN
    SELECT * FROM refill_dispatching
    WHERE machine_id = p_machine_id
      AND dispatch_date = p_dispatch_date
      AND dispatched = true
      AND item_added = false
      AND include = true
    ORDER BY created_at
  LOOP
    v_qty := CASE
      WHEN p_use_filled_as_received AND v_row.filled_quantity IS NOT NULL
      THEN v_row.filled_quantity
      ELSE COALESCE(v_row.filled_quantity, v_row.quantity)
    END;

    v_one := public.receive_dispatch_line(v_row.dispatch_id, v_qty);
    v_results := v_results || v_one;
  END LOOP;

  RETURN jsonb_build_object(
    'received_count', jsonb_array_length(v_results),
    'results', v_results
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.receive_all_dispatches_for_machine TO authenticated;
