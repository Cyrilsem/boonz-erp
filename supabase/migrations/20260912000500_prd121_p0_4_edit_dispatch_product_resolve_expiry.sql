-- PRD-121 P0.4: expiry stays populated and editable after Change Product.
--
-- edit_dispatch_product (the pre-pack "operator/driver editing before packing" tool,
-- wired via DispatchEditDialog.tsx on the packing page) swaps boonz_product_id and
-- pod_product_id but never touches expiry_date or from_wh_inventory_id. Both are then
-- left holding the OLD product's values while boonz_product_id points at the NEW one --
-- a real cross-product mismatch, not just a cosmetic stale value. Two concrete
-- consequences found while verifying this:
--
--   1. The packing page (src/app/(field)/field/packing/[machineId]/page.tsx) reads
--      line.expiry_date straight off the row for display/edit -- after a product change
--      it shows the OLD product's expiry as if it belonged to the NEW product.
--   2. rebind_stale_dispatch_pins' "still good, no-op" check (PRD-120 G6) validates the
--      PINNED BATCH's status/stock/expiry floor but never checks that the batch's own
--      boonz_product_id still matches the dispatch row's (possibly just-changed)
--      boonz_product_id -- so a stale cross-product pin can pass as "still good" and
--      never get corrected.
--
-- Fix: when the product actually changes, resolve a real batch for the NEW product using
-- the SAME picker substitute_dispatch_line already uses (pick_wh_batch_for_machine,
-- scoped to the machine's serving warehouses) -- Article 16, one canonical FEFO picker,
-- not a third divergent one -- and set expiry_date/from_wh_inventory_id to that real
-- batch. When nothing resolves, clear both to NULL (never leave the OLD, now-wrong
-- pair) and set bind_fail_reason='no_stock' using the SAME column pack_dispatch_line and
-- rebind_stale_dispatch_pins already use for exactly this purpose, so the pack screen
-- surfaces a real, honest shortage instead of a silently mismatched batch. This keeps
-- expiry genuinely populated (a real batch, when one exists) and leaves it in the normal
-- editable state (NULL + bind_fail_reason) the pack screen already knows how to handle
-- when one doesn't.
--
-- Cody: approve. Articles 1 (still the sole writer of this edit, no new write path), 4
-- (role/reason guards unchanged), 8 (existing edit log entry unchanged), 12 (forward-only
-- CREATE OR REPLACE, same signature, md5-guarded), 16 (reuses pick_wh_batch_for_machine
-- exactly as substitute_dispatch_line does, rather than a third FEFO implementation).

DO $mig$ DECLARE v_def text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p WHERE p.proname='edit_dispatch_product' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '8fe926b89cffad6fdf3305402eac94d5' THEN
    RAISE EXCEPTION 'edit_dispatch_product drifted (md5 %), refusing blind replace', md5(v_def);
  END IF;
END $mig$;

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
  v_primary_wh   uuid;
  v_secondary_wh uuid;
  v_pick         record;
  v_new_wh_inv   uuid := NULL;
  v_new_expiry   date := NULL;
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

  -- PRD-121 P0.4: resolve a real batch for the NEW product before writing anything, so
  -- expiry_date/from_wh_inventory_id never carry the OLD product's values forward.
  IF p_new_boonz_product_id IS DISTINCT FROM v_row.boonz_product_id THEN
    SELECT m.primary_warehouse_id, m.secondary_warehouse_id
      INTO v_primary_wh, v_secondary_wh
    FROM public.machines m WHERE m.machine_id = v_row.machine_id;

    SELECT p.wh_inventory_id, p.expiration_date INTO v_pick
    FROM public.pick_wh_batch_for_machine(p_new_boonz_product_id, v_row.machine_id, v_row.quantity, NULL) p
    JOIN public.warehouse_inventory wi2 ON wi2.wh_inventory_id = p.wh_inventory_id
    WHERE wi2.warehouse_id = ANY (ARRAY[v_primary_wh, v_secondary_wh])
    ORDER BY p.pick_rank LIMIT 1;

    IF v_pick IS NOT NULL THEN
      v_new_wh_inv := v_pick.wh_inventory_id;
      v_new_expiry := v_pick.expiration_date;
    END IF;
  ELSE
    v_new_wh_inv := v_row.from_wh_inventory_id;
    v_new_expiry := v_row.expiry_date;
  END IF;

  v_before := jsonb_build_object('boonz_product_id', v_row.boonz_product_id,
                                 'pod_product_id',   v_row.pod_product_id,
                                 'expiry_date',      v_row.expiry_date,
                                 'from_wh_inventory_id', v_row.from_wh_inventory_id);

  UPDATE public.refill_dispatching
  SET boonz_product_id          = p_new_boonz_product_id,
      pod_product_id            = v_new_pod,
      expiry_date               = v_new_expiry,
      from_wh_inventory_id      = v_new_wh_inv,
      bind_fail_reason          = CASE WHEN p_new_boonz_product_id IS DISTINCT FROM v_row.boonz_product_id AND v_new_wh_inv IS NULL THEN 'no_stock' ELSE NULL END,
      bind_fail_at              = CASE WHEN p_new_boonz_product_id IS DISTINCT FROM v_row.boonz_product_id AND v_new_wh_inv IS NULL THEN now() ELSE NULL END,
      original_boonz_product_id = COALESCE(original_boonz_product_id, v_row.boonz_product_id),
      edit_count                = edit_count + 1,
      last_edited_by            = auth.uid(),
      last_edited_by_role       = p_edit_role,
      last_edited_at            = now()
  WHERE dispatch_id = p_dispatch_id;

  v_after := jsonb_build_object('boonz_product_id', p_new_boonz_product_id,
                                'pod_product_id',   v_new_pod,
                                'expiry_date',      v_new_expiry,
                                'from_wh_inventory_id', v_new_wh_inv);

  INSERT INTO public.refill_dispatching_edit_log
    (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
  VALUES
    (p_dispatch_id, auth.uid(), p_edit_role, 'product', v_before, v_after, p_reason, p_conductor_session);

  RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'edit_kind','product',
                            'before', v_before, 'after', v_after);
END $function$;
