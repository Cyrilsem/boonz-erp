-- PRD-130 step 01 (F1): add_dispatch_row v4. See supabase/rollback/prd130_00_rollback.sql for
-- the full R1-R7 root cause findings this migration and its siblings are based on.
--
-- R2 confirmed: v3 set is_m2m=true for source_kind='m2m' but never touched m2m_transfer_id,
-- m2m_partner_id, or source_origin -- an orphan leg, exactly the 21 Sep failure. R3 confirmed:
-- v3 took source_kind/source_warehouse_id from the caller as-is for Remove rows, so a Remove
-- meant as a transfer source still landed as a plain warehouse-return row.
--
-- Changes in v4:
--  * dispatched=true on every insert (matches the PRD's ask; per R1's finding this does not
--    change field-app visibility, which already runs on include+dispatch_date, but it does
--    match push_plan_to_dispatch's own M2M-source-leg behavior and removes one more manual flag
--    CS would otherwise have to set).
--  * source_origin set from source_kind: 'warehouse' for wh, 'internal_transfer' for m2m and
--    truck_transfer, 'unknown' otherwise. 'unknown' added to source_origin_enum below -- it did
--    not exist before this migration.
--  * p_source_kind='wh' and action in (Refill, Add New): FEFO-bind immediately via
--    wh_fefo_for_line(), the same STABLE helper push_plan_to_dispatch itself calls per line
--    (not bind_dispatch_fefo, which is a plan-wide sweep restricted to
--    warehouse/operator_admin/superadmin/manager callers and would reject a field_staff caller
--    of add_dispatch_row outright). If nothing binds, insert with bind_fail_reason='no_stock'
--    and do not raise.
--  * new optional p_partner_dispatch_id uuid, appended after the existing parameters (no
--    existing positional or named call site breaks). When source_kind='m2m' and a partner id is
--    given: the partner must be an unpacked, unreceived Remove on p_source_machine_id with the
--    same boonz_product_id (matching the identity key convert_removes_to_m2m_transfer and
--    is_internal_move_dispatch already use, not pod_product_id, which can legitimately differ
--    by machine slot naming for the same product); both legs get a shared m2m_transfer_id,
--    reciprocal m2m_partner_id, is_m2m=true, and the partner's source_kind flips to 'm2m' with
--    source_warehouse_id and from_warehouse_id cleared. When source_kind='m2m' and no partner is
--    given: raise. This is what stops an unpaired M2M leg from ever being created again.
--
-- Verified in a rolled-back transaction before applying: a plain Refill add (no m2m) still
-- inserts exactly as before plus dispatched=true/source_origin='warehouse'/FEFO bind; an
-- m2m add with no partner raises; an m2m add with a valid partner links both rows and returns
-- transfer_id + both dispatch ids; an m2m add with a partner that is already packed, already
-- item_added, or on the wrong machine raises with the specific reason.

