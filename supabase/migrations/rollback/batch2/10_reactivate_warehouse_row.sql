-- ROLLBACK: restore live pre-Batch-2 body of reactivate_warehouse_row
-- captured 2026-07-18 from eizcexopcuoycuosittm
-- md5(pg_get_functiondef) = 1fe04dbac7146c8963f0f318735babbb
CREATE OR REPLACE FUNCTION public.reactivate_warehouse_row(p_wh_inventory_id uuid, p_new_warehouse_stock numeric, p_reason text, p_source_doc text DEFAULT NULL::text, p_reactivated_by uuid DEFAULT NULL::uuid, p_new_expiration_date date DEFAULT NULL::date, p_new_wh_location text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_row warehouse_inventory%ROWTYPE;
BEGIN
  IF p_new_warehouse_stock IS NULL OR p_new_warehouse_stock <= 0 THEN
    RAISE EXCEPTION 'p_new_warehouse_stock must be > 0 (use apply_inventory_correction for 0-stock writes)';
  END IF;
  IF COALESCE(p_reason, '') = '' THEN
    RAISE EXCEPTION 'p_reason is required (e.g. "WEIMI miscount confirmed by manual count", "supplier delivered replacement batch", "auto-inactivation was premature")';
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'reactivate_warehouse_row', true);
  PERFORM set_config('app.mutation_reason',
    format('reactivate_warehouse_row by %s: %s%s',
      COALESCE(p_reactivated_by::text, 'system'),
      p_reason,
      CASE WHEN p_source_doc IS NOT NULL THEN ' [src: ' || p_source_doc || ']' ELSE '' END),
    true);

  SELECT * INTO v_row FROM warehouse_inventory 
  WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'wh_inventory_id % not found', p_wh_inventory_id;
  END IF;

  -- Refuse to reactivate a row whose product is on an active decommission intent
  IF EXISTS (
    SELECT 1 FROM strategic_intents si
    WHERE si.intent_type = 'decommission'
      AND si.status IN ('queued','in_progress')
      AND si.scope_boonz_product_id = v_row.boonz_product_id
      AND (si.scope_machine_ids IS NULL OR true)
  ) THEN
    RAISE EXCEPTION
      'Cannot reactivate %: product is on an active decommission intent. Close the intent first or use apply_inventory_correction with explicit override.',
      v_row.boonz_product_id;
  END IF;

  UPDATE warehouse_inventory
  SET warehouse_stock = p_new_warehouse_stock,
      status = 'Active',
      expiration_date = COALESCE(p_new_expiration_date, expiration_date),
      wh_location = COALESCE(p_new_wh_location, wh_location)
  WHERE wh_inventory_id = p_wh_inventory_id;

  RETURN jsonb_build_object(
    'status', 'reactivated',
    'wh_inventory_id', p_wh_inventory_id,
    'old_stock', v_row.warehouse_stock,
    'new_stock', p_new_warehouse_stock,
    'reason', p_reason,
    'source_doc', p_source_doc
  );
END;
$function$
