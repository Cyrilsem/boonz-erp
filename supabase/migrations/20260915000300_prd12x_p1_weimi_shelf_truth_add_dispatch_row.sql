-- PRD-125 D2 / ONE-LOOP Phase 1 -- WEIMI is the shelf truth.
--
-- add_dispatch_row's Remove path had the exact same three-tier bug as
-- push_plan_to_dispatch's old Remove path (see 20260915000100): a global,
-- non-shelf-scoped lot search that let the pod_inventory lot's shelf win
-- over the shelf the caller named, a flavor-correction fallback that could
-- swap the product to whatever a different lot happened to be on the same
-- shelf, and a 0-qty "[NO LOT ON SHELF]" row when nothing matched anywhere.
--
-- Fix: identical to push_plan_to_dispatch. shelf_id is always v_shelf_id
-- (resolved from p_shelf_code via shelf_configurations, i.e. the shelf the
-- caller actually named). pod_inventory on that shelf supplies expiry_date
-- and pod_lot_id only. One row, full requested quantity, always. No lot on
-- that shelf: expiry_date NULL, EXPIRY-TO-CONFIRM comment, never a zeroed row.
--
-- Non-Remove branch (Refill/Add New) untouched. rpc_version bumped to
-- v3_prd125_p1_weimi_shelf_truth.
CREATE OR REPLACE FUNCTION public.add_dispatch_row(p_machine_id uuid, p_shelf_code text, p_boonz_product_id uuid, p_quantity numeric, p_action text, p_dispatch_date date, p_source_kind text DEFAULT 'unknown'::text, p_source_warehouse_id uuid DEFAULT NULL::uuid, p_source_machine_id uuid DEFAULT NULL::uuid, p_edit_role text DEFAULT NULL::text, p_reason text DEFAULT NULL::text, p_conductor_session text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role              text;
  v_shelf_id          uuid;
  v_pod_product_id    uuid;
  v_new_id            uuid;
  v_after             jsonb;
  v_src_name          text;
  v_bp_name           text;
  v_legs              jsonb := '[]'::jsonb;
  v_leg_after         jsonb;
  v_first_id          uuid;
  v_lot_expiry        date;
  v_lot_id            uuid;
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

  IF p_action <> 'Remove' THEN
    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action,
       quantity, packed, dispatched, picked_up, returned, item_added, include,
       source_kind, source_warehouse_id, source_machine_id, is_m2m, created_by_edit,
       from_warehouse_id,
       last_edited_by, last_edited_by_role, last_edited_at, edit_count)
    VALUES
      (p_machine_id, v_shelf_id, v_pod_product_id, p_boonz_product_id, p_dispatch_date, p_action,
       p_quantity, false, false, false, false, false, true,
       p_source_kind, p_source_warehouse_id, p_source_machine_id, (p_source_kind = 'truck_transfer' OR (p_source_kind = 'm2m' AND p_source_machine_id IS DISTINCT FROM p_machine_id)), true,
       CASE WHEN p_source_kind = 'wh' THEN p_source_warehouse_id ELSE NULL END,
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
  END IF;

  -- p_action = 'Remove': PRD-125 D2 -- shelf is the one the caller named
  -- (v_shelf_id), always. pod_inventory on that shelf supplies expiry_date
  -- and pod_lot_id only -- never a different shelf, never a different
  -- product, never split into multiple legs. When nothing Active sits on
  -- that shelf, the row still lands with the full requested quantity,
  -- expiry_date NULL, and EXPIRY-TO-CONFIRM (never a 0-qty NO-LOT-ON-SHELF
  -- row and never a cross-shelf "flavor-corrected" product swap -- those
  -- branches are deleted, same fix as push_plan_to_dispatch).
  SELECT pil.expiration_date, pil.pod_inventory_id
    INTO v_lot_expiry, v_lot_id
    FROM public.v_pod_inventory_latest pil
   WHERE pil.machine_id = p_machine_id
     AND pil.shelf_id = v_shelf_id
     AND pil.status = 'Active'
     AND COALESCE(pil.current_stock,0) > 0
   ORDER BY pil.expiration_date ASC NULLS LAST
   LIMIT 1;

  INSERT INTO public.refill_dispatching
    (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action,
     quantity, packed, dispatched, picked_up, returned, item_added, include, comment,
     source_kind, source_warehouse_id, source_machine_id, is_m2m, created_by_edit,
     from_warehouse_id, expiry_date, pod_lot_id,
     last_edited_by, last_edited_by_role, last_edited_at, edit_count)
  VALUES
    (p_machine_id, v_shelf_id, v_pod_product_id, p_boonz_product_id, p_dispatch_date, p_action,
     p_quantity, false, false, false, false, false, true,
     CASE WHEN v_lot_expiry IS NULL THEN '[EXPIRY-TO-CONFIRM — remainder not attributable to a known batch (PRD-053)]' ELSE NULL END,
     p_source_kind, p_source_warehouse_id, p_source_machine_id, (p_source_kind = 'truck_transfer' OR (p_source_kind = 'm2m' AND p_source_machine_id IS DISTINCT FROM p_machine_id)), true,
     CASE WHEN p_source_kind = 'wh' THEN p_source_warehouse_id ELSE NULL END, v_lot_expiry, v_lot_id,
     auth.uid(), p_edit_role, now(), 0)
  RETURNING dispatch_id INTO v_new_id;
  v_first_id := v_new_id;
  v_leg_after := jsonb_build_object(
    'dispatch_id', v_new_id, 'machine_id', p_machine_id, 'shelf_id', v_shelf_id,
    'boonz_product_id', p_boonz_product_id, 'pod_product_id', v_pod_product_id,
    'quantity', p_quantity, 'action', p_action, 'pod_lot_id', v_lot_id,
    'expiry_date', v_lot_expiry, 'flavor_corrected', false);
  v_legs := v_legs || jsonb_build_array(v_leg_after);
  INSERT INTO public.refill_dispatching_edit_log
    (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
  VALUES (v_new_id, auth.uid(), p_edit_role, 'add', NULL, v_leg_after, p_reason, p_conductor_session);

  RETURN jsonb_build_object(
    'dispatch_id', v_first_id, 'edit_kind','add', 'legs', v_legs,
    'remove_flavor_corrected', 0, 'remove_no_lot_on_shelf', 0,
    'rpc_version','v3_prd125_p1_weimi_shelf_truth');
END
$function$;
