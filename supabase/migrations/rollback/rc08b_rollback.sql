-- ROLLBACK for 20260718090003_rc08b_dispatch_wh_propagation_literals.sql
-- Restores VERBATIM pre-B live bodies (captured 2026-07-18) and re-magics the 6
-- de-magicked sites (public.wh_central_id() -> the literal). No data change:
-- from_warehouse_id values written in the interim stay valid (reverting code does
-- not corrupt them). Rollback is pure DDL.

-- (1) add_dispatch_row — verbatim pre-B (no from_warehouse_id propagation).
CREATE OR REPLACE FUNCTION public.add_dispatch_row(p_machine_id uuid, p_shelf_code text, p_boonz_product_id uuid, p_quantity numeric, p_action text, p_dispatch_date date, p_source_kind text DEFAULT 'unknown'::text, p_source_warehouse_id uuid DEFAULT NULL::uuid, p_source_machine_id uuid DEFAULT NULL::uuid, p_edit_role text DEFAULT NULL::text, p_reason text DEFAULT NULL::text, p_conductor_session text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role            text;
  v_shelf_id        uuid;
  v_pod_product_id  uuid;
  v_new_id          uuid;
  v_after           jsonb;
  v_src_name        text;
  v_bp_name         text;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','add_dispatch_row',true);

  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NOT NULL AND v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'forbidden: add_dispatch_row requires field_staff / warehouse / operator_admin';
  END IF;

  IF p_machine_id IS NULL OR p_boonz_product_id IS NULL OR p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'p_machine_id, p_boonz_product_id, p_quantity (>0) required';
  END IF;
  IF p_action NOT IN ('Refill','Add New','Remove') THEN
    RAISE EXCEPTION 'p_action must be Refill | Add New | Remove (title case)';
  END IF;
  IF p_source_kind NOT IN ('wh','m2m','truck_transfer','unknown') THEN
    RAISE EXCEPTION 'invalid p_source_kind';
  END IF;
  IF p_source_kind = 'wh' AND p_source_warehouse_id IS NULL THEN
    RAISE EXCEPTION 'source_kind=wh requires p_source_warehouse_id';
  END IF;
  IF p_source_kind IN ('m2m','truck_transfer') AND p_source_machine_id IS NULL THEN
    RAISE EXCEPTION 'source_kind=% requires p_source_machine_id', p_source_kind;
  END IF;

  IF p_source_kind = 'm2m' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.pod_inventory
      WHERE machine_id = p_source_machine_id
        AND boonz_product_id = p_boonz_product_id
        AND status = 'Active' AND current_stock > 0
    ) THEN
      SELECT official_name INTO v_src_name FROM public.machines WHERE machine_id = p_source_machine_id;
      SELECT boonz_product_name INTO v_bp_name FROM public.boonz_products WHERE product_id = p_boonz_product_id;
      RAISE EXCEPTION 'Source machine % does not carry % — no Active pod_inventory > 0. Pick a different source machine or use a warehouse.',
        COALESCE(v_src_name, p_source_machine_id::text),
        COALESCE(v_bp_name, p_boonz_product_id::text);
    END IF;
  END IF;

  SELECT shelf_id INTO v_shelf_id
  FROM public.shelf_configurations
  WHERE machine_id = p_machine_id AND shelf_code = p_shelf_code;
  IF v_shelf_id IS NULL THEN
    RAISE EXCEPTION 'shelf_code % not found on machine %', p_shelf_code, p_machine_id;
  END IF;

  SELECT sl.pod_product_id INTO v_pod_product_id
  FROM public.slot_lifecycle sl
  WHERE sl.machine_id = p_machine_id
    AND sl.shelf_id   = v_shelf_id
    AND sl.is_current = true
    AND sl.archived   = false
    AND EXISTS (
      SELECT 1 FROM public.product_mapping pm2
      WHERE pm2.pod_product_id   = sl.pod_product_id
        AND pm2.boonz_product_id = p_boonz_product_id
        AND pm2.status = 'Active'
    )
  ORDER BY sl.rotated_in_at DESC NULLS LAST
  LIMIT 1;

  IF v_pod_product_id IS NULL THEN
    SELECT pm.pod_product_id INTO v_pod_product_id
    FROM public.product_mapping pm
    WHERE pm.boonz_product_id = p_boonz_product_id AND pm.status = 'Active'
      AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)
    ORDER BY (pm.machine_id = p_machine_id) DESC NULLS LAST, pm.is_global_default DESC
    LIMIT 1;
  END IF;

  IF v_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'no Active product_mapping for boonz_product % on machine %', p_boonz_product_id, p_machine_id;
  END IF;

  INSERT INTO public.refill_dispatching
    (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action,
     quantity, packed, dispatched, picked_up, returned, item_added, include,
     source_kind, source_warehouse_id, source_machine_id, is_m2m, created_by_edit,
     last_edited_by, last_edited_by_role, last_edited_at, edit_count)
  VALUES
    (p_machine_id, v_shelf_id, v_pod_product_id, p_boonz_product_id, p_dispatch_date, p_action,
     p_quantity, false, false, false, false, false, true,
     p_source_kind, p_source_warehouse_id, p_source_machine_id, (p_source_kind IN ('m2m','truck_transfer')), true,
     auth.uid(), p_edit_role, now(), 0)
  RETURNING dispatch_id INTO v_new_id;

  v_after := jsonb_build_object(
    'dispatch_id', v_new_id, 'machine_id', p_machine_id, 'shelf_id', v_shelf_id,
    'boonz_product_id', p_boonz_product_id, 'pod_product_id', v_pod_product_id,
    'quantity', p_quantity, 'action', p_action, 'source_kind', p_source_kind,
    'source_warehouse_id', p_source_warehouse_id, 'source_machine_id', p_source_machine_id);

  INSERT INTO public.refill_dispatching_edit_log
    (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
  VALUES
    (v_new_id, auth.uid(), p_edit_role, 'add', NULL, v_after, p_reason, p_conductor_session);

  RETURN jsonb_build_object('dispatch_id', v_new_id, 'edit_kind','add', 'after', v_after);
END $function$;

-- (2) pick_wh_batch_for_machine — verbatim pre-B (no QUAR/EXP guard; 'unreserved_fifo').
CREATE OR REPLACE FUNCTION public.pick_wh_batch_for_machine(p_boonz_product_id uuid, p_machine_id uuid, p_qty_needed numeric, p_expiry date DEFAULT NULL::date)
 RETURNS TABLE(wh_inventory_id uuid, batch_id text, expiration_date date, available_qty numeric, is_reserved boolean, pick_reason text, pick_rank integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT
    wh_inventory_id,
    batch_id,
    expiration_date,
    warehouse_stock AS available_qty,
    COALESCE(reserved_for_machine_id = p_machine_id, false) AS is_reserved,
    CASE
      WHEN reserved_for_machine_id = p_machine_id THEN 'reserved_for_this_machine'
      WHEN reserved_for_machine_id IS NULL THEN 'unreserved_fifo'
      ELSE 'held_for_other_machine_excluded'
    END AS pick_reason,
    (ROW_NUMBER() OVER (
      ORDER BY
        COALESCE(reserved_for_machine_id = p_machine_id, false) DESC,
        expiration_date ASC NULLS LAST,
        COALESCE(reservation_priority, 999) ASC,
        created_at ASC
    ))::int AS pick_rank
  FROM warehouse_inventory
  WHERE boonz_product_id = p_boonz_product_id
    AND status = 'Active'
    AND COALESCE(warehouse_stock, 0) >= p_qty_needed
    AND (p_expiry IS NULL OR expiration_date >= p_expiry)
    AND (reserved_for_machine_id IS NULL OR reserved_for_machine_id = p_machine_id)
  ORDER BY
    COALESCE(reserved_for_machine_id = p_machine_id, false) DESC,
    expiration_date ASC NULLS LAST,
    COALESCE(reservation_priority, 999) ASC,
    created_at ASC
  LIMIT 5;
$function$;

-- (3) log_manual_refill — verbatim pre-B (no QUAR/EXP guard on the FEFO draw).
--     Full body in include file for length.
\i rollback/rc08b_log_manual_refill_pre.sql

-- (4) receive_dispatch_line + return_dispatch_line — verbatim pre-B (v_default_wh
--     literal fallback). Full bodies in include files for length.
\i rollback/rc08b_receive_pre.sql
\i rollback/rc08b_return_pre.sql

-- (5) Re-magic: restore the literal in the 6 de-magicked sites.
DO $rc08b_remagic$
DECLARE r record; v_new_def text; v_hit int := 0;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname, pg_get_functiondef(p.oid) AS def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('auto_generate_refill_plan','bind_dispatch_fefo','inject_swap',
                        'pack_dispatch_line','receive_purchase_order','set_machine_warehouse')
      AND p.prosrc LIKE '%public.wh_central_id()%'
  LOOP
    v_new_def := replace(r.def, 'public.wh_central_id()', '''4bebef68-9e36-4a5c-9c2c-142f8dbdae85''');
    EXECUTE v_new_def;
    v_hit := v_hit + 1;
  END LOOP;
  RAISE NOTICE 'RC-08-B rollback: re-magicked % sites', v_hit;
END
$rc08b_remagic$;
