-- PRD-130 step 05 (F5): intra-machine move.
--
-- R6 finding (see supabase/rollback/prd130_00_rollback.sql for the full note): a working
-- detection-and-credit-block mechanism for same-machine cross-shelf moves already exists
-- (is_internal_move_dispatch / tg_mark_internal_move_pair / tg_block_internal_move_credit,
-- PRD-113) -- it auto-flags a Remove and an Add New of the same boonz_product_id on different
-- shelves of the same machine and blocks warehouse credit on receipt for either leg, for every
-- writer. What genuinely does not exist is a dedicated RPC that creates both legs correctly in
-- one call, a source_kind to mark the intent explicitly, and a field-app label. This migration
-- adds those three; it does not replace the PRD-113 mechanism, which will also independently
-- flag these same rows (is_internal_move=true) as a second, redundant layer of protection.
--
-- On "receipt": receive_dispatch_line's existing generic logic already does the move once both
-- legs are received normally through it -- the Remove branch deactivates pod_inventory on the
-- FROM shelf (status='Inactive') regardless of source_kind, and the Add New branch upserts
-- pod_inventory on the TO shelf regardless of source_kind, for every action of that shape today.
-- No new "on item_added" trigger is added here to duplicate that -- it would be redundant with
-- what already runs. What receive_dispatch_line does NOT yet do is explicitly refuse warehouse
-- credit for source_kind='intra_machine' the same way it already does for is_m2m -- that
-- explicit check is added in prd130_03 (after 22:00 Dubai), as a second layer alongside the
-- pre-existing is_internal_move_dispatch guard.
--
-- The WEIMI slot guard is run here, at creation time (inline equivalent against
-- v_shelf_slot_identity, same as add_m2m_transfer -- assert_weimi_slot_match only reads
-- refill_plan_output, which this move has no row in), not at receipt time -- catching a bad
-- destination lane before the row exists is strictly better than catching it after.

ALTER TABLE public.refill_dispatching DROP CONSTRAINT IF EXISTS refill_dispatching_source_consistency_chk;
ALTER TABLE public.refill_dispatching ADD CONSTRAINT refill_dispatching_source_consistency_chk CHECK (
  (source_kind = 'wh' AND source_warehouse_id IS NOT NULL AND source_machine_id IS NULL)
  OR (source_kind = 'venue' AND source_warehouse_id IS NULL AND source_machine_id IS NULL)
  OR (source_kind = 'm2m' AND source_machine_id IS NOT NULL AND source_warehouse_id IS NULL)
  OR (source_kind = 'truck_transfer' AND source_machine_id IS NOT NULL AND source_warehouse_id IS NULL)
  OR (source_kind = 'intra_machine' AND source_machine_id IS NOT NULL AND source_warehouse_id IS NULL)
  OR (source_kind = 'unknown' AND source_warehouse_id IS NULL AND source_machine_id IS NULL)
) NOT VALID;

