-- ROLLBACK: restore live pre-Batch-2 body of drain_phantom_consumer_stock
-- captured 2026-07-18 from eizcexopcuoycuosittm
-- md5(pg_get_functiondef) = fc359865eae7f6601181d9726d1822b1
CREATE OR REPLACE FUNCTION public.drain_phantom_consumer_stock(p_wh_inventory_id uuid, p_units numeric, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_row public.warehouse_inventory%ROWTYPE;
  v_new_consumer numeric;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'drain_phantom_consumer_stock: no caller identity'; END IF;
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
  IF v_role NOT IN ('operator_admin','superadmin') THEN
    RAISE EXCEPTION 'drain_phantom_consumer_stock: role % cannot drain', v_role;
  END IF;
  IF p_units IS NULL OR p_units <= 0 THEN
    RAISE EXCEPTION 'drain_phantom_consumer_stock: p_units must be positive (got %)', p_units;
  END IF;
  IF length(trim(coalesce(p_reason,''))) < 10 THEN
    RAISE EXCEPTION 'drain_phantom_consumer_stock: p_reason min 10 chars';
  END IF;

  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','drain_phantom_consumer_stock',true);
  PERFORM set_config('app.mutation_reason',
    format('drain phantom %s units wh=%s by=%s reason=%s', p_units, p_wh_inventory_id, v_uid, p_reason), true);

  SELECT * INTO v_row FROM public.warehouse_inventory
   WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
  IF v_row.wh_inventory_id IS NULL THEN
    RAISE EXCEPTION 'drain_phantom_consumer_stock: wh % not found', p_wh_inventory_id;
  END IF;
  IF coalesce(v_row.consumer_stock, 0) < p_units THEN
    RAISE EXCEPTION 'drain_phantom_consumer_stock: consumer_stock=% < p_units=% on wh %',
      v_row.consumer_stock, p_units, p_wh_inventory_id;
  END IF;

  v_new_consumer := coalesce(v_row.consumer_stock,0) - p_units;

  UPDATE public.warehouse_inventory
     SET consumer_stock = v_new_consumer
   WHERE wh_inventory_id = p_wh_inventory_id;

  RETURN jsonb_build_object(
    'result','success',
    'wh_inventory_id', p_wh_inventory_id,
    'previous_consumer_stock', v_row.consumer_stock,
    'new_consumer_stock', v_new_consumer,
    'units_drained', p_units,
    'drained_by', v_uid,
    'drained_at', now()
  );
END $function$
