-- Phase G P3 A.3: drain_consumer_stock_phantom canonical writer.
-- Cody-approved against Articles 1, 4, 6, 8, 12 with the provenance_reason
-- fix (manual_adjust, not consumer_phantom_drain — discriminator stays in
-- inventory_audit_log.reason).
-- Applied to prod 2026-05-25 via MCP. This file is the repo mirror.

CREATE OR REPLACE FUNCTION public.drain_consumer_stock_phantom(
  p_wh_inventory_id uuid,
  p_reason text,
  p_drained_by uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_user_id   uuid;
  v_caller    text;
  v_row       public.warehouse_inventory%ROWTYPE;
  v_before    numeric;
BEGIN
  v_user_id := COALESCE(p_drained_by, auth.uid());
  SELECT role INTO v_caller FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller IS NULL OR v_caller NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'drain_consumer_stock_phantom: forbidden for role %', COALESCE(v_caller,'unknown');
  END IF;

  IF p_wh_inventory_id IS NULL THEN
    RAISE EXCEPTION 'p_wh_inventory_id required';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason is required (>= 10 chars) - phantom drain demands per-row CS audit text';
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'drain_consumer_stock_phantom', true);
  -- Cody: 'consumer_phantom_drain' not in wh_provenance_reason_enum CHECK.
  -- Use the closest legal value; discriminator carried in audit reason text.
  PERFORM set_config('app.provenance_reason', 'manual_adjust', true);
  PERFORM set_config('app.mutation_reason', p_reason, true);

  SELECT * INTO v_row
    FROM public.warehouse_inventory
   WHERE wh_inventory_id = p_wh_inventory_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'wh_inventory_id % not found', p_wh_inventory_id;
  END IF;

  v_before := COALESCE(v_row.consumer_stock, 0);

  IF v_before = 0 THEN
    RAISE EXCEPTION 'drain_consumer_stock_phantom: wh_inventory_id % already has consumer_stock=0, nothing to drain', p_wh_inventory_id;
  END IF;

  UPDATE public.warehouse_inventory
     SET consumer_stock = 0
   WHERE wh_inventory_id = p_wh_inventory_id;

  INSERT INTO public.inventory_audit_log (
    wh_inventory_id, boonz_product_id, adjusted_by,
    old_qty, new_qty, delta, reason, provenance_reason
  ) VALUES (
    p_wh_inventory_id, v_row.boonz_product_id, v_user_id,
    v_before, 0, -v_before,
    'consumer_phantom_drain: ' || p_reason,
    'manual_adjust'
  );

  RETURN jsonb_build_object(
    'wh_inventory_id', p_wh_inventory_id,
    'boonz_product_id', v_row.boonz_product_id,
    'old_consumer_stock', v_before,
    'new_consumer_stock', 0,
    'drained_units', v_before,
    'reason', p_reason,
    'drained_at', now(),
    'drained_by', v_user_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.drain_consumer_stock_phantom(uuid, text, uuid) TO authenticated;
