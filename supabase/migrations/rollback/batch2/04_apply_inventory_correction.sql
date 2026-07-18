-- ROLLBACK: restore live pre-Batch-2 body of apply_inventory_correction
-- captured 2026-07-18 from eizcexopcuoycuosittm
-- md5(pg_get_functiondef) = 380dc01f611b9fbeb74c203ac0ec07e2
CREATE OR REPLACE FUNCTION public.apply_inventory_correction(p_wh_inventory_id uuid DEFAULT NULL::uuid, p_boonz_product_id uuid DEFAULT NULL::uuid, p_warehouse_id uuid DEFAULT NULL::uuid, p_expiration_date date DEFAULT NULL::date, p_new_warehouse_stock numeric DEFAULT NULL::numeric, p_reason text DEFAULT NULL::text, p_corrected_by uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_row warehouse_inventory%ROWTYPE;
  v_inserted boolean := false;
BEGIN
  IF p_new_warehouse_stock IS NULL OR p_new_warehouse_stock < 0 THEN
    RAISE EXCEPTION 'p_new_warehouse_stock must be >= 0';
  END IF;
  IF COALESCE(p_reason, '') = '' THEN
    RAISE EXCEPTION 'p_reason is required for inventory corrections';
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'apply_inventory_correction', true);
  PERFORM set_config('app.mutation_reason',
    format('inventory correction by %s: %s',
           COALESCE(p_corrected_by::text, 'cs'), p_reason), true);

  -- Path A: row id provided → direct update
  IF p_wh_inventory_id IS NOT NULL THEN
    SELECT * INTO v_row FROM warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'wh_inventory_id % not found', p_wh_inventory_id; END IF;
    UPDATE warehouse_inventory
    SET warehouse_stock = p_new_warehouse_stock,
        -- If row was Inactive AND now has stock, re-activate
        status = CASE 
          WHEN p_new_warehouse_stock > 0 AND status IN ('Inactive') THEN 'Active'
          WHEN p_new_warehouse_stock = 0 AND status = 'Active' THEN status -- leave Active, manager will inactivate separately
          ELSE status END,
        -- If we're setting an expiry on a row that didn't have one, allow it
        expiration_date = COALESCE(expiration_date, p_expiration_date)
    WHERE wh_inventory_id = p_wh_inventory_id;

  -- Path B: identify by (product, warehouse, expiry)
  ELSIF p_boonz_product_id IS NOT NULL AND p_warehouse_id IS NOT NULL THEN
    IF p_expiration_date IS NULL THEN
      RAISE EXCEPTION 'p_expiration_date required when correcting by (product, warehouse). Never create NULL-expiry rows.';
    END IF;
    SELECT * INTO v_row FROM warehouse_inventory
    WHERE boonz_product_id = p_boonz_product_id
      AND warehouse_id = p_warehouse_id
      AND expiration_date = p_expiration_date
    ORDER BY (status = 'Active') DESC, created_at DESC
    LIMIT 1 FOR UPDATE;

    IF FOUND THEN
      UPDATE warehouse_inventory
      SET warehouse_stock = p_new_warehouse_stock,
          status = CASE 
            WHEN p_new_warehouse_stock > 0 AND status IN ('Inactive') THEN 'Active'
            ELSE status END
      WHERE wh_inventory_id = v_row.wh_inventory_id;
    ELSE
      INSERT INTO warehouse_inventory
        (boonz_product_id, warehouse_id, warehouse_stock, expiration_date, status,
         batch_id, snapshot_date)
      VALUES
        (p_boonz_product_id, p_warehouse_id, p_new_warehouse_stock, p_expiration_date, 'Active',
         format('CORRECTION-%s', CURRENT_DATE), CURRENT_DATE)
      RETURNING wh_inventory_id INTO v_row.wh_inventory_id;
      v_inserted := true;
    END IF;
  ELSE
    RAISE EXCEPTION 'Provide either p_wh_inventory_id OR (p_boonz_product_id + p_warehouse_id + p_expiration_date)';
  END IF;

  RETURN jsonb_build_object(
    'status', 'corrected',
    'wh_inventory_id', v_row.wh_inventory_id,
    'inserted', v_inserted,
    'new_warehouse_stock', p_new_warehouse_stock,
    'reason', p_reason
  );
END;
$function$