CREATE OR REPLACE FUNCTION public.add_intra_machine_move(
  p_machine_id uuid,
  p_from_shelf_code text,
  p_to_shelf_code text,
  p_boonz_product_id uuid,
  p_quantity numeric,
  p_dispatch_date date,
  p_reason text DEFAULT NULL::text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role              text;
  v_from_shelf_id     uuid;
  v_to_shelf_id       uuid;
  v_from_pod_product  uuid;
  v_to_pod_product    uuid;
  v_lot_expiry        date;
  v_lot_id            uuid;
  v_transfer_id       uuid := gen_random_uuid();
  v_remove_id         uuid;
  v_add_id            uuid;
  v_slot              record;
  v_staged_remove     boolean;
  v_machine_name      text;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','add_intra_machine_move',true);

  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NOT NULL AND v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'forbidden: add_intra_machine_move requires field_staff / warehouse / operator_admin';
  END IF;

  IF p_machine_id IS NULL OR p_boonz_product_id IS NULL OR p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'p_machine_id, p_boonz_product_id, p_quantity (>0) required';
  END IF;
  IF p_from_shelf_code = p_to_shelf_code THEN
    RAISE EXCEPTION 'p_from_shelf_code and p_to_shelf_code must differ';
  END IF;

  SELECT official_name INTO v_machine_name FROM public.machines WHERE machine_id = p_machine_id;
  IF v_machine_name IS NULL THEN RAISE EXCEPTION 'machine % not found', p_machine_id; END IF;

  SELECT shelf_id INTO v_from_shelf_id FROM public.shelf_configurations
   WHERE machine_id = p_machine_id AND shelf_code = p_from_shelf_code;
  IF v_from_shelf_id IS NULL THEN RAISE EXCEPTION 'from shelf_code % not found on %', p_from_shelf_code, v_machine_name; END IF;

  SELECT shelf_id INTO v_to_shelf_id FROM public.shelf_configurations
   WHERE machine_id = p_machine_id AND shelf_code = p_to_shelf_code;
  IF v_to_shelf_id IS NULL THEN RAISE EXCEPTION 'to shelf_code % not found on %', p_to_shelf_code, v_machine_name; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.pod_inventory
    WHERE machine_id = p_machine_id AND shelf_id = v_from_shelf_id AND boonz_product_id = p_boonz_product_id
      AND status = 'Active' AND current_stock > 0
  ) THEN
    RAISE EXCEPTION 'Shelf % on % does not carry an Active lot of boonz_product % (current_stock > 0)', p_from_shelf_code, v_machine_name, p_boonz_product_id;
  END IF;

  SELECT sl.pod_product_id INTO v_from_pod_product
  FROM public.slot_lifecycle sl
  WHERE sl.machine_id = p_machine_id AND sl.shelf_id = v_from_shelf_id
    AND sl.is_current = true AND sl.archived = false
    AND EXISTS (SELECT 1 FROM public.product_mapping pm WHERE pm.pod_product_id = sl.pod_product_id
                  AND pm.boonz_product_id = p_boonz_product_id AND pm.status = 'Active')
  ORDER BY sl.rotated_in_at DESC NULLS LAST LIMIT 1;
  IF v_from_pod_product IS NULL THEN
    SELECT pm.pod_product_id INTO v_from_pod_product FROM public.product_mapping pm
    WHERE pm.boonz_product_id = p_boonz_product_id AND pm.status = 'Active'
      AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)
    ORDER BY (pm.machine_id = p_machine_id) DESC NULLS LAST, pm.is_global_default DESC LIMIT 1;
  END IF;
  IF v_from_pod_product IS NULL THEN
    RAISE EXCEPTION 'no Active product_mapping for boonz_product % on machine %', p_boonz_product_id, v_machine_name;
  END IF;
  v_to_pod_product := v_from_pod_product;

  SELECT ssi.pod_product_id, ssi.pod_product_name, ssi.match_method
    INTO v_slot
  FROM public.v_shelf_slot_identity ssi
  WHERE ssi.machine_id = p_machine_id AND ssi.shelf_id = v_to_shelf_id;

  IF v_slot.pod_product_id IS NOT NULL AND v_slot.match_method <> 'unmatched'
     AND v_slot.pod_product_id IS DISTINCT FROM v_to_pod_product THEN
    SELECT EXISTS (
      SELECT 1 FROM public.refill_dispatching rd
      WHERE rd.machine_id = p_machine_id AND rd.shelf_id = v_to_shelf_id
        AND rd.dispatch_date = p_dispatch_date AND rd.action = 'Remove'
        AND rd.pod_product_id = v_slot.pod_product_id
        AND COALESCE(rd.cancelled,false) = false AND COALESCE(rd.item_added,false) = false
    ) INTO v_staged_remove;
    IF NOT v_staged_remove THEN
      RAISE EXCEPTION 'WEIMI slot guard: destination shelf % on % currently reads % (pod_product %), not the product being moved. Add a Remove for the current product first, or pick a different destination shelf.',
        p_to_shelf_code, v_machine_name, v_slot.pod_product_name, v_slot.pod_product_id;
    END IF;
  END IF;

  SELECT pil.expiration_date, pil.pod_inventory_id
    INTO v_lot_expiry, v_lot_id
    FROM public.v_pod_inventory_latest pil
   WHERE pil.machine_id = p_machine_id
     AND pil.shelf_id = v_from_shelf_id
     AND pil.status = 'Active'
     AND COALESCE(pil.current_stock,0) > 0
   ORDER BY pil.expiration_date ASC NULLS LAST
   LIMIT 1;

  INSERT INTO public.refill_dispatching
    (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action, quantity,
     packed, dispatched, picked_up, returned, item_added, include, comment,
     source_kind, source_machine_id, m2m_transfer_id, created_by_edit,
     expiry_date, pod_lot_id, pack_outcome,
     last_edited_by, last_edited_by_role, last_edited_at, edit_count)
  VALUES
    (p_machine_id, v_from_shelf_id, v_from_pod_product, p_boonz_product_id, p_dispatch_date, 'Remove', p_quantity,
     true, true, true, false, false, true,
     format('Move %s to %s%s', p_from_shelf_code, p_to_shelf_code, CASE WHEN p_reason IS NOT NULL THEN ' ('||p_reason||')' ELSE '' END),
     'intra_machine', p_machine_id, v_transfer_id, true,
     v_lot_expiry, v_lot_id, 'no_pack_needed'::public.pack_outcome_enum,
     auth.uid(), NULL, now(), 0)
  RETURNING dispatch_id INTO v_remove_id;

  INSERT INTO public.refill_dispatching
    (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action, quantity,
     packed, dispatched, picked_up, returned, item_added, include, comment,
     source_kind, source_machine_id, m2m_transfer_id, m2m_partner_id, created_by_edit,
     pack_outcome,
     last_edited_by, last_edited_by_role, last_edited_at, edit_count)
  VALUES
    (p_machine_id, v_to_shelf_id, v_to_pod_product, p_boonz_product_id, p_dispatch_date, 'Add New', p_quantity,
     true, true, false, false, false, true,
     format('Move %s to %s%s', p_from_shelf_code, p_to_shelf_code, CASE WHEN p_reason IS NOT NULL THEN ' ('||p_reason||')' ELSE '' END),
     'intra_machine', p_machine_id, v_transfer_id, v_remove_id, true,
     'no_pack_needed'::public.pack_outcome_enum,
     auth.uid(), NULL, now(), 0)
  RETURNING dispatch_id INTO v_add_id;

  UPDATE public.refill_dispatching SET m2m_partner_id = v_add_id WHERE dispatch_id = v_remove_id;

  INSERT INTO public.refill_dispatching_edit_log
    (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason)
  VALUES
    (v_remove_id, auth.uid(), NULL, 'add', NULL,
     jsonb_build_object('dispatch_id', v_remove_id, 'action', 'Remove', 'transfer_id', v_transfer_id, 'partner', v_add_id), p_reason),
    (v_add_id, auth.uid(), NULL, 'add', NULL,
     jsonb_build_object('dispatch_id', v_add_id, 'action', 'Add New', 'transfer_id', v_transfer_id, 'partner', v_remove_id), p_reason);

  RETURN jsonb_build_object(
    'status', 'ok', 'transfer_id', v_transfer_id,
    'remove_dispatch_id', v_remove_id, 'add_dispatch_id', v_add_id,
    'machine', v_machine_name, 'from_shelf', p_from_shelf_code, 'to_shelf', p_to_shelf_code,
    'quantity', p_quantity, 'boonz_product_id', p_boonz_product_id
  );
END;
$function$;
