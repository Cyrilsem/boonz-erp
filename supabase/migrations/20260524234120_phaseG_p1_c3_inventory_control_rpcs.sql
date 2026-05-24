-- Migration: phaseG_p1_c3_inventory_control_rpcs
-- PRD v2 Phase G, Workstream C.3 plus the new canonical writer inactivate_warehouse_row (PRD B.2).
-- Articles: 1 (narrow-concern writer via Amendment 005), 4, 5, 6 (propose-then-confirm amended), 7, 8, 12, 14, 15.
-- Dara designed C.1/C.2. Cody approved with revisions R1 (reservation guard), R2 (article header), R3 (function COMMENT).

-- =====================================================================
-- 1. inactivate_warehouse_row  (NEW CANONICAL WRITER)
-- =====================================================================
CREATE OR REPLACE FUNCTION public.inactivate_warehouse_row(
  p_wh_inventory_id uuid,
  p_reason          text,
  p_inactivated_by  uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row         public.warehouse_inventory%ROWTYPE;
  v_caller_role text;
  v_user_id     uuid;
BEGIN
  v_user_id := COALESCE(p_inactivated_by, auth.uid());

  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'inactivate_warehouse_row: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;

  IF COALESCE(p_reason, '') = '' OR length(trim(p_reason)) < 4 THEN
    RAISE EXCEPTION 'inactivate_warehouse_row: p_reason required (min 4 chars)';
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'inactivate_warehouse_row', true);
  PERFORM set_config('app.mutation_reason',
    format('inactivate_warehouse_row by %s: %s', COALESCE(v_user_id::text, 'system'), p_reason), true);

  SELECT * INTO v_row FROM public.warehouse_inventory
    WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'inactivate_warehouse_row: wh_inventory_id % not found', p_wh_inventory_id;
  END IF;

  IF v_row.status <> 'Active' THEN
    RAISE EXCEPTION 'inactivate_warehouse_row: row already in status % (only Active rows can be inactivated)', v_row.status;
  END IF;

  IF COALESCE(v_row.warehouse_stock, 0) > 0 OR COALESCE(v_row.consumer_stock, 0) > 0 THEN
    RAISE EXCEPTION 'inactivate_warehouse_row: refusing to inactivate row with stock > 0 (warehouse_stock=%, consumer_stock=%). Drain stock via apply_inventory_correction first.',
      COALESCE(v_row.warehouse_stock, 0), COALESCE(v_row.consumer_stock, 0);
  END IF;

  -- R1 per Cody: do not orphan a reservation by inactivating its source row.
  IF v_row.reserved_for_machine_id IS NOT NULL THEN
    RAISE EXCEPTION 'inactivate_warehouse_row: refusing to inactivate row reserved for machine % (release the reservation first)', v_row.reserved_for_machine_id;
  END IF;

  UPDATE public.warehouse_inventory
     SET status = 'Inactive'
   WHERE wh_inventory_id = p_wh_inventory_id;

  RETURN jsonb_build_object(
    'status',          'inactivated',
    'wh_inventory_id', p_wh_inventory_id,
    'reason',          p_reason
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.inactivate_warehouse_row(uuid, text, uuid) TO authenticated;

COMMENT ON FUNCTION public.inactivate_warehouse_row(uuid, text, uuid) IS
  'Canonical writer for warehouse_inventory.status Active->Inactive transition. Refuses when warehouse_stock>0, consumer_stock>0, or reserved_for_machine_id IS NOT NULL. Set by Phase G PRD v2 B.2. Articles 1, 4, 5, 6, 8.';

-- =====================================================================
-- 2. start_inventory_session
-- =====================================================================
CREATE OR REPLACE FUNCTION public.start_inventory_session(
  p_scope_warehouse_id uuid,
  p_scope_product_ids  uuid[] DEFAULT NULL,
  p_session_slug       text   DEFAULT NULL,
  p_started_by         uuid   DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id     uuid;
  v_caller_role text;
  v_session_id  uuid;
BEGIN
  v_user_id := COALESCE(p_started_by, auth.uid());

  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'start_inventory_session: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'start_inventory_session', true);

  UPDATE public.inventory_control_session
     SET status = 'aborted',
         closed_at = now(),
         closed_by = v_user_id,
         summary = jsonb_build_object('aborted_reason','superseded_by_new_session')
   WHERE started_by = v_user_id AND status = 'open';

  INSERT INTO public.inventory_control_session
    (session_slug, started_by, scope_warehouse_id, scope_product_ids, status)
  VALUES
    (p_session_slug, v_user_id, p_scope_warehouse_id, p_scope_product_ids, 'open')
  RETURNING session_id INTO v_session_id;

  RETURN jsonb_build_object(
    'session_id',         v_session_id,
    'session_slug',       p_session_slug,
    'scope_warehouse_id', p_scope_warehouse_id,
    'status',             'open'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.start_inventory_session(uuid, uuid[], text, uuid) TO authenticated;

-- =====================================================================
-- 3. close_inventory_session
-- =====================================================================
CREATE OR REPLACE FUNCTION public.close_inventory_session(
  p_session_id uuid,
  p_closed_by  uuid  DEFAULT NULL,
  p_summary    jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id      uuid;
  v_caller_role  text;
  v_session      public.inventory_control_session%ROWTYPE;
  v_summary      jsonb;
BEGIN
  v_user_id := COALESCE(p_closed_by, auth.uid());

  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'close_inventory_session: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'close_inventory_session', true);

  SELECT * INTO v_session FROM public.inventory_control_session
    WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'close_inventory_session: session % not found', p_session_id;
  END IF;
  IF v_session.status <> 'open' THEN
    RAISE EXCEPTION 'close_inventory_session: session % already %', p_session_id, v_session.status;
  END IF;

  SELECT jsonb_build_object(
    'attempt_total',     COUNT(*),
    'success_count',     COUNT(*) FILTER (WHERE result = 'success'),
    'failure_count',     COUNT(*) FILTER (WHERE result <> 'success'),
    'by_result',         COALESCE(jsonb_object_agg(result, n) FILTER (WHERE result IS NOT NULL), '{}'::jsonb),
    'distinct_products', COUNT(DISTINCT boonz_product_id) FILTER (WHERE boonz_product_id IS NOT NULL),
    'distinct_rows',     COUNT(DISTINCT wh_inventory_id)  FILTER (WHERE wh_inventory_id IS NOT NULL)
  )
  INTO v_summary
  FROM (
    SELECT result, COUNT(*) AS n, boonz_product_id, wh_inventory_id
    FROM public.inventory_control_attempt
    WHERE session_id = p_session_id
    GROUP BY result, boonz_product_id, wh_inventory_id
  ) sub;

  v_summary := COALESCE(v_summary, '{}'::jsonb) || COALESCE(p_summary, '{}'::jsonb);

  UPDATE public.inventory_control_session
     SET status    = 'closed',
         closed_at = now(),
         closed_by = v_user_id,
         summary   = v_summary
   WHERE session_id = p_session_id;

  RETURN jsonb_build_object(
    'session_id', p_session_id,
    'status',     'closed',
    'summary',    v_summary
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.close_inventory_session(uuid, uuid, jsonb) TO authenticated;

-- =====================================================================
-- 4. attempt_inventory_correction
-- =====================================================================
CREATE OR REPLACE FUNCTION public.attempt_inventory_correction(
  p_session_id            uuid,
  p_wh_inventory_id       uuid,
  p_new_warehouse_stock   numeric,
  p_reason                text,
  p_client_correlation_id uuid,
  p_attempted_by          uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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
  -- Note: inner RPC overwrites app.rpc_name to its own ('apply_inventory_correction') so the
  -- warehouse_inventory audit trigger attributes the write to the canonical writer.

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
$$;

GRANT EXECUTE ON FUNCTION public.attempt_inventory_correction(uuid, uuid, numeric, text, uuid, uuid) TO authenticated;

-- =====================================================================
-- 5. attempt_reactivate_row
-- =====================================================================
CREATE OR REPLACE FUNCTION public.attempt_reactivate_row(
  p_session_id            uuid,
  p_wh_inventory_id       uuid,
  p_new_warehouse_stock   numeric,
  p_reason                text,
  p_client_correlation_id uuid,
  p_attempted_by          uuid DEFAULT NULL,
  p_source_doc            text DEFAULT NULL,
  p_new_expiration_date   date DEFAULT NULL,
  p_new_wh_location       text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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
    RAISE EXCEPTION 'attempt_reactivate_row: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;

  SELECT status INTO v_session_status FROM public.inventory_control_session WHERE session_id = p_session_id;
  IF v_session_status IS NULL OR v_session_status <> 'open' THEN
    RAISE EXCEPTION 'attempt_reactivate_row: session % not open', p_session_id;
  END IF;

  SELECT * INTO v_old_row FROM public.warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'attempt_reactivate_row', true);

  BEGIN
    v_rpc_response := public.reactivate_warehouse_row(
      p_wh_inventory_id      => p_wh_inventory_id,
      p_new_warehouse_stock  => p_new_warehouse_stock,
      p_reason               => p_reason,
      p_source_doc           => p_source_doc,
      p_reactivated_by       => v_user_id,
      p_new_expiration_date  => p_new_expiration_date,
      p_new_wh_location      => p_new_wh_location
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
    'status',
    CASE WHEN v_old_row.wh_inventory_id IS NOT NULL
      THEN jsonb_build_object('status', v_old_row.status, 'warehouse_stock', v_old_row.warehouse_stock)
      ELSE NULL END,
    jsonb_build_object('status', 'Active', 'warehouse_stock', p_new_warehouse_stock),
    'reactivate_warehouse_row',
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
$$;

GRANT EXECUTE ON FUNCTION public.attempt_reactivate_row(uuid, uuid, numeric, text, uuid, uuid, text, date, text) TO authenticated;

-- =====================================================================
-- 6. attempt_status_change
-- =====================================================================
CREATE OR REPLACE FUNCTION public.attempt_status_change(
  p_session_id            uuid,
  p_wh_inventory_id       uuid,
  p_new_status            text,
  p_reason                text,
  p_client_correlation_id uuid,
  p_attempted_by          uuid    DEFAULT NULL,
  p_new_warehouse_stock   numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id        uuid;
  v_caller_role    text;
  v_session_status text;
  v_old_row        public.warehouse_inventory%ROWTYPE;
  v_rpc_response   jsonb;
  v_attempt_id     uuid := gen_random_uuid();
  v_terminal       text;
  v_error_message  text;
  v_rpc_called     text;
BEGIN
  v_user_id := COALESCE(p_attempted_by, auth.uid());

  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'attempt_status_change: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;

  SELECT status INTO v_session_status FROM public.inventory_control_session WHERE session_id = p_session_id;
  IF v_session_status IS NULL OR v_session_status <> 'open' THEN
    RAISE EXCEPTION 'attempt_status_change: session % not open', p_session_id;
  END IF;

  SELECT * INTO v_old_row FROM public.warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id;
  IF v_old_row.wh_inventory_id IS NULL THEN
    RAISE EXCEPTION 'attempt_status_change: wh_inventory_id % not found', p_wh_inventory_id;
  END IF;

  IF p_new_status NOT IN ('Active','Inactive') THEN
    RAISE EXCEPTION 'attempt_status_change: only Active and Inactive transitions are supported via this wrapper, got %', p_new_status;
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'attempt_status_change', true);

  BEGIN
    IF v_old_row.status = 'Inactive' AND p_new_status = 'Active' THEN
      v_rpc_called := 'reactivate_warehouse_row';
      v_rpc_response := public.reactivate_warehouse_row(
        p_wh_inventory_id      => p_wh_inventory_id,
        p_new_warehouse_stock  => COALESCE(p_new_warehouse_stock, v_old_row.warehouse_stock),
        p_reason               => p_reason,
        p_source_doc           => NULL,
        p_reactivated_by       => v_user_id,
        p_new_expiration_date  => NULL,
        p_new_wh_location      => NULL
      );
    ELSIF v_old_row.status = 'Active' AND p_new_status = 'Inactive' THEN
      v_rpc_called := 'inactivate_warehouse_row';
      v_rpc_response := public.inactivate_warehouse_row(
        p_wh_inventory_id => p_wh_inventory_id,
        p_reason          => p_reason,
        p_inactivated_by  => v_user_id
      );
    ELSE
      RAISE EXCEPTION 'no-op or unsupported transition: % -> %', v_old_row.status, p_new_status;
    END IF;
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
    'status',
    jsonb_build_object('status', v_old_row.status, 'warehouse_stock', v_old_row.warehouse_stock),
    jsonb_build_object('status', p_new_status),
    COALESCE(v_rpc_called, 'none'),
    v_rpc_response,
    v_terminal,
    v_error_message,
    p_client_correlation_id,
    p_reason
  );

  RETURN jsonb_build_object(
    'attempt_id',   v_attempt_id,
    'rpc_called',   v_rpc_called,
    'result',       v_terminal,
    'rpc_response', v_rpc_response,
    'error',        v_error_message
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.attempt_status_change(uuid, uuid, text, text, uuid, uuid, numeric) TO authenticated;
