-- Rollback for PRD-137 F5 (add_m2m_transfer role allowlist). Restores the pre-change body
-- (field_staff excluded). Byte-exact against live as of 2026-09-30, verified before drafting.
CREATE OR REPLACE FUNCTION public.add_m2m_transfer(p_source_machine_id uuid, p_source_shelf_code text, p_dest_machine_id uuid, p_dest_shelf_code text, p_boonz_product_id uuid, p_quantity numeric, p_dispatch_date date, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role              text;
  v_src_shelf_id      uuid;
  v_dest_shelf_id     uuid;
  v_src_pod_product   uuid;
  v_dest_pod_product  uuid;
  v_lot_expiry        date;
  v_lot_id            uuid;
  v_transfer_id       uuid := gen_random_uuid();
  v_remove_id         uuid;
  v_add_id            uuid;
  v_slot              record;
  v_staged_remove     boolean;
  v_src_name          text;
  v_dest_name         text;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','add_m2m_transfer',true);

  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NOT NULL AND v_role NOT IN ('operator_admin','superadmin','manager','warehouse') THEN
    RAISE EXCEPTION 'forbidden: add_m2m_transfer requires operator_admin / superadmin / manager / warehouse';
  END IF;

  IF p_source_machine_id IS NULL OR p_dest_machine_id IS NULL OR p_boonz_product_id IS NULL
     OR p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'p_source_machine_id, p_dest_machine_id, p_boonz_product_id, p_quantity (>0) required';
  END IF;
  IF p_source_machine_id = p_dest_machine_id THEN
    RAISE EXCEPTION 'source and destination machines must differ. For a move within one machine, use add_intra_machine_move (PRD-130 F5).';
  END IF;

  SELECT official_name INTO v_src_name FROM public.machines WHERE machine_id = p_source_machine_id;
  SELECT official_name INTO v_dest_name FROM public.machines WHERE machine_id = p_dest_machine_id;
  IF v_src_name IS NULL THEN RAISE EXCEPTION 'source machine % not found', p_source_machine_id; END IF;
  IF v_dest_name IS NULL THEN RAISE EXCEPTION 'dest machine % not found', p_dest_machine_id; END IF;

  SELECT shelf_id INTO v_src_shelf_id FROM public.shelf_configurations
   WHERE machine_id = p_source_machine_id AND shelf_code = p_source_shelf_code;
  IF v_src_shelf_id IS NULL THEN RAISE EXCEPTION 'source shelf_code % not found on %', p_source_shelf_code, v_src_name; END IF;

  SELECT shelf_id INTO v_dest_shelf_id FROM public.shelf_configurations
   WHERE machine_id = p_dest_machine_id AND shelf_code = p_dest_shelf_code;
  IF v_dest_shelf_id IS NULL THEN RAISE EXCEPTION 'dest shelf_code % not found on %', p_dest_shelf_code, v_dest_name; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.pod_inventory
    WHERE machine_id = p_source_machine_id AND boonz_product_id = p_boonz_product_id
      AND status = 'Active' AND current_stock > 0
  ) THEN
    RAISE EXCEPTION 'Source machine % does not carry an Active lot of boonz_product % (current_stock > 0)', v_src_name, p_boonz_product_id;
  END IF;

  SELECT sl.pod_product_id INTO v_src_pod_product
  FROM public.slot_lifecycle sl
  WHERE sl.machine_id = p_source_machine_id AND sl.shelf_id = v_src_shelf_id
    AND sl.is_current = true AND sl.archived = false
    AND EXISTS (SELECT 1 FROM public.product_mapping pm WHERE pm.pod_product_id = sl.pod_product_id
                  AND pm.boonz_product_id = p_boonz_product_id AND pm.status = 'Active')
  ORDER BY sl.rotated_in_at DESC NULLS LAST LIMIT 1;
  IF v_src_pod_product IS NULL THEN
    SELECT pm.pod_product_id INTO v_src_pod_product FROM public.product_mapping pm
    WHERE pm.boonz_product_id = p_boonz_product_id AND pm.status = 'Active'
      AND (pm.machine_id = p_source_machine_id OR pm.machine_id IS NULL)
    ORDER BY (pm.machine_id = p_source_machine_id) DESC NULLS LAST, pm.is_global_default DESC LIMIT 1;
  END IF;
  IF v_src_pod_product IS NULL THEN
    RAISE EXCEPTION 'no Active product_mapping for boonz_product % on source machine %', p_boonz_product_id, v_src_name;
  END IF;

  SELECT sl.pod_product_id INTO v_dest_pod_product
  FROM public.slot_lifecycle sl
  WHERE sl.machine_id = p_dest_machine_id AND sl.shelf_id = v_dest_shelf_id
    AND sl.is_current = true AND sl.archived = false
    AND EXISTS (SELECT 1 FROM public.product_mapping pm WHERE pm.pod_product_id = sl.pod_product_id
                  AND pm.boonz_product_id = p_boonz_product_id AND pm.status = 'Active')
  ORDER BY sl.rotated_in_at DESC NULLS LAST LIMIT 1;
  IF v_dest_pod_product IS NULL THEN
    SELECT pm.pod_product_id INTO v_dest_pod_product FROM public.product_mapping pm
    WHERE pm.boonz_product_id = p_boonz_product_id AND pm.status = 'Active'
      AND (pm.machine_id = p_dest_machine_id OR pm.machine_id IS NULL)
    ORDER BY (pm.machine_id = p_dest_machine_id) DESC NULLS LAST, pm.is_global_default DESC LIMIT 1;
  END IF;
  IF v_dest_pod_product IS NULL THEN
    RAISE EXCEPTION 'no Active product_mapping for boonz_product % on dest machine %', p_boonz_product_id, v_dest_name;
  END IF;

  SELECT ssi.pod_product_id, ssi.pod_product_name, ssi.match_method
    INTO v_slot
  FROM public.v_shelf_slot_identity ssi
  WHERE ssi.machine_id = p_dest_machine_id AND ssi.shelf_id = v_dest_shelf_id;

  IF v_slot.pod_product_id IS NOT NULL AND v_slot.match_method <> 'unmatched'
     AND v_slot.pod_product_id IS DISTINCT FROM v_dest_pod_product THEN
    SELECT EXISTS (
      SELECT 1 FROM public.refill_dispatching rd
      WHERE rd.machine_id = p_dest_machine_id AND rd.shelf_id = v_dest_shelf_id
        AND rd.dispatch_date = p_dispatch_date AND rd.action = 'Remove'
        AND rd.pod_product_id = v_slot.pod_product_id
        AND COALESCE(rd.cancelled,false) = false AND COALESCE(rd.item_added,false) = false
    ) INTO v_staged_remove;
    IF NOT v_staged_remove THEN
      RAISE EXCEPTION 'WEIMI slot guard: destination shelf % on % currently reads % (pod_product %), not the product being transferred. Add a Remove for the current product first, or pick a different destination shelf.',
        p_dest_shelf_code, v_dest_name, v_slot.pod_product_name, v_slot.pod_product_id;
    END IF;
  END IF;

  -- Loop 2026-09-25 A4: filter to p_boonz_product_id, the product actually being transferred, so
  -- a shelf holding several Active lots (a flavour changeover, or several SKUs on one lane) can no
  -- longer bind a different flavour's soonest-expiring lot onto this transfer. No matching lot on
  -- the shelf for this product now falls back to NULL, never to another flavour's lot.
  SELECT pil.expiration_date, pil.pod_inventory_id
    INTO v_lot_expiry, v_lot_id
    FROM public.v_pod_inventory_latest pil
   WHERE pil.machine_id = p_source_machine_id
     AND pil.shelf_id = v_src_shelf_id
     AND pil.boonz_product_id = p_boonz_product_id
     AND pil.status = 'Active'
     AND COALESCE(pil.current_stock,0) > 0
   ORDER BY pil.expiration_date ASC NULLS LAST
   LIMIT 1;

  INSERT INTO public.refill_dispatching
    (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action, quantity,
     packed, dispatched, picked_up, returned, item_added, include, comment,
     source_kind, source_machine_id, is_m2m, m2m_transfer_id, created_by_edit,
     expiry_date, pod_lot_id, pack_outcome, source_origin,
     last_edited_by, last_edited_by_role, last_edited_at, edit_count)
  VALUES
    (p_source_machine_id, v_src_shelf_id, v_src_pod_product, p_boonz_product_id, p_dispatch_date, 'Remove', p_quantity,
     true, true, true, false, false, true,
     format('M2M: %s -> %s%s', v_src_name, v_dest_name, CASE WHEN p_reason IS NOT NULL THEN ' ('||p_reason||')' ELSE '' END),
     'm2m', p_source_machine_id, true, v_transfer_id, true,
     v_lot_expiry, v_lot_id, 'no_pack_needed'::public.pack_outcome_enum, 'internal_transfer'::public.source_origin_enum,
     auth.uid(), NULL, now(), 0)
  RETURNING dispatch_id INTO v_remove_id;

  INSERT INTO public.refill_dispatching
    (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action, quantity,
     packed, dispatched, picked_up, returned, item_added, include, comment,
     source_kind, source_machine_id, is_m2m, m2m_transfer_id, m2m_partner_id, created_by_edit,
     pack_outcome, source_origin,
     last_edited_by, last_edited_by_role, last_edited_at, edit_count)
  VALUES
    (p_dest_machine_id, v_dest_shelf_id, v_dest_pod_product, p_boonz_product_id, p_dispatch_date, 'Add New', p_quantity,
     true, true, false, false, false, true,
     format('M2M: %s -> %s%s', v_src_name, v_dest_name, CASE WHEN p_reason IS NOT NULL THEN ' ('||p_reason||')' ELSE '' END),
     'm2m', p_source_machine_id, true, v_transfer_id, v_remove_id, true,
     'no_pack_needed'::public.pack_outcome_enum, 'internal_transfer'::public.source_origin_enum,
     auth.uid(), NULL, now(), 0)
  RETURNING dispatch_id INTO v_add_id;

  UPDATE public.refill_dispatching SET m2m_partner_id = v_add_id WHERE dispatch_id = v_remove_id;

  -- Loop 2026-09-25 A4 (incidental fix, same function already being replaced above): the prior
  -- body hardcoded edited_by_role to a literal NULL here regardless of v_role, which violates
  -- refill_dispatching_edit_log.edited_by_role's NOT NULL constraint on every call, authenticated
  -- or not -- confirmed live while smoke testing this migration (23502 on the first attempt).
  -- Same COALESCE(v_role,'system') fallback already used by cancel_m2m_transfer (A1).
  INSERT INTO public.refill_dispatching_edit_log
    (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason)
  VALUES
    (v_remove_id, auth.uid(), COALESCE(v_role, 'system'), 'add', NULL,
     jsonb_build_object('dispatch_id', v_remove_id, 'action', 'Remove', 'transfer_id', v_transfer_id, 'partner', v_add_id), p_reason),
    (v_add_id, auth.uid(), COALESCE(v_role, 'system'), 'add', NULL,
     jsonb_build_object('dispatch_id', v_add_id, 'action', 'Add New', 'transfer_id', v_transfer_id, 'partner', v_remove_id), p_reason);

  RETURN jsonb_build_object(
    'status', 'ok', 'transfer_id', v_transfer_id,
    'remove_dispatch_id', v_remove_id, 'add_dispatch_id', v_add_id,
    'source_machine', v_src_name, 'dest_machine', v_dest_name,
    'quantity', p_quantity, 'boonz_product_id', p_boonz_product_id
  );
END;
$function$;
