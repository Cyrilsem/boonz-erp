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

  SELECT pm.pod_product_id INTO v_pod_product_id
  FROM public.product_mapping pm
  WHERE pm.boonz_product_id = p_boonz_product_id AND pm.status = 'Active'
    AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)
  ORDER BY (pm.machine_id = p_machine_id) DESC NULLS LAST, pm.is_global_default DESC
  LIMIT 1;
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
END $function$
