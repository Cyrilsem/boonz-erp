-- ROLLBACK: restore live pre-Batch-2 body of attempt_inventory_correction
-- captured 2026-07-18 from eizcexopcuoycuosittm
-- md5(pg_get_functiondef) = 1fadf2fa1c572afe1e3bec9d1b0fddd9
CREATE OR REPLACE FUNCTION public.attempt_inventory_correction(p_session_id uuid, p_wh_inventory_id uuid, p_new_warehouse_stock numeric, p_reason text, p_client_correlation_id uuid, p_attempted_by uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id        uuid;
  v_caller_role    text;
  v_session_status text;
  v_old_row        public.warehouse_inventory%ROWTYPE;
  v_rpc_response   jsonb;
  v_attempt_id     uuid := gen_random_uuid();
  v_terminal       text;
  v_error_message  text;
BEGIN
  v_user_id := COALESCE(p_attempted_by, auth.uid());
  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'attempt_inventory_correction: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;
  SELECT status INTO v_session_status FROM public.inventory_control_session WHERE session_id = p_session_id;
  IF v_session_status IS NULL THEN
    RAISE EXCEPTION 'attempt_inventory_correction: session % not found', p_session_id;
  END IF;
  IF v_session_status <> 'open' THEN
    RAISE EXCEPTION 'attempt_inventory_correction: session % is %, not open', p_session_id, v_session_status;
  END IF;
  SELECT * INTO v_old_row FROM public.warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id;
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'attempt_inventory_correction', true);
  BEGIN
    v_rpc_response := public.apply_inventory_correction(
      p_wh_inventory_id      => p_wh_inventory_id,
      p_boonz_product_id     => NULL,
      p_warehouse_id         => NULL,
      p_expiration_date      => NULL,
      p_new_warehouse_stock  => p_new_warehouse_stock,
      p_reason               => p_reason,
      p_corrected_by         => v_user_id
    );
    v_terminal := 'success';
  EXCEPTION
    WHEN insufficient_privilege THEN v_terminal := 'blocked_rls';      v_error_message := SQLERRM;
    WHEN check_violation       THEN v_terminal := 'blocked_trigger';   v_error_message := SQLERRM;
    WHEN raise_exception       THEN v_terminal := 'validation_error';  v_error_message := SQLERRM;
    WHEN OTHERS                THEN v_terminal := 'rpc_error';         v_error_message := SQLERRM;
  END;
  INSERT INTO public.inventory_control_attempt (
    attempt_id, session_id, attempted_by,
    target_path, wh_inventory_id,
    field_changed, old_value, new_value,
    rpc_called, rpc_response, result, error_message,
    client_correlation_id, reason
  ) VALUES (
    v_attempt_id, p_session_id, v_user_id,
    'by_id', p_wh_inventory_id,
    'warehouse_stock',
    CASE WHEN v_old_row.wh_inventory_id IS NOT NULL
      THEN jsonb_build_object('warehouse_stock', v_old_row.warehouse_stock, 'status', v_old_row.status)
      ELSE NULL END,
    jsonb_build_object('warehouse_stock', p_new_warehouse_stock),
    'apply_inventory_correction',
    v_rpc_response,
    v_terminal,
    v_error_message,
    p_client_correlation_id,
    p_reason
  );
  RETURN jsonb_build_object(
    'attempt_id',   v_attempt_id,
    'result',       v_terminal,
    'rpc_response', v_rpc_response,
    'error',        v_error_message
  );
END;
$function$