DO $$ BEGIN
  ALTER TYPE public.source_origin_enum ADD VALUE IF NOT EXISTS 'unknown';
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE OR REPLACE FUNCTION public.add_dispatch_row(
  p_machine_id uuid,
  p_shelf_code text,
  p_boonz_product_id uuid,
  p_quantity numeric,
  p_action text,
  p_dispatch_date date,
  p_source_kind text DEFAULT 'unknown'::text,
  p_source_warehouse_id uuid DEFAULT NULL::uuid,
  p_source_machine_id uuid DEFAULT NULL::uuid,
  p_edit_role text DEFAULT NULL::text,
  p_reason text DEFAULT NULL::text,
  p_conductor_session text DEFAULT NULL::text,
  p_partner_dispatch_id uuid DEFAULT NULL::uuid
)
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
  v_source_origin     public.source_origin_enum;
  v_fefo_wh_id        uuid;
  v_fefo_expiry       date;
  v_bind_fail_reason  text;
  v_partner           refill_dispatching%ROWTYPE;
  v_transfer_id       uuid;
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
  IF p_source_kind = 'm2m' AND p_partner_dispatch_id IS NULL THEN
    RAISE EXCEPTION 'source_kind=m2m requires p_partner_dispatch_id. Create the Remove leg first (source_kind=wh or m2m with its own partner), then call add_dispatch_row again for the Add New leg with p_partner_dispatch_id set to that Remove''s dispatch_id. An unpaired m2m leg is exactly the row that broke 21 Sep (PRD-130 R2).';
  END IF;
  IF p_source_kind = 'm2m' AND p_source_machine_id = p_machine_id THEN
    RAISE EXCEPTION 'source_kind=m2m requires source and destination machines to differ. For a move within one machine, use add_intra_machine_move (PRD-130 F5), not add_dispatch_row.';
  END IF;

  v_source_origin := CASE p_source_kind
    WHEN 'wh' THEN 'warehouse'::public.source_origin_enum
    WHEN 'm2m' THEN 'internal_transfer'::public.source_origin_enum
    WHEN 'truck_transfer' THEN 'internal_transfer'::public.source_origin_enum
    ELSE 'unknown'::public.source_origin_enum
  END;

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

    SELECT * INTO v_partner FROM public.refill_dispatching WHERE dispatch_id = p_partner_dispatch_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'p_partner_dispatch_id % not found', p_partner_dispatch_id;
    END IF;
    IF v_partner.action <> 'Remove' THEN
      RAISE EXCEPTION 'Partner dispatch % must be action=Remove (got %)', p_partner_dispatch_id, v_partner.action;
    END IF;
    IF v_partner.machine_id <> p_source_machine_id THEN
      RAISE EXCEPTION 'Partner dispatch % is on machine %, not the declared source machine %', p_partner_dispatch_id, v_partner.machine_id, p_source_machine_id;
    END IF;
    IF v_partner.boonz_product_id <> p_boonz_product_id THEN
      RAISE EXCEPTION 'Partner dispatch % is boonz_product %, this row is %', p_partner_dispatch_id, v_partner.boonz_product_id, p_boonz_product_id;
    END IF;
    IF COALESCE(v_partner.packed, false) OR COALESCE(v_partner.item_added, false)
       OR COALESCE(v_partner.cancelled, false) OR COALESCE(v_partner.returned, false) THEN
      RAISE EXCEPTION 'Partner dispatch % is already packed, received, cancelled, or returned; cannot pair', p_partner_dispatch_id;
    END IF;
    IF v_partner.m2m_transfer_id IS NOT NULL THEN
      RAISE EXCEPTION 'Partner dispatch % already belongs to transfer %', p_partner_dispatch_id, v_partner.m2m_transfer_id;
    END IF;
    v_transfer_id := gen_random_uuid();
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
    v_fefo_wh_id := NULL;
    v_fefo_expiry := NULL;
    v_bind_fail_reason := NULL;
    IF p_source_kind = 'wh' AND p_action IN ('Refill','Add New') THEN
      SELECT f.wh_inventory_id, f.expiration_date
        INTO v_fefo_wh_id, v_fefo_expiry
      FROM public.wh_fefo_for_line(p_machine_id, p_boonz_product_id, p_dispatch_date, p_quantity, ARRAY[p_source_warehouse_id]) f
      WHERE f.is_satisfiable AND f.net_running >= p_quantity
      ORDER BY f.pick_rank
      LIMIT 1;
      IF v_fefo_wh_id IS NULL THEN
        v_bind_fail_reason := 'no_stock';
      END IF;
    END IF;

    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action,
       quantity, packed, dispatched, picked_up, returned, item_added, include,
       source_kind, source_warehouse_id, source_machine_id, is_m2m, created_by_edit,
       from_warehouse_id, from_wh_inventory_id, expiry_date, bind_fail_reason, bind_fail_at,
       source_origin, m2m_transfer_id, m2m_partner_id,
       last_edited_by, last_edited_by_role, last_edited_at, edit_count)
    VALUES
      (p_machine_id, v_shelf_id, v_pod_product_id, p_boonz_product_id, p_dispatch_date, p_action,
       p_quantity, false, true, false, false, false, true,
       p_source_kind, p_source_warehouse_id, p_source_machine_id,
       (p_source_kind = 'truck_transfer' OR p_source_kind = 'm2m'), true,
       CASE WHEN p_source_kind = 'wh' THEN p_source_warehouse_id ELSE NULL END,
       v_fefo_wh_id, v_fefo_expiry,
       v_bind_fail_reason, CASE WHEN v_bind_fail_reason IS NOT NULL THEN now() ELSE NULL END,
       v_source_origin,
       v_transfer_id, CASE WHEN p_source_kind = 'm2m' THEN p_partner_dispatch_id ELSE NULL END,
       auth.uid(), p_edit_role, now(), 0)
    RETURNING dispatch_id INTO v_new_id;

    IF p_source_kind = 'm2m' THEN
      -- refill_dispatching_source_consistency_chk requires source_machine_id NOT NULL when
      -- source_kind='m2m'. The partner Remove may have been created with source_kind='wh'
      -- (source_machine_id NULL) before anyone knew it would pair -- set it to the partner's
      -- own machine_id (the transfer's source machine), the same self-referential shape
      -- convert_removes_to_m2m_transfer already uses for its Remove leg.
      UPDATE public.refill_dispatching
         SET source_kind = 'm2m',
             is_m2m = true,
             m2m_transfer_id = v_transfer_id,
             m2m_partner_id = v_new_id,
             source_warehouse_id = NULL,
             from_warehouse_id = NULL,
             source_machine_id = v_partner.machine_id
       WHERE dispatch_id = p_partner_dispatch_id;
    END IF;

    v_after := jsonb_build_object(
      'dispatch_id', v_new_id, 'machine_id', p_machine_id, 'shelf_id', v_shelf_id,
      'boonz_product_id', p_boonz_product_id, 'pod_product_id', v_pod_product_id,
      'quantity', p_quantity, 'action', p_action, 'source_kind', p_source_kind,
      'source_warehouse_id', p_source_warehouse_id, 'source_machine_id', p_source_machine_id,
      'from_wh_inventory_id', v_fefo_wh_id, 'bind_fail_reason', v_bind_fail_reason,
      'm2m_transfer_id', v_transfer_id, 'm2m_partner_id', CASE WHEN p_source_kind = 'm2m' THEN p_partner_dispatch_id ELSE NULL END);

    INSERT INTO public.refill_dispatching_edit_log
      (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
    VALUES
      (v_new_id, auth.uid(), p_edit_role, 'add', NULL, v_after, p_reason, p_conductor_session);

    RETURN jsonb_build_object('dispatch_id', v_new_id, 'edit_kind','add', 'after', v_after,
      'transfer_id', v_transfer_id, 'partner_dispatch_id', CASE WHEN p_source_kind = 'm2m' THEN p_partner_dispatch_id ELSE NULL END,
      'rpc_version','v4_prd130_f1');
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
     from_warehouse_id, expiry_date, pod_lot_id, source_origin,
     last_edited_by, last_edited_by_role, last_edited_at, edit_count)
  VALUES
    (p_machine_id, v_shelf_id, v_pod_product_id, p_boonz_product_id, p_dispatch_date, p_action,
     p_quantity, false, true, false, false, false, true,
     CASE WHEN v_lot_expiry IS NULL THEN '[EXPIRY-TO-CONFIRM — remainder not attributable to a known batch (PRD-053)]' ELSE NULL END,
     p_source_kind, p_source_warehouse_id, p_source_machine_id,
     (p_source_kind = 'truck_transfer' OR p_source_kind = 'm2m'), true,
     CASE WHEN p_source_kind = 'wh' THEN p_source_warehouse_id ELSE NULL END, v_lot_expiry, v_lot_id,
     v_source_origin,
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
    'rpc_version','v4_prd130_f1');
END
$function$;
