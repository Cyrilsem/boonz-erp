-- backported from prod pg_get_functiondef on 2026-07-18, RC-15 parity
-- Live function definitions that exist NOWHERE in repo migrations or the RC-15 migration
-- backports (their defining migrations were prod-only / chat-applied). Byte-faithful to
-- pg_get_functiondef output; applying to prod is a no-op re-create.

-- ============================================================================
-- adjust_pod_inventory: live-only drift: defined/evolved via prod-only migrations (20260504 inventory_rpc_* through 20260607 prd019_set_dispatch_include_service_role_bypass); no repo migration ever defines it
-- ============================================================================
CREATE OR REPLACE FUNCTION public.adjust_pod_inventory(p_machine_name text, p_snapshot_date date DEFAULT CURRENT_DATE, p_lines jsonb DEFAULT NULL::jsonb, p_reason text DEFAULT 'physical_count_reconciliation'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role text;
  v_machine_id uuid;
  v_line jsonb;
  v_bpid uuid;
  v_new_qty numeric;
  v_exp date;
  v_batch text;
  v_shelf_code text;
  v_shelf_id uuid;
  v_product_name text;
  v_existing pod_inventory%ROWTYPE;
  v_old_qty numeric;
  v_pod_id uuid;
  v_lines_processed int := 0;
  v_lines_updated int := 0;
  v_lines_inserted int := 0;
  v_lines_zeroed int := 0;
  v_results jsonb := '[]'::jsonb;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'adjust_pod_inventory', true);

  SELECT role INTO v_role FROM user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NOT NULL AND (v_role IS NULL OR v_role NOT IN ('warehouse', 'operator_admin', 'superadmin', 'manager')) THEN
    RAISE EXCEPTION 'Unauthorized: role "%" cannot adjust pod inventory', COALESCE(v_role, 'none');
  END IF;

  SELECT machine_id INTO v_machine_id FROM machines WHERE official_name = p_machine_name;
  IF v_machine_id IS NULL THEN
    RAISE EXCEPTION 'Machine "%" not found', p_machine_name;
  END IF;

  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'p_lines must be a non-empty JSON array';
  END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_bpid       := (v_line->>'boonz_product_id')::uuid;
    v_new_qty    := (v_line->>'new_qty')::numeric;
    v_exp        := (v_line->>'expiration_date')::date;
    v_batch      := v_line->>'batch_id';
    v_shelf_code := v_line->>'shelf_code';

    IF v_bpid IS NULL THEN RAISE EXCEPTION 'boonz_product_id required in every line'; END IF;
    IF v_new_qty IS NULL OR v_new_qty < 0 THEN RAISE EXCEPTION 'new_qty must be >= 0'; END IF;
    IF v_shelf_code IS NULL THEN RAISE EXCEPTION 'shelf_code required in every line'; END IF;

    SELECT boonz_product_name INTO v_product_name
    FROM boonz_products WHERE product_id = v_bpid;
    IF v_product_name IS NULL THEN
      RAISE EXCEPTION 'boonz_product_id % not found', v_bpid;
    END IF;

    SELECT shelf_id INTO v_shelf_id
    FROM shelf_configurations
    WHERE machine_id = v_machine_id AND shelf_code = v_shelf_code;

    SELECT * INTO v_existing FROM pod_inventory
    WHERE machine_id = v_machine_id
      AND boonz_product_id = v_bpid
      AND (shelf_id = v_shelf_id OR (shelf_id IS NULL AND v_shelf_id IS NULL))
      AND (expiration_date = v_exp OR (expiration_date IS NULL AND v_exp IS NULL))
      AND status = 'Active'
    ORDER BY snapshot_at DESC
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      v_old_qty := COALESCE(v_existing.current_stock, 0);
      v_pod_id := v_existing.pod_inventory_id;

      UPDATE pod_inventory
      SET current_stock = v_new_qty,
          estimated_remaining = v_new_qty,
          expiration_date = COALESCE(v_exp, v_existing.expiration_date),
          batch_id = COALESCE(v_batch, v_existing.batch_id),
          snapshot_date = p_snapshot_date,
          snapshot_at = now(),
          status = CASE WHEN v_new_qty = 0 THEN 'Inactive' ELSE 'Active' END
      WHERE pod_inventory_id = v_existing.pod_inventory_id;

      v_lines_updated := v_lines_updated + 1;
      IF v_new_qty = 0 THEN v_lines_zeroed := v_lines_zeroed + 1; END IF;
    ELSE
      v_old_qty := 0;

      INSERT INTO pod_inventory (
        machine_id, shelf_id, boonz_product_id,
        snapshot_date, current_stock, estimated_remaining,
        expiration_date, batch_id, status, snapshot_at
      ) VALUES (
        v_machine_id, v_shelf_id, v_bpid,
        p_snapshot_date, v_new_qty, v_new_qty,
        v_exp, COALESCE(v_batch, format('ADJUST-%s', p_snapshot_date)),
        CASE WHEN v_new_qty = 0 THEN 'Inactive' ELSE 'Active' END,
        now()
      )
      RETURNING pod_inventory_id INTO v_pod_id;

      v_lines_inserted := v_lines_inserted + 1;
    END IF;

    INSERT INTO pod_inventory_audit_log (
      pod_inventory_id, machine_id, shelf_id, boonz_product_id,
      expiration_date, source, operation,
      old_stock, new_stock, delta,
      old_status, new_status, actor,
      reference_id, notes
    ) VALUES (
      v_pod_id, v_machine_id, v_shelf_id, v_bpid,
      v_exp, 'correction',
      CASE WHEN v_old_qty = 0 AND v_new_qty > 0 THEN 'insert' ELSE 'update' END,
      v_old_qty, v_new_qty, v_new_qty - v_old_qty,
      CASE WHEN v_old_qty > 0 THEN 'Active' ELSE NULL END,
      CASE WHEN v_new_qty = 0 THEN 'Inactive' ELSE 'Active' END,
      auth.uid(),
      format('adjust-%s-%s-%s', p_machine_name, v_shelf_code, p_snapshot_date),
      format('%s: %s -> %s on %s/%s — %s', v_product_name, v_old_qty, v_new_qty, p_machine_name, v_shelf_code, p_reason)
    );

    v_lines_processed := v_lines_processed + 1;

    v_results := v_results || jsonb_build_object(
      'shelf_code', v_shelf_code,
      'product', v_product_name,
      'old_qty', v_old_qty,
      'new_qty', v_new_qty,
      'delta', v_new_qty - v_old_qty,
      'pod_inventory_id', v_pod_id,
      'action', CASE WHEN v_old_qty = 0 AND v_new_qty > 0 THEN 'inserted'
                     WHEN v_new_qty = 0 THEN 'zeroed'
                     ELSE 'updated' END
    );
  END LOOP;

  RETURN jsonb_build_object(
    'status', 'ok',
    'machine', p_machine_name,
    'snapshot_date', p_snapshot_date,
    'lines_processed', v_lines_processed,
    'lines_updated', v_lines_updated,
    'lines_inserted', v_lines_inserted,
    'lines_zeroed', v_lines_zeroed,
    'details', v_results
  );
