-- ROLLBACK: restore live pre-Batch-2 body of drain_phantom_consumer_stock_batch_run
-- captured 2026-07-18 from eizcexopcuoycuosittm
-- md5(pg_get_functiondef) = 0084f0468f4e887c57fa19d67f4c2dc6
CREATE OR REPLACE FUNCTION public.drain_phantom_consumer_stock_batch_run(p_caller_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_role text;
  r record;
  v_drained_rows int := 0;
  v_drained_units numeric := 0;
  v_failed int := 0;
BEGIN
  IF p_caller_id IS NULL THEN
    RAISE EXCEPTION 'drain_phantom_consumer_stock_batch_run: p_caller_id required';
  END IF;
  SELECT role INTO v_role FROM public.user_profiles WHERE id = p_caller_id;
  IF coalesce(v_role,'') NOT IN ('operator_admin','superadmin') THEN
    RAISE EXCEPTION 'drain_phantom_consumer_stock_batch_run: role % cannot drain', coalesce(v_role,'unknown');
  END IF;

  FOR r IN
    SELECT wh_inventory_id, phantom_units, consumer_stock
    FROM public.v_consumer_stock_leaks
    WHERE phantom_units > 0
  LOOP
    BEGIN
      PERFORM set_config('app.via_rpc','true',true);
      PERFORM set_config('app.rpc_name','drain_phantom_consumer_stock_batch_run',true);
      PERFORM set_config('app.mutation_reason',
        format('drain phantom %s units wh=%s by=%s reason=%s',
          r.phantom_units, r.wh_inventory_id, p_caller_id,
          'bug006_phantom_drain_2026-05-30_audit-finding-F3'), true);

      UPDATE public.warehouse_inventory
         SET consumer_stock = greatest(coalesce(consumer_stock,0) - r.phantom_units, 0)
       WHERE wh_inventory_id = r.wh_inventory_id
         AND coalesce(consumer_stock,0) >= r.phantom_units;

      IF FOUND THEN
        v_drained_rows := v_drained_rows + 1;
        v_drained_units := v_drained_units + r.phantom_units;
      ELSE
        v_failed := v_failed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'result','success',
    'rows_drained', v_drained_rows,
    'units_drained', v_drained_units,
    'failed', v_failed,
    'ran_at', now(),
    'ran_by', p_caller_id
  );
END $function$