END;
$function$;

-- ============================================================================
-- apply_inventory_correction: live-only drift: defined via prod-only migrations (20260512 apply_inventory_correction_rpc, 20260512 bug001_block_silent_reactivation); no repo migration ever defines it
-- ============================================================================
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
$function$;

-- ============================================================================
-- confirm_stitched_plan: live-only drift: defined via prod-only migration (20260511 phaseF_gate_rpcs_approve_and_confirm); no repo migration ever defines it
-- ============================================================================
CREATE OR REPLACE FUNCTION public.confirm_stitched_plan(p_plan_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id   uuid;
  v_rows      integer;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'confirm_stitched_plan', true);

  v_user_id := auth.uid();
  -- Allow service_role too — Stage 3 Stitch (edge function) will call this
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id AND up.role = 'operator_admin'
  ) THEN
    RAISE EXCEPTION 'confirm_stitched_plan: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'p_plan_date required';
  END IF;

  UPDATE public.pod_refill_plan
     SET status      = 'stitched',
         stitched_at = now(),
         updated_at  = now()
   WHERE plan_date = p_plan_date
     AND status    = 'approved';

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN jsonb_build_object('plan_date', p_plan_date, 'stitched_rows', v_rows);
END;
$function$;

-- ============================================================================
-- edit_dispatch_product: live-only drift: base def is prod-only (20260519 phaseF_dispatch_editing_rpcs, 20260623 prd052); the backported fixD2 (20260714235045) is a patch-on-live and cannot replay without this base
-- ============================================================================
CREATE OR REPLACE FUNCTION public.edit_dispatch_product(p_dispatch_id uuid, p_new_boonz_product_id uuid, p_edit_role text, p_reason text DEFAULT NULL::text, p_conductor_session text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row     refill_dispatching%ROWTYPE;
  v_role    text;
  v_new_pod uuid;
  v_before  jsonb;
  v_after   jsonb;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','edit_dispatch_product',true);

  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NOT NULL AND v_role NOT IN ('field_staff','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'forbidden: edit_dispatch_product requires field_staff (driver) / operator_admin / superadmin / manager';
  END IF;

  IF p_new_boonz_product_id IS NULL THEN RAISE EXCEPTION 'p_new_boonz_product_id required'; END IF;
  IF p_edit_role NOT IN ('driver','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'edit_dispatch_product only allowed for driver / operator_admin (not WH manager)';
  END IF;

  SELECT * INTO v_row FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'dispatch % not found', p_dispatch_id; END IF;
  IF NOT v_row.picked_up THEN RAISE EXCEPTION 'dispatch % not picked up — driver edits blocked', p_dispatch_id; END IF;
  IF v_row.item_added THEN RAISE EXCEPTION 'dispatch % already item_added — edit blocked', p_dispatch_id; END IF;

  -- FIX D2: resolve pod from the SHELF BINDING (slot_lifecycle current pod), not the
  -- product_mapping default. Accept the shelf-bound pod only when it carries the new
  -- boonz SKU via an Active product_mapping, so pod_product_id stays consistent with
  -- boonz_product_id. Fall back to product_mapping (per-machine wins, then global
  -- default) only when the shelf has no current binding that carries this SKU.
  SELECT sl.pod_product_id INTO v_new_pod
  FROM public.slot_lifecycle sl
  WHERE sl.machine_id = v_row.machine_id
    AND sl.shelf_id   = v_row.shelf_id
    AND sl.is_current = true
    AND sl.archived   = false
    AND EXISTS (
      SELECT 1 FROM public.product_mapping pm2
      WHERE pm2.pod_product_id   = sl.pod_product_id
        AND pm2.boonz_product_id = p_new_boonz_product_id
        AND pm2.status = 'Active'
    )
  ORDER BY sl.rotated_in_at DESC NULLS LAST
  LIMIT 1;

  IF v_new_pod IS NULL THEN
    SELECT pm.pod_product_id INTO v_new_pod
    FROM public.product_mapping pm
    WHERE pm.boonz_product_id = p_new_boonz_product_id
      AND pm.status = 'Active'
      AND (pm.machine_id = v_row.machine_id OR pm.machine_id IS NULL)
    ORDER BY (pm.machine_id = v_row.machine_id) DESC NULLS LAST, pm.is_global_default DESC
    LIMIT 1;
  END IF;

  IF v_new_pod IS NULL THEN
    RAISE EXCEPTION 'boonz_product % has no Active product_mapping for machine %', p_new_boonz_product_id, v_row.machine_id;
  END IF;

  v_before := jsonb_build_object('boonz_product_id', v_row.boonz_product_id,
                                 'pod_product_id',   v_row.pod_product_id);

  UPDATE public.refill_dispatching
  SET boonz_product_id          = p_new_boonz_product_id,
      pod_product_id            = v_new_pod,
      original_boonz_product_id = COALESCE(original_boonz_product_id, v_row.boonz_product_id),
      edit_count                = edit_count + 1,
      last_edited_by            = auth.uid(),
      last_edited_by_role       = p_edit_role,
      last_edited_at            = now()
  WHERE dispatch_id = p_dispatch_id;

  v_after := jsonb_build_object('boonz_product_id', p_new_boonz_product_id,
                                'pod_product_id',   v_new_pod);

  INSERT INTO public.refill_dispatching_edit_log
    (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
  VALUES
    (p_dispatch_id, auth.uid(), p_edit_role, 'product', v_before, v_after, p_reason, p_conductor_session);

  RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'edit_kind','product',
                            'before', v_before, 'after', v_after);
END $function$;

-- ============================================================================
-- edit_dispatch_qty: live-only drift: base def is prod-only (20260519 phaseF_dispatch_editing_rpcs, 20260622 prd049_c, 20260623 prd052); no repo migration ever defines it
-- ============================================================================
CREATE OR REPLACE FUNCTION public.edit_dispatch_qty(p_dispatch_id uuid, p_new_qty numeric, p_edit_role text, p_reason text DEFAULT NULL::text, p_conductor_session text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row    refill_dispatching%ROWTYPE;
  v_role   text;
  v_before jsonb;
  v_after  jsonb;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','edit_dispatch_qty',true);

  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NOT NULL AND v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'forbidden: edit_dispatch_qty requires warehouse / operator_admin / superadmin / manager';
  END IF;

  IF p_new_qty IS NULL OR p_new_qty < 0 THEN RAISE EXCEPTION 'invalid p_new_qty'; END IF;
  IF p_edit_role NOT IN ('driver','warehouse_manager','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'invalid p_edit_role';
  END IF;

  SELECT * INTO v_row FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'dispatch % not found', p_dispatch_id; END IF;
  IF v_row.item_added THEN
    RAISE EXCEPTION 'dispatch % already item_added — edit blocked', p_dispatch_id;
  END IF;

  v_before := jsonb_build_object('quantity', v_row.quantity);

  UPDATE public.refill_dispatching
  SET quantity            = p_new_qty,
      original_quantity   = COALESCE(original_quantity, v_row.quantity),
      edit_count          = edit_count + 1,
      last_edited_by      = auth.uid(),
      last_edited_by_role = p_edit_role,
      last_edited_at      = now()
  WHERE dispatch_id = p_dispatch_id;

  v_after := jsonb_build_object('quantity', p_new_qty);

  INSERT INTO public.refill_dispatching_edit_log
    (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
  VALUES
    (p_dispatch_id, auth.uid(), p_edit_role, 'qty', v_before, v_after, p_reason, p_conductor_session);

  RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'edit_kind','qty',
                            'before', v_before, 'after', v_after);
END $function$;

-- ============================================================================
-- repack_machine: live-only drift: defined via prod-only migrations (20260504 m10_repack_machine_rpc, 20260513 repack_machine_add_dispatch_gate); no repo migration ever defines it
-- ============================================================================
CREATE OR REPLACE FUNCTION public.repack_machine(p_machine_name text, p_dispatch_date date DEFAULT NULL::date, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role      text;
  v_machine_id       uuid;
  v_today            date := (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date;
  v_target_date      date;
  v_returned_count   int := 0;
  v_failed_returns   int := 0;
  v_resets_done      int := 0;
  v_pushed           int := 0;
  v_dispatched_count int := 0;
  v_row              record;
  v_push_result      jsonb;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','repack_machine',true);
  PERFORM set_config('app.mutation_reason',
    format('repack_machine: %s for %s (reason: %s)',
           p_machine_name,
           COALESCE(p_dispatch_date, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date),
           COALESCE(p_reason,'none')),
    true);

  -- Caller role guard
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RETURN jsonb_build_object('status','error','error','Insufficient role');
  END IF;

  v_target_date := COALESCE(p_dispatch_date, v_today);

  SELECT machine_id INTO v_machine_id FROM machines WHERE official_name = p_machine_name;
  IF v_machine_id IS NULL THEN
    RETURN jsonb_build_object('status','error','error','Machine not found: ' || p_machine_name);
  END IF;

  -- 🛑 Dispatch gate: refuse repack if ANY row for this (machine, date) is dispatched=true.
  -- Once the bag has been dispatched, returning stock to the warehouse is no longer accurate.
  SELECT COUNT(*) INTO v_dispatched_count
  FROM refill_dispatching
  WHERE machine_id    = v_machine_id
    AND dispatch_date = v_target_date
    AND dispatched    = true;

  IF v_dispatched_count > 0 THEN
    RETURN jsonb_build_object(
      'status','error',
      'error','cannot_repack_after_dispatch',
      'message', format('Cannot repack %s for %s — %s row(s) already dispatched.',
                        p_machine_name, v_target_date, v_dispatched_count),
      'dispatched_count', v_dispatched_count,
      'machine', p_machine_name,
      'dispatch_date', v_target_date
    );
  END IF;

  -- Step 1: Return stock & mark each packed-not-picked-up row terminal
  FOR v_row IN
    SELECT dispatch_id, shelf_id, boonz_product_id, action
    FROM refill_dispatching
    WHERE machine_id    = v_machine_id
      AND dispatch_date = v_target_date
      AND packed        = true
      AND picked_up     = false
      AND returned      = false
      AND item_added    = false
    ORDER BY created_at
  LOOP
    BEGIN
      PERFORM public.return_dispatch_line(v_row.dispatch_id, 'superseded_by_repack');
      v_returned_count := v_returned_count + 1;
    EXCEPTION WHEN OTHERS THEN
      v_failed_returns := v_failed_returns + 1;
      RAISE WARNING 'repack_machine: return_dispatch_line failed for %, error: %',
        v_row.dispatch_id, SQLERRM;
    END;
  END LOOP;

  -- Step 2: Reset matching plan rows so push_plan_to_dispatch can re-mirror.
  -- Only reset rows whose 1:1 matching dispatch row is now terminal AND not received.
  UPDATE refill_plan_output rpo
  SET dispatched = false
  WHERE rpo.plan_date        = v_target_date
    AND rpo.machine_name     = p_machine_name
    AND rpo.operator_status  = 'approved'
    AND rpo.dispatched       = true
    AND NOT EXISTS (
      -- skip plan rows whose dispatch was successfully received (item_added=true)
      SELECT 1
      FROM refill_dispatching rd
      JOIN machines m ON m.machine_id = rd.machine_id
      LEFT JOIN shelf_configurations sc ON sc.shelf_id = rd.shelf_id
      WHERE m.official_name = rpo.machine_name
        AND rd.dispatch_date = rpo.plan_date
        AND COALESCE(sc.shelf_code,'') = COALESCE(rpo.shelf_code,'')
        AND rd.item_added = true
    );
  GET DIAGNOSTICS v_resets_done = ROW_COUNT;

  -- Step 3: Push the plan rows fresh
  IF v_resets_done > 0 THEN
    v_push_result := public.push_plan_to_dispatch(p_machine_name, v_target_date);
    v_pushed := COALESCE((v_push_result->>'lines_pushed')::int, 0);
  END IF;

  RETURN jsonb_build_object(
    'status',           'ok',
    'machine',          p_machine_name,
    'dispatch_date',    v_target_date,
    'returned_count',   v_returned_count,
    'failed_returns',   v_failed_returns,
    'plan_rows_reset',  v_resets_done,
    'fresh_dispatch_rows_created', v_pushed,
    'reason',           p_reason
  );
END;
$function$;

-- ============================================================================
-- reset_approved_undispatched: live-only drift: defined via prod-only migrations (20260605 phaseF_reset_approved_undispatched_writer, 20260616 prd019_d1b/f1 prod variants); no repo migration ever defines it
-- ============================================================================
CREATE OR REPLACE FUNCTION public.reset_approved_undispatched(p_plan_date date, p_machine_ids uuid[], p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid           uuid := (SELECT auth.uid());
  v_role          text;
  v_machine_names text[];
  v_blocked       integer;
  v_disp          record;
  v_skipped       integer := 0;
  v_rpo_reset     integer := 0;
BEGIN
  -- Article 4: role gate (service/NULL context bypasses, mirrors reset_and_restitch)
  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin') THEN
      RAISE EXCEPTION 'reset_approved_undispatched: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  -- Article 4: input validation
  IF p_plan_date IS NULL THEN RAISE EXCEPTION 'p_plan_date required'; END IF;
  IF p_machine_ids IS NULL OR array_length(p_machine_ids,1) IS NULL THEN
    RAISE EXCEPTION 'p_machine_ids required (non-empty array)';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>= 10 chars)';
  END IF;

  SELECT array_agg(m.official_name) INTO v_machine_names
    FROM public.machines m WHERE m.machine_id = ANY(p_machine_ids);
  IF v_machine_names IS NULL OR array_length(v_machine_names,1) <> array_length(p_machine_ids,1) THEN
    RAISE EXCEPTION 'reset_approved_undispatched: one or more machine_ids not found';
  END IF;

  -- Article 5 guard: refuse if any in-scope approved row is unsafe to reverse
  SELECT COUNT(*) INTO v_blocked
    FROM public.refill_plan_output rpo
    JOIN public.refill_dispatching rd ON rd.dispatch_id = rpo.dispatch_id
   WHERE rpo.plan_date = p_plan_date
     AND rpo.machine_name = ANY(v_machine_names)
     AND rpo.operator_status = 'approved'
     AND (COALESCE(rd.dispatched,false) = true
          OR COALESCE(rd.picked_up,false) = true
          OR COALESCE(rd.packed,false) = true
          OR rd.from_wh_inventory_id IS NOT NULL
          OR COALESCE(rd.cancelled,false) = true);
  IF v_blocked > 0 THEN
    RAISE EXCEPTION 'reset_approved_undispatched: % approved row(s) dispatched/picked_up/packed/WH-bound/cancelled; refusing', v_blocked;
  END IF;

  -- Neutralize the open dispatch rows via the allowlisted canonical RPC (skipped + include=false)
  FOR v_disp IN
    SELECT rd.dispatch_id
      FROM public.refill_plan_output rpo
      JOIN public.refill_dispatching rd ON rd.dispatch_id = rpo.dispatch_id
     WHERE rpo.plan_date = p_plan_date
       AND rpo.machine_name = ANY(v_machine_names)
       AND rpo.operator_status = 'approved'
       AND COALESCE(rd.skipped,false) = false
       AND COALESCE(rd.cancelled,false) = false
  LOOP
    PERFORM public.skip_dispatch_line(v_disp.dispatch_id, p_reason);
    v_skipped := v_skipped + 1;
  END LOOP;

  -- Article 4/8: re-stamp GUCs for the rpo audit (skip_dispatch_line overwrote app.rpc_name)
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'reset_approved_undispatched', true);
  PERFORM set_config('app.mutation_reason', p_reason, true);

  -- Article 5: guarded backward transition approved -> pending
  UPDATE public.refill_plan_output
     SET operator_status = 'pending',
         dispatch_id     = NULL,
         dispatched      = false
   WHERE plan_date = p_plan_date
     AND machine_name = ANY(v_machine_names)
     AND operator_status = 'approved';
  GET DIAGNOSTICS v_rpo_reset = ROW_COUNT;

  RETURN jsonb_build_object(
    'status','ok',
    'plan_date', p_plan_date,
    'machine_names', v_machine_names,
    'dispatch_rows_skipped', v_skipped,
    'rpo_reset_to_pending', v_rpo_reset,
    'reason', p_reason
  );
END;
$function$;
