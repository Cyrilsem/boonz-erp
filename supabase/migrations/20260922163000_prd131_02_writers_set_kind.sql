-- PRD-131 F2: every writer that can insert a refill_dispatching row sets movement_kind
-- explicitly, plus tg_movement_kind_required and reclassify_dispatch_movement.
--
-- NOT APPLIED YET. Gated: depends on the movement_kind column (F1, also gated), and directly
-- touches wm_confirm_line_split's caller surface... actually wm_confirm_line_split itself does
-- NOT insert into refill_dispatching (verified: only warehouse_inventory and disposition_events),
-- so it needs no change here -- but it IS named explicitly in the window rule
-- ("wm_confirm_line*"), so this whole migration stays gated to after 22:00 Dubai regardless,
-- since it also touches push_plan_to_dispatch which the field app and packing screen both
-- depend on for same-day data shape.
--
-- Writers covered and their movement_kind assignment:
--   add_dispatch_row (v4): non-Remove + source_kind in (m2m,truck_transfer) -> transfer_in;
--     non-Remove + source_kind in (wh,unknown) -> warehouse_fill; Remove + source_kind in
--     (m2m,truck_transfer) -> transfer_out; Remove + else -> warehouse_return. The m2m partner
--     UPDATE (pairing an existing Remove leg) also sets movement_kind='transfer_out' on the
--     partner.
--   add_m2m_transfer: Remove leg -> transfer_out, Add New leg -> transfer_in (always source_kind='m2m').
--   add_intra_machine_move: Remove leg -> intra_out, Add New leg -> intra_in (always source_kind='intra_machine').
--   insert_driver_remove_line: m2m-split source -> transfer_out, m2m-split dest -> transfer_in,
--     plain remove (parent not m2m) -> warehouse_return.
--   convert_removes_to_m2m_transfer: new Add New leg -> transfer_in; the retroactive UPDATE on
--     the source Remove rows now also sets movement_kind='transfer_out' explicitly (this RPC is
--     itself the privileged retroactive-reclassification tool for this one case, operator_admin
--     gated already -- it does not need to additionally call reclassify_dispatch_movement).
--   pair_internal_transfer_m2m (supersedes prd130_06's body): both pairing UPDATEs now also set
--     movement_kind (transfer_in on the dest leg, transfer_out on the src leg), idempotently --
--     harmless if the writer already set it correctly at creation.
--   push_plan_to_dispatch: M2M source Remove leg -> transfer_out; M2M dest per-group leg ->
--     transfer_in; plain Remove/M2W leg -> warehouse_return (and the v_action CASE mapping for
--     plan action 'MACHINE TO WAREHOUSE' now produces 'Remove', not 'Machine To Warehouse' --
--     action is derived/compatibility per F1, movement_kind carries the real meaning, and
--     'Machine To Warehouse' is retired); general upsert leg (Refill/Add New, non-m2m) ->
--     warehouse_fill (vox_at_venue lines included -- no dedicated PRD-131 kind exists for
--     venue-sourced fills, and pack_dispatch_line already treats them as a pick-and-pack flow
--     via the 2099 placeholder-batch guard, so warehouse_fill is the closest fit; flagged as a
--     judgment call, not explicit in the PRD).
--
-- wm_confirm_line_split: no INSERT into refill_dispatching, no change needed for F2's purpose.
-- Its F5 changes (kind-based receipt screen, lots table) are a separate migration.

CREATE OR REPLACE FUNCTION public.tg_movement_kind_required()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.movement_kind IS NULL THEN
      RAISE EXCEPTION 'tg_movement_kind_required: movement_kind is required on insert into refill_dispatching';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.movement_kind IS DISTINCT FROM OLD.movement_kind THEN
    IF COALESCE(current_setting('app.rpc_name', true), '') <> 'reclassify_dispatch_movement' THEN
      IF COALESCE(OLD.packed, false) = true OR OLD.driver_confirmed_at IS NOT NULL THEN
        RAISE EXCEPTION 'tg_movement_kind_required: movement_kind cannot change on dispatch % after packed=true or driver_confirmed_at is set, except via reclassify_dispatch_movement', OLD.dispatch_id;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS tg_movement_kind_required ON public.refill_dispatching;
CREATE TRIGGER tg_movement_kind_required
  BEFORE INSERT OR UPDATE ON public.refill_dispatching
  FOR EACH ROW EXECUTE FUNCTION public.tg_movement_kind_required();

CREATE OR REPLACE FUNCTION public.reclassify_dispatch_movement(
  p_dispatch_id uuid,
  p_new_kind text,
  p_reason text,
  p_caller_id uuid DEFAULT NULL::uuid
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller_id, auth.uid());
  v_role    text;
  v_row     refill_dispatching%ROWTYPE;
  v_before  jsonb;
BEGIN
  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
    IF v_role IS NULL OR v_role <> 'operator_admin' THEN
      RAISE EXCEPTION 'reclassify_dispatch_movement: requires operator_admin (got %)', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  IF p_new_kind NOT IN ('warehouse_fill','warehouse_return','transfer_out','transfer_in','intra_out','intra_in','write_off','legacy_noop') THEN
    RAISE EXCEPTION 'reclassify_dispatch_movement: invalid p_new_kind %', p_new_kind;
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'reclassify_dispatch_movement: p_reason must be at least 10 characters';
  END IF;

  SELECT * INTO v_row FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'reclassify_dispatch_movement: dispatch % not found', p_dispatch_id;
  END IF;
  IF v_row.wh_approved_at IS NOT NULL OR COALESCE(v_row.item_added, false) = true THEN
    RAISE EXCEPTION 'reclassify_dispatch_movement: dispatch % already has a warehouse credit (wh_approved_at=%, item_added=%) -- cannot reclassify a settled line',
      p_dispatch_id, v_row.wh_approved_at, v_row.item_added;
  END IF;

  v_before := jsonb_build_object('movement_kind', v_row.movement_kind);

  PERFORM set_config('app.via_rpc','true', true);
  PERFORM set_config('app.rpc_name','reclassify_dispatch_movement', true);
  PERFORM set_config('app.mutation_reason',
    format('PRD-131 reclassify dispatch %s: %s -> %s by=%s: %s', p_dispatch_id, v_row.movement_kind, p_new_kind, v_user_id, p_reason), true);

  UPDATE public.refill_dispatching
     SET movement_kind = p_new_kind
   WHERE dispatch_id = p_dispatch_id;

  INSERT INTO public.refill_dispatching_edit_log
    (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason)
  VALUES
    (p_dispatch_id, v_user_id, v_role, 'reclassify_movement_kind', v_before,
     jsonb_build_object('movement_kind', p_new_kind), p_reason);

  RETURN jsonb_build_object('status','ok','dispatch_id',p_dispatch_id,'old_kind',v_before->>'movement_kind','new_kind',p_new_kind);
END;
$function$;

-- add_dispatch_row v4: movement_kind added to both INSERTs and to the m2m-partner UPDATE.
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
) RETURNS jsonb
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
  v_movement_kind     text;
  v_return_wh_id      uuid;
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

  -- PRD-131 F2: movement_kind decided here, once, from action + source_kind.
  v_movement_kind := CASE
    WHEN p_action = 'Remove' AND p_source_kind IN ('m2m','truck_transfer') THEN 'transfer_out'
    WHEN p_action = 'Remove' THEN 'warehouse_return'
    WHEN p_source_kind IN ('m2m','truck_transfer') THEN 'transfer_in'
    ELSE 'warehouse_fill'
  END;

  -- PRD-131 F5 VOX rule: a warehouse_return always settles against
  -- machines.primary_warehouse_id, never a caller-supplied warehouse, and never carries
  -- from_warehouse_id (that column is warehouse_fill-only per F1).
  IF v_movement_kind = 'warehouse_return' THEN
    SELECT primary_warehouse_id INTO v_return_wh_id FROM public.machines WHERE machine_id = p_machine_id;
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
       source_origin, m2m_transfer_id, m2m_partner_id, movement_kind,
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
       v_movement_kind,
       auth.uid(), p_edit_role, now(), 0)
    RETURNING dispatch_id INTO v_new_id;

    IF p_source_kind = 'm2m' THEN
      UPDATE public.refill_dispatching
         SET source_kind = 'm2m',
             is_m2m = true,
             m2m_transfer_id = v_transfer_id,
             m2m_partner_id = v_new_id,
             source_warehouse_id = NULL,
             from_warehouse_id = NULL,
             source_machine_id = v_partner.machine_id,
             movement_kind = 'transfer_out'
       WHERE dispatch_id = p_partner_dispatch_id;
    END IF;

    v_after := jsonb_build_object(
      'dispatch_id', v_new_id, 'machine_id', p_machine_id, 'shelf_id', v_shelf_id,
      'boonz_product_id', p_boonz_product_id, 'pod_product_id', v_pod_product_id,
      'quantity', p_quantity, 'action', p_action, 'source_kind', p_source_kind,
      'source_warehouse_id', p_source_warehouse_id, 'source_machine_id', p_source_machine_id,
      'from_wh_inventory_id', v_fefo_wh_id, 'bind_fail_reason', v_bind_fail_reason,
      'm2m_transfer_id', v_transfer_id, 'm2m_partner_id', CASE WHEN p_source_kind = 'm2m' THEN p_partner_dispatch_id ELSE NULL END,
      'movement_kind', v_movement_kind);

    INSERT INTO public.refill_dispatching_edit_log
      (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
    VALUES
      (v_new_id, auth.uid(), p_edit_role, 'add', NULL, v_after, p_reason, p_conductor_session);

    RETURN jsonb_build_object('dispatch_id', v_new_id, 'edit_kind','add', 'after', v_after,
      'transfer_id', v_transfer_id, 'partner_dispatch_id', CASE WHEN p_source_kind = 'm2m' THEN p_partner_dispatch_id ELSE NULL END,
      'rpc_version','v4_prd131_f2');
  END IF;

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
     from_warehouse_id, expiry_date, pod_lot_id, source_origin, movement_kind, return_warehouse_id,
     last_edited_by, last_edited_by_role, last_edited_at, edit_count)
  VALUES
    (p_machine_id, v_shelf_id, v_pod_product_id, p_boonz_product_id, p_dispatch_date, p_action,
     p_quantity, false, true, false, false, false, true,
     CASE WHEN v_lot_expiry IS NULL THEN '[EXPIRY-TO-CONFIRM — remainder not attributable to a known batch (PRD-053)]' ELSE NULL END,
     p_source_kind, p_source_warehouse_id, p_source_machine_id,
     (p_source_kind = 'truck_transfer' OR p_source_kind = 'm2m'), true,
     NULL, v_lot_expiry, v_lot_id,
     v_source_origin, v_movement_kind, v_return_wh_id,
     auth.uid(), p_edit_role, now(), 0)
  RETURNING dispatch_id INTO v_new_id;
  v_first_id := v_new_id;
  v_leg_after := jsonb_build_object(
    'dispatch_id', v_new_id, 'machine_id', p_machine_id, 'shelf_id', v_shelf_id,
    'boonz_product_id', p_boonz_product_id, 'pod_product_id', v_pod_product_id,
    'quantity', p_quantity, 'action', p_action, 'pod_lot_id', v_lot_id,
    'expiry_date', v_lot_expiry, 'flavor_corrected', false, 'movement_kind', v_movement_kind);
  v_legs := v_legs || jsonb_build_array(v_leg_after);
  INSERT INTO public.refill_dispatching_edit_log
    (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
  VALUES (v_new_id, auth.uid(), p_edit_role, 'add', NULL, v_leg_after, p_reason, p_conductor_session);

  RETURN jsonb_build_object(
    'dispatch_id', v_first_id, 'edit_kind','add', 'legs', v_legs,
    'remove_flavor_corrected', 0, 'remove_no_lot_on_shelf', 0,
    'rpc_version','v4_prd131_f2');
END;
$function$;

-- add_m2m_transfer: both legs always source_kind='m2m' -> Remove leg transfer_out, Add New leg transfer_in.
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

  SELECT pil.expiration_date, pil.pod_inventory_id
    INTO v_lot_expiry, v_lot_id
    FROM public.v_pod_inventory_latest pil
   WHERE pil.machine_id = p_source_machine_id
     AND pil.shelf_id = v_src_shelf_id
     AND pil.status = 'Active'
     AND COALESCE(pil.current_stock,0) > 0
   ORDER BY pil.expiration_date ASC NULLS LAST
   LIMIT 1;

  INSERT INTO public.refill_dispatching
    (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action, quantity,
     packed, dispatched, picked_up, returned, item_added, include, comment,
     source_kind, source_machine_id, is_m2m, m2m_transfer_id, created_by_edit,
     expiry_date, pod_lot_id, pack_outcome, source_origin, movement_kind,
     last_edited_by, last_edited_by_role, last_edited_at, edit_count)
  VALUES
    (p_source_machine_id, v_src_shelf_id, v_src_pod_product, p_boonz_product_id, p_dispatch_date, 'Remove', p_quantity,
     true, true, true, false, false, true,
     format('M2M: %s -> %s%s', v_src_name, v_dest_name, CASE WHEN p_reason IS NOT NULL THEN ' ('||p_reason||')' ELSE '' END),
     'm2m', p_source_machine_id, true, v_transfer_id, true,
     v_lot_expiry, v_lot_id, 'no_pack_needed'::public.pack_outcome_enum, 'internal_transfer'::public.source_origin_enum, 'transfer_out',
     auth.uid(), NULL, now(), 0)
  RETURNING dispatch_id INTO v_remove_id;

  INSERT INTO public.refill_dispatching
    (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action, quantity,
     packed, dispatched, picked_up, returned, item_added, include, comment,
     source_kind, source_machine_id, is_m2m, m2m_transfer_id, m2m_partner_id, created_by_edit,
     pack_outcome, source_origin, movement_kind,
     last_edited_by, last_edited_by_role, last_edited_at, edit_count)
  VALUES
    (p_dest_machine_id, v_dest_shelf_id, v_dest_pod_product, p_boonz_product_id, p_dispatch_date, 'Add New', p_quantity,
     true, true, false, false, false, true,
     format('M2M: %s -> %s%s', v_src_name, v_dest_name, CASE WHEN p_reason IS NOT NULL THEN ' ('||p_reason||')' ELSE '' END),
     'm2m', p_source_machine_id, true, v_transfer_id, v_remove_id, true,
     'no_pack_needed'::public.pack_outcome_enum, 'internal_transfer'::public.source_origin_enum, 'transfer_in',
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
    'source_machine', v_src_name, 'dest_machine', v_dest_name,
    'quantity', p_quantity, 'boonz_product_id', p_boonz_product_id
  );
END;
$function$;

-- add_intra_machine_move: both legs always source_kind='intra_machine' -> Remove leg intra_out, Add New leg intra_in.
CREATE OR REPLACE FUNCTION public.add_intra_machine_move(p_machine_id uuid, p_from_shelf_code text, p_to_shelf_code text, p_boonz_product_id uuid, p_quantity numeric, p_dispatch_date date, p_reason text DEFAULT NULL::text)
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
     expiry_date, pod_lot_id, pack_outcome, movement_kind,
     last_edited_by, last_edited_by_role, last_edited_at, edit_count)
  VALUES
    (p_machine_id, v_from_shelf_id, v_from_pod_product, p_boonz_product_id, p_dispatch_date, 'Remove', p_quantity,
     true, true, true, false, false, true,
     format('Move %s to %s%s', p_from_shelf_code, p_to_shelf_code, CASE WHEN p_reason IS NOT NULL THEN ' ('||p_reason||')' ELSE '' END),
     'intra_machine', p_machine_id, v_transfer_id, true,
     v_lot_expiry, v_lot_id, 'no_pack_needed'::public.pack_outcome_enum, 'intra_out',
     auth.uid(), NULL, now(), 0)
  RETURNING dispatch_id INTO v_remove_id;

  INSERT INTO public.refill_dispatching
    (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action, quantity,
     packed, dispatched, picked_up, returned, item_added, include, comment,
     source_kind, source_machine_id, m2m_transfer_id, m2m_partner_id, created_by_edit,
     pack_outcome, movement_kind,
     last_edited_by, last_edited_by_role, last_edited_at, edit_count)
  VALUES
    (p_machine_id, v_to_shelf_id, v_to_pod_product, p_boonz_product_id, p_dispatch_date, 'Add New', p_quantity,
     true, true, false, false, false, true,
     format('Move %s to %s%s', p_from_shelf_code, p_to_shelf_code, CASE WHEN p_reason IS NOT NULL THEN ' ('||p_reason||')' ELSE '' END),
     'intra_machine', p_machine_id, v_transfer_id, v_remove_id, true,
     'no_pack_needed'::public.pack_outcome_enum, 'intra_in',
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

-- insert_driver_remove_line: m2m-split source -> transfer_out, m2m-split dest -> transfer_in,
-- plain remove (parent not m2m by construction at this point in the function) -> warehouse_return.
CREATE OR REPLACE FUNCTION public.insert_driver_remove_line(p_machine_id uuid, p_boonz_product_id uuid, p_pod_product_id uuid, p_shelf_id uuid, p_quantity numeric, p_expiry_date date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_caller_id uuid := auth.uid();
  v_caller_role text;
  v_dispatch_id uuid;
  v_parent refill_dispatching%ROWTYPE;
  v_partner refill_dispatching%ROWTYPE;
  v_new_transfer_id uuid;
  v_new_source_id uuid;
  v_new_dest_id uuid;
  v_dest_pod_ok boolean;
BEGIN
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = v_caller_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN
    ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'insert_driver_remove_line: role % not authorized', COALESCE(v_caller_role, 'none');
  END IF;
  IF p_machine_id IS NULL OR p_boonz_product_id IS NULL OR p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'p_machine_id, p_boonz_product_id, p_quantity required (qty > 0)';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>=10 chars)';
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'insert_driver_remove_line', true);

  SELECT * INTO v_parent FROM refill_dispatching rd
   WHERE rd.machine_id = p_machine_id
     AND (rd.shelf_id = p_shelf_id OR (rd.shelf_id IS NULL AND p_shelf_id IS NULL))
     AND rd.pod_product_id = p_pod_product_id
     AND rd.dispatch_date = CURRENT_DATE
     AND rd.action = 'Remove' AND rd.include
     AND COALESCE(rd.cancelled, false) = false
   ORDER BY rd.created_at DESC LIMIT 1;

  IF COALESCE(v_parent.is_m2m, false) THEN
    SELECT * INTO v_parent FROM refill_dispatching rd
     WHERE rd.machine_id = p_machine_id
       AND (rd.shelf_id = p_shelf_id OR (rd.shelf_id IS NULL AND p_shelf_id IS NULL))
       AND rd.pod_product_id = p_pod_product_id
       AND rd.dispatch_date = CURRENT_DATE
       AND rd.action = 'Remove' AND rd.include
       AND COALESCE(rd.cancelled, false) = false
       AND COALESCE(rd.is_m2m, false) = true
       AND rd.boonz_product_id IS DISTINCT FROM p_boonz_product_id
       AND COALESCE(rd.quantity, 0) >= p_quantity
     ORDER BY rd.quantity DESC, rd.created_at ASC
     FOR UPDATE
     LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'insert_driver_remove_line: no open M2M parent leg for machine %, shelf %, pod % has >= % units remaining to split off as % -- resolve manually, refusing to write an orphan',
        p_machine_id, p_shelf_id, p_pod_product_id, p_quantity, p_boonz_product_id;
    END IF;

    IF v_parent.m2m_partner_id IS NULL THEN
      RAISE EXCEPTION 'insert_driver_remove_line: parent dispatch % is is_m2m=true but has no m2m_partner_id -- destination cannot be resolved, refusing to write an orphan',
        v_parent.dispatch_id;
    END IF;

    SELECT * INTO v_partner FROM refill_dispatching WHERE dispatch_id = v_parent.m2m_partner_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'insert_driver_remove_line: parent dispatch %''s partner % not found -- destination cannot be resolved, refusing to write an orphan',
        v_parent.dispatch_id, v_parent.m2m_partner_id;
    END IF;
    IF COALESCE(v_partner.quantity, 0) < p_quantity THEN
      RAISE EXCEPTION 'insert_driver_remove_line: destination leg % only has % units remaining, cannot absorb a % unit split -- the pair is already imbalanced, resolve manually',
        v_partner.dispatch_id, v_partner.quantity, p_quantity;
    END IF;

    SELECT EXISTS (
      SELECT 1 FROM product_mapping pm
      WHERE pm.pod_product_id = p_pod_product_id AND pm.status = 'Active'
        AND pm.boonz_product_id = p_boonz_product_id
        AND (pm.machine_id = v_partner.machine_id OR pm.machine_id IS NULL)
    ) INTO v_dest_pod_ok;
    IF NOT v_dest_pod_ok THEN
      RAISE EXCEPTION 'insert_driver_remove_line: boonz_product % has no Active product_mapping to pod % at destination machine % -- refusing to write an orphan',
        p_boonz_product_id, p_pod_product_id, v_partner.machine_id;
    END IF;

    v_new_transfer_id := gen_random_uuid();
    v_new_source_id := gen_random_uuid();
    v_new_dest_id := gen_random_uuid();

    INSERT INTO refill_dispatching
      (dispatch_id, machine_id, boonz_product_id, pod_product_id, shelf_id,
       dispatch_date, action, quantity, filled_quantity, expiry_date,
       packed, picked_up, dispatched, returned, item_added, include, comment,
       source_origin, source_kind, source_machine_id, is_m2m, m2m_transfer_id,
       from_warehouse_id, movement_kind)
    VALUES
      (v_new_source_id, p_machine_id, p_boonz_product_id, p_pod_product_id, p_shelf_id,
       CURRENT_DATE, 'Remove', p_quantity, 0, p_expiry_date,
       true, true, true, false, false, true,
       format('[DRIVER-INSERT] Multi-variant split: %s', p_reason),
       'internal_transfer'::source_origin_enum, 'm2m', p_machine_id, true, v_new_transfer_id,
       NULL, 'transfer_out');

    INSERT INTO refill_dispatching
      (dispatch_id, machine_id, boonz_product_id, pod_product_id, shelf_id,
       dispatch_date, action, quantity, filled_quantity, expiry_date,
       packed, picked_up, dispatched, returned, item_added, include, comment,
       source_origin, source_kind, source_machine_id, is_m2m, m2m_transfer_id, m2m_partner_id,
       from_warehouse_id, movement_kind)
    VALUES
      (v_new_dest_id, v_partner.machine_id, p_boonz_product_id, p_pod_product_id, v_partner.shelf_id,
       CURRENT_DATE, 'Add New', p_quantity, 0, p_expiry_date,
       true, false, false, false, false, true,
       format('[DRIVER-INSERT] Multi-variant split: %s', p_reason),
       'internal_transfer'::source_origin_enum, 'm2m', p_machine_id, true, v_new_transfer_id, v_new_source_id,
       NULL, 'transfer_in')
    RETURNING dispatch_id INTO v_dispatch_id;

    UPDATE refill_dispatching SET m2m_partner_id = v_new_dest_id WHERE dispatch_id = v_new_source_id;

    UPDATE refill_dispatching SET quantity = quantity - p_quantity WHERE dispatch_id = v_parent.dispatch_id;
    UPDATE refill_dispatching SET quantity = quantity - p_quantity WHERE dispatch_id = v_partner.dispatch_id;

    RETURN jsonb_build_object('ok', true, 'dispatch_id', v_new_source_id,
      'dest_dispatch_id', v_new_dest_id, 'transfer_id', v_new_transfer_id,
      'machine_id', p_machine_id, 'dest_machine_id', v_partner.machine_id,
      'qty', p_quantity, 'reason', p_reason,
      'inherited_from_parent', v_parent.dispatch_id, 'partner_reduced', v_partner.dispatch_id);
  END IF;

  IF v_parent.dispatch_id IS NOT NULL AND COALESCE(v_parent.quantity, 0) < p_quantity THEN
    RAISE EXCEPTION 'insert_driver_remove_line: parent dispatch % only has % units remaining, cannot absorb a % unit split',
      v_parent.dispatch_id, v_parent.quantity, p_quantity;
  END IF;

  INSERT INTO refill_dispatching
    (machine_id, boonz_product_id, pod_product_id, shelf_id,
     dispatch_date, action, quantity, filled_quantity, expiry_date,
     packed, picked_up, dispatched, returned, item_added, include, comment,
     source_kind, source_machine_id, is_m2m, is_internal_move, from_warehouse_id, source_warehouse_id,
     movement_kind, return_warehouse_id)
  VALUES
    (p_machine_id, p_boonz_product_id, p_pod_product_id, p_shelf_id,
     CURRENT_DATE, 'Remove', p_quantity, 0, p_expiry_date,
     true, true, false, false, false, true,
     format('[DRIVER-INSERT] %s', p_reason),
     CASE WHEN COALESCE(v_parent.source_kind, 'unknown') = 'wh'
               AND COALESCE(v_parent.source_warehouse_id, v_parent.from_warehouse_id) IS NULL
          THEN 'unknown' ELSE COALESCE(v_parent.source_kind, 'unknown') END,
     v_parent.source_machine_id,
     COALESCE(v_parent.is_m2m, false), COALESCE(v_parent.is_internal_move, false),
     NULL,
     CASE WHEN COALESCE(v_parent.source_kind, 'unknown') = 'wh'
          THEN COALESCE(v_parent.source_warehouse_id, v_parent.from_warehouse_id) ELSE NULL END,
     'warehouse_return', (SELECT primary_warehouse_id FROM machines WHERE machine_id = p_machine_id))
  RETURNING dispatch_id INTO v_dispatch_id;

  IF v_parent.dispatch_id IS NOT NULL THEN
    UPDATE refill_dispatching SET quantity = quantity - p_quantity WHERE dispatch_id = v_parent.dispatch_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'dispatch_id', v_dispatch_id,
    'machine_id', p_machine_id, 'qty', p_quantity, 'reason', p_reason,
    'inherited_from_parent', v_parent.dispatch_id);
END $function$;

-- convert_removes_to_m2m_transfer: new Add New leg -> transfer_in; source rows retroactively
-- converted to transfer_out explicitly (this RPC IS the privileged retroactive-reclassification
-- tool for this one case; operator_admin/superadmin/manager gated already).
CREATE OR REPLACE FUNCTION public.convert_removes_to_m2m_transfer(p_dispatch_ids uuid[], p_dest_machine_id uuid, p_dest_shelf_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_transfer_id uuid := gen_random_uuid(); v_n int;
  v_src_machine uuid; v_src_name text; v_dest_name text; v_row refill_dispatching%ROWTYPE;
  v_add_id uuid; v_qty numeric; v_total numeric := 0; v_results jsonb := '[]'::jsonb; v_tag text;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','convert_removes_to_m2m_transfer',true);
  IF v_uid IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id=v_uid AND role=ANY(ARRAY['operator_admin','superadmin','manager'])) THEN
    RAISE EXCEPTION 'Unauthorized: operator_admin/superadmin/manager required'; END IF;
  IF p_dispatch_ids IS NULL OR array_length(p_dispatch_ids,1) IS NULL THEN RAISE EXCEPTION 'p_dispatch_ids must be a non-empty array'; END IF;
  SELECT official_name INTO v_dest_name FROM public.machines WHERE machine_id=p_dest_machine_id;
  IF v_dest_name IS NULL THEN RAISE EXCEPTION 'Dest machine not found: %', p_dest_machine_id; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.shelf_configurations WHERE shelf_id=p_dest_shelf_id AND machine_id=p_dest_machine_id) THEN
    RAISE EXCEPTION 'Dest shelf % not found on dest machine %', p_dest_shelf_id, p_dest_machine_id; END IF;
  SELECT count(*) INTO v_n FROM public.refill_dispatching WHERE dispatch_id=ANY(p_dispatch_ids);
  IF v_n<>array_length(p_dispatch_ids,1) THEN RAISE EXCEPTION 'Some dispatch_ids not found (% of % exist)', v_n, array_length(p_dispatch_ids,1); END IF;
  IF EXISTS (SELECT 1 FROM public.refill_dispatching WHERE dispatch_id=ANY(p_dispatch_ids) AND action<>'Remove') THEN RAISE EXCEPTION 'All rows must be action=Remove'; END IF;
  IF EXISTS (SELECT 1 FROM public.refill_dispatching WHERE dispatch_id=ANY(p_dispatch_ids) AND COALESCE(is_m2m,false)=true) THEN RAISE EXCEPTION 'Idempotency: one or more rows are already is_m2m=true (already converted)'; END IF;
  IF EXISTS (SELECT 1 FROM public.refill_dispatching WHERE dispatch_id=ANY(p_dispatch_ids) AND (item_added=true OR COALESCE(cancelled,false)=true OR COALESCE(returned,false)=true)) THEN
    RAISE EXCEPTION 'All rows must have item_added=false, cancelled=false, returned=false'; END IF;
  SELECT count(DISTINCT machine_id) INTO v_n FROM public.refill_dispatching WHERE dispatch_id=ANY(p_dispatch_ids);
  IF v_n<>1 THEN RAISE EXCEPTION 'All rows must share one source machine (found % distinct)', v_n; END IF;
  SELECT machine_id INTO v_src_machine FROM public.refill_dispatching WHERE dispatch_id=ANY(p_dispatch_ids) LIMIT 1;
  IF v_src_machine=p_dest_machine_id THEN RAISE EXCEPTION 'Source and destination machine must differ'; END IF;
  SELECT official_name INTO v_src_name FROM public.machines WHERE machine_id=v_src_machine;
  v_tag := format('M2M retro %s -> %s: %s', v_src_name, v_dest_name, p_reason);
  FOR v_row IN SELECT * FROM public.refill_dispatching WHERE dispatch_id=ANY(p_dispatch_ids) ORDER BY dispatch_id LOOP
    v_qty := COALESCE(v_row.driver_confirmed_qty, v_row.quantity); v_add_id := gen_random_uuid();
    INSERT INTO public.refill_dispatching (
      dispatch_id, machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action, quantity,
      packed, dispatched, picked_up, is_m2m, m2m_transfer_id, m2m_partner_id,
      from_warehouse_id, from_wh_inventory_id, source_machine_id, source_kind, comment, movement_kind
    ) VALUES (
      v_add_id, p_dest_machine_id, p_dest_shelf_id, v_row.pod_product_id, v_row.boonz_product_id, v_row.dispatch_date, 'Add New', v_qty,
      true, true, false, true, v_transfer_id, v_row.dispatch_id,
      NULL, NULL, v_src_machine, 'm2m', v_tag, 'transfer_in');
    UPDATE public.refill_dispatching SET
      quantity=v_qty, is_m2m=true, m2m_transfer_id=v_transfer_id, m2m_partner_id=v_add_id,
      from_warehouse_id=NULL, source_machine_id=v_src_machine, source_kind='m2m', comment=v_tag,
      movement_kind='transfer_out'
    WHERE dispatch_id=v_row.dispatch_id;
    v_total := v_total + v_qty;
    v_results := v_results || jsonb_build_object('source_dispatch_id', v_row.dispatch_id, 'dest_dispatch_id', v_add_id, 'boonz_product_id', v_row.boonz_product_id, 'quantity', v_qty);
  END LOOP;
  RETURN jsonb_build_object('status','ok','transfer_id',v_transfer_id,'source_machine',v_src_name,'dest_machine',v_dest_name,'lines',jsonb_array_length(v_results),'total_units',v_total,'items',v_results);
END; $function$;

-- pair_internal_transfer_m2m: supersedes prd130_06's body. Both pairing UPDATEs now also set
-- movement_kind explicitly (idempotent if the writer already set it correctly at creation).
CREATE OR REPLACE FUNCTION public.pair_internal_transfer_m2m(p_plan_date date DEFAULT NULL::date, p_caller_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller_id, auth.uid());
  v_role    text;
  v_pair    RECORD;
  v_transfer_id uuid;
  v_paired  int := 0;
  v_legs    int := 0;
  v_results jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
BEGIN
  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager','warehouse') THEN
      RAISE EXCEPTION 'pair_internal_transfer_m2m: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  PERFORM set_config('app.via_rpc','true', true);
  PERFORM set_config('app.rpc_name','pair_internal_transfer_m2m', true);
  PERFORM set_config('app.via_trigger','true', true);
  PERFORM set_config('app.mutation_reason',
    format('PRD-130 F6 pair internal_transfer/m2m legs plan_date=%s by=%s', COALESCE(p_plan_date::text,'ALL'), v_user_id), true);

  FOR v_pair IN
    WITH dest AS (
      SELECT d.dispatch_id AS dest_id, d.machine_id AS dest_machine, d.from_machine_id AS src_machine,
             d.pod_product_id, d.boonz_product_id, d.dispatch_date, d.quantity AS dest_qty, d.expiry_date
      FROM public.refill_dispatching d
      WHERE (d.source_origin = 'internal_transfer' OR d.source_kind = 'm2m')
        AND d.action IN ('Refill','Add New')
        AND d.from_machine_id IS NOT NULL
        AND d.m2m_transfer_id IS NULL
        AND COALESCE(d.item_added,false)=false
        AND COALESCE(d.cancelled,false)=false
        AND COALESCE(d.returned,false)=false
        AND (p_plan_date IS NULL OR d.dispatch_date = p_plan_date)
    ),
    src AS (
      SELECT s.dispatch_id AS src_id, s.machine_id AS src_machine,
             s.pod_product_id, s.dispatch_date, s.quantity AS src_qty, s.expiry_date AS src_expiry
      FROM public.refill_dispatching s
      WHERE (s.source_origin = 'internal_transfer' OR s.source_kind = 'm2m')
        AND s.action IN ('Remove','Machine To Warehouse')
        AND s.m2m_transfer_id IS NULL
        AND COALESCE(s.item_added,false)=false
        AND COALESCE(s.cancelled,false)=false
        AND COALESCE(s.returned,false)=false
        AND (p_plan_date IS NULL OR s.dispatch_date = p_plan_date)
    ),
    matched AS (
      SELECT d.dest_id, d.dest_machine, d.src_machine, d.pod_product_id, d.boonz_product_id,
             d.dispatch_date, d.dest_qty, d.expiry_date AS dest_expiry,
             s.src_id, s.src_qty, s.src_expiry,
             count(*) OVER (PARTITION BY d.dest_id) AS src_count
      FROM dest d
      JOIN src s
        ON s.src_machine    = d.src_machine
       AND s.pod_product_id = d.pod_product_id
       AND s.dispatch_date  = d.dispatch_date
    )
    SELECT * FROM matched
  LOOP
    IF v_pair.src_count <> 1 THEN
      v_skipped := v_skipped || jsonb_build_object('dest_id', v_pair.dest_id, 'reason',
        format('ambiguous: %s candidate source legs (batch split / multi-match) - manual pairing', v_pair.src_count));
      CONTINUE;
    END IF;
    IF v_pair.src_qty <> v_pair.dest_qty THEN
      v_skipped := v_skipped || jsonb_build_object('dest_id', v_pair.dest_id, 'reason',
        format('qty mismatch: source %s <> dest %s', v_pair.src_qty, v_pair.dest_qty));
      CONTINUE;
    END IF;

    v_transfer_id := gen_random_uuid();

    UPDATE public.refill_dispatching
       SET is_m2m = true, m2m_transfer_id = v_transfer_id, m2m_partner_id = v_pair.src_id,
           source_machine_id = v_pair.src_machine, source_kind = 'm2m', source_origin = 'internal_transfer',
           expiry_date = COALESCE(expiry_date, v_pair.src_expiry), movement_kind = 'transfer_in'
     WHERE dispatch_id = v_pair.dest_id;

    UPDATE public.refill_dispatching
       SET is_m2m = true, m2m_transfer_id = v_transfer_id, m2m_partner_id = v_pair.dest_id,
           source_machine_id = v_pair.src_machine, source_kind = 'm2m', source_origin = 'internal_transfer',
           movement_kind = 'transfer_out'
     WHERE dispatch_id = v_pair.src_id;

    v_paired := v_paired + 1;
    v_legs   := v_legs + 2;
    v_results := v_results || jsonb_build_object(
      'transfer_id', v_transfer_id, 'dest_id', v_pair.dest_id, 'src_id', v_pair.src_id,
      'pod_product_id', v_pair.pod_product_id, 'qty', v_pair.dest_qty,
      'dispatch_date', v_pair.dispatch_date, 'dest_machine', v_pair.dest_machine, 'src_machine', v_pair.src_machine);
  END LOOP;

  RETURN jsonb_build_object(
    'status','ok',
    'plan_date', p_plan_date,
    'pairs_formed', v_paired,
    'legs_flagged', v_legs,
    'paired', v_results,
    'skipped', v_skipped
  );
END;
$function$;

-- push_plan_to_dispatch: 4 insertion points get movement_kind (M2M source Remove ->
-- transfer_out, M2M dest group -> transfer_in, plain Remove/M2W -> warehouse_return, general
-- upsert Refill/Add New -> warehouse_fill, vox_at_venue lines included per F2's own note). Also
-- fixes the v_action CASE: plan action 'MACHINE TO WAREHOUSE' now produces v_action='Remove',
-- not 'Machine To Warehouse' -- action is derived/compatibility per F1, movement_kind carries
-- the real meaning, and 'Machine To Warehouse' is retired.
CREATE OR REPLACE FUNCTION public.push_plan_to_dispatch(p_plan_date date, p_machine_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id              uuid;
  v_machine_id           uuid;
  v_primary_warehouse_id uuid;
  v_secondary_warehouse_id uuid;
  v_count                int := 0;
  v_skipped              int := 0;
  v_pinned_count         int := 0;
  v_procurement_gaps     int := 0;
  v_preserved            int := 0;
  v_remove_split         int := 0;
  v_leak_n               int := 0;
  line                   RECORD;
  v_batch                RECORD;
  v_leak                 RECORD;
  v_remaining            int;
  v_take                 int;
  v_shelf_id             uuid;
  v_pod_product_id       uuid;
  v_boonz_product_id     uuid;
  v_normalized_shelf     text;
  v_action               text;
  v_dispatch_comment     text;
  v_new_dispatch_id      uuid;
  v_existing_edit_id     uuid;
  v_pinned_wh_id         uuid;
  v_pinned_expiry        date;
  v_pin_eligible         boolean;
  v_storage_temp         text;
  v_line_wh_id           uuid;
  v_wh_candidates        uuid[];
  v_pinned_route_wh      uuid;
  v_pairing              jsonb := NULL;
  v_prev_via_trigger     text;
  v_prev_mutation_reason text;
  v_transfer_id          uuid;
  v_src_line             RECORD;
  v_src_machine_id       uuid;
  v_src_shelf_id         uuid;
  v_src_normalized_shelf text;
  v_first_remove_id      uuid;
  v_dest_leg_id          uuid;
  v_earliest_expiry      date;
  v_transfer_pairs       int := 0;
  v_transfer_deferred    int := 0;
  v_transfer_skipped     int := 0;
  v_slot_guard           jsonb := NULL;
  v_tombstoned           int := 0;
  v_lane_weimi_stock     int;
  v_flavor_corrected     int := 0;
  v_no_lot_on_shelf      int := 0;
  v_src_group            RECORD;
  v_dest_leg_id_first    uuid;
  v_bulk_repair          jsonb := NULL;
  v_fefo_bind            jsonb := NULL;
  v_remove_lot_expiry    date;
  v_remove_lot_id        uuid;
  v_source_kind          text;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'push_plan_to_dispatch', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = v_user_id AND role = ANY (public.push_dispatch_authorized_roles())
  ) THEN
    RAISE EXCEPTION 'push_plan_to_dispatch: caller % lacks required role', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN RETURN jsonb_build_object('status','error','error','p_plan_date is required'); END IF;
  IF p_machine_name IS NULL OR length(trim(p_machine_name)) = 0 THEN
    RETURN jsonb_build_object('status','error','error','p_machine_name is required');
  END IF;

  SELECT machine_id, primary_warehouse_id, secondary_warehouse_id
    INTO v_machine_id, v_primary_warehouse_id, v_secondary_warehouse_id
    FROM machines WHERE official_name = p_machine_name;
  IF v_machine_id IS NULL THEN
    RETURN jsonb_build_object('status','error','error','Machine not found: '||p_machine_name);
  END IF;

  v_slot_guard := public.assert_weimi_slot_match(p_plan_date, NULL, p_machine_name);
  PERFORM set_config('app.rpc_name', 'push_plan_to_dispatch', true);

  v_leak_n := 0;
  FOR v_leak IN
    SELECT prp.shelf_id, prp.pod_product_id, prp.action,
           prp.qty::int AS parent, COALESCE(g.children,0)::int AS children
    FROM pod_refill_plan prp
    LEFT JOIN (
      SELECT sc.shelf_id, pp.pod_product_id,
             CASE upper(trim(rpo.action))
               WHEN 'REMOVE' THEN 'REMOVE' WHEN 'MACHINE TO WAREHOUSE' THEN 'M2W' END AS pod_action,
             SUM(rpo.quantity)::int AS children
      FROM refill_plan_output rpo
      JOIN shelf_configurations sc ON sc.machine_id = v_machine_id
           AND sc.shelf_code = regexp_replace(rpo.shelf_code, '^([A-Z])([0-9])$', '\1' || '0' || '\2')
      JOIN pod_products pp ON lower(trim(pp.pod_product_name)) = lower(trim(rpo.pod_product_name))
      WHERE rpo.plan_date = p_plan_date AND rpo.machine_name = p_machine_name
        AND rpo.operator_status = 'approved' AND rpo.dispatched = false
        AND upper(trim(rpo.action)) IN ('REMOVE','MACHINE TO WAREHOUSE')
      GROUP BY sc.shelf_id, pp.pod_product_id, 3
    ) g ON g.shelf_id = prp.shelf_id AND g.pod_product_id = prp.pod_product_id AND g.pod_action = prp.action
    WHERE prp.plan_date = p_plan_date AND prp.machine_id = v_machine_id
      AND prp.action IN ('REMOVE','M2W') AND prp.qty > 0
      AND prp.status <> 'superseded'
      AND prp.qty <> COALESCE(g.children, 0)
  LOOP
    INSERT INTO public.stitch_leakage(plan_date, machine_id, shelf_id, pod_product_id,
                                      action, parent_pod_qty, children_sum, delta, detected_by)
    VALUES (p_plan_date, v_machine_id, v_leak.shelf_id, v_leak.pod_product_id,
            v_leak.action, v_leak.parent, v_leak.children, v_leak.parent - v_leak.children,
            'push_plan_to_dispatch');
    v_leak_n := v_leak_n + 1;
  END LOOP;
  IF v_leak_n > 0 THEN
    RETURN jsonb_build_object(
      'status','conservation_violation',
      'machine', p_machine_name,
      'leaking_instructions', v_leak_n,
      'reason','SUM(approved plan children) <> pod_refill_plan qty for REMOVE/M2W — stop-ship; logged durably to stitch_leakage (PRD-053)'
    );
  END IF;

  FOR line IN
    SELECT * FROM refill_plan_output
    WHERE plan_date = p_plan_date AND machine_name = p_machine_name
      AND operator_status = 'approved' AND dispatched = false
  LOOP
    IF line.dispatch_id IS NOT NULL AND EXISTS (
      SELECT 1
        FROM public.refill_dispatching rd
        JOIN public.refill_dispatching_edit_log el
          ON el.dispatch_id = rd.dispatch_id AND el.edit_kind = 'remove'
       WHERE rd.dispatch_id   = line.dispatch_id
         AND rd.dispatch_date = p_plan_date
         AND COALESCE(rd.include, true) = false
    ) THEN
      v_tombstoned := v_tombstoned + 1;
      CONTINUE;
    END IF;

    v_normalized_shelf := regexp_replace(line.shelf_code, '^([A-Z])([0-9])$', '\1' || '0' || '\2');
    v_shelf_id := line.shelf_id;
    IF v_shelf_id IS NULL THEN
      SELECT shelf_id INTO v_shelf_id FROM shelf_configurations WHERE machine_id=v_machine_id AND shelf_code=v_normalized_shelf;
    END IF;
    v_pod_product_id := line.pod_product_id;
    IF v_pod_product_id IS NULL THEN
      SELECT pod_product_id INTO v_pod_product_id FROM pod_products WHERE lower(trim(pod_product_name))=lower(trim(line.pod_product_name)) LIMIT 1;
    END IF;
    v_boonz_product_id := line.boonz_product_id;
    IF v_boonz_product_id IS NULL THEN
      SELECT product_id INTO v_boonz_product_id FROM boonz_products WHERE lower(trim(boonz_product_name))=lower(trim(line.boonz_product_name)) LIMIT 1;
    END IF;

    IF v_boonz_product_id IS NULL OR v_pod_product_id IS NULL THEN v_skipped := v_skipped + 1; CONTINUE; END IF;

    -- PRD-124 #38 / PRD-125 D3: source_kind mapped from source_origin at push,
    -- so downstream consumers (validate_refill_plan G8's is_venue check, the
    -- WM confirmations screen) stop seeing 'unknown' on every row.
    v_source_kind := CASE COALESCE(line.source_origin::text, 'warehouse')
      WHEN 'warehouse' THEN 'wh'
      WHEN 'vox_at_venue' THEN 'venue'
      WHEN 'internal_transfer' THEN 'm2m'
      ELSE 'unknown'
    END;

    SELECT rd.dispatch_id INTO v_existing_edit_id
      FROM refill_dispatching rd
     WHERE rd.machine_id     = v_machine_id
       AND rd.dispatch_date  = line.plan_date
       AND rd.shelf_id       = v_shelf_id
       AND rd.pod_product_id = v_pod_product_id
       AND (rd.created_by_edit OR rd.edit_count > 0)
       AND COALESCE(rd.include,   true) = true
       AND COALESCE(rd.skipped,   false) = false
       AND COALESCE(rd.cancelled, false) = false
       AND COALESCE(rd.returned,  false) = false
     ORDER BY rd.created_at DESC NULLS LAST
     LIMIT 1;
    IF v_existing_edit_id IS NOT NULL THEN
      UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_existing_edit_id WHERE id = line.id;
      v_preserved := v_preserved + 1;
      CONTINUE;
    END IF;

    v_action := CASE upper(trim(line.action))
      WHEN 'REFILL' THEN 'Refill' WHEN 'ADD NEW' THEN 'Add New'
      WHEN 'REMOVE' THEN 'Remove' WHEN 'MACHINE TO WAREHOUSE' THEN 'Remove'
      WHEN 'SWAP' THEN 'Add New' ELSE trim(line.action)
    END;

    v_dispatch_comment := CASE
      WHEN line.operator_comment IS NOT NULL AND trim(line.operator_comment) != '' THEN
        COALESCE(NULLIF(trim(line.comment), '') || E'\n', '') || E'\U0001F4AC ' || trim(line.operator_comment)
      ELSE line.comment
    END;

    IF v_action IN ('Refill','Add New')
       AND COALESCE(line.source_origin::text, 'warehouse') = 'warehouse' THEN
      SELECT rd.dispatch_id INTO v_existing_edit_id
        FROM refill_dispatching rd
       WHERE rd.machine_id       = v_machine_id
         AND rd.dispatch_date    = line.plan_date
         AND rd.shelf_id         = v_shelf_id
         AND rd.boonz_product_id = v_boonz_product_id
         AND rd.action           = v_action
         AND rd.include          = true
         AND COALESCE(rd.skipped,   false) = false
         AND COALESCE(rd.cancelled, false) = false
         AND COALESCE(rd.returned,  false) = false
         AND COALESCE(rd.is_m2m,    false) = false
       ORDER BY rd.created_at DESC NULLS LAST
       LIMIT 1;
      IF v_existing_edit_id IS NOT NULL THEN
        UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_existing_edit_id WHERE id = line.id;
        v_preserved := v_preserved + 1;
        CONTINUE;
      END IF;
    END IF;

    IF COALESCE(line.source_origin::text,'warehouse') = 'internal_transfer' THEN
      IF v_action IN ('Remove','Machine To Warehouse') THEN
        v_transfer_deferred := v_transfer_deferred + 1;
        CONTINUE;
      END IF;
      IF v_action NOT IN ('Refill','Add New') OR line.from_machine_id IS NULL THEN
        v_transfer_skipped := v_transfer_skipped + 1;
        INSERT INTO public.monitoring_alerts (source, severity, payload)
        VALUES ('m2m_push_unroutable','warning', jsonb_build_object(
          'title', format('M2M line unroutable at push: %s @ %s', line.boonz_product_name, p_machine_name),
          'plan_line_id', line.id, 'plan_date', p_plan_date, 'action', v_action,
          'from_machine_id', line.from_machine_id,
          'detected_by','push_plan_to_dispatch_v7_prd071','detected_at', now()));
        CONTINUE;
      END IF;
      BEGIN
        SELECT rpo.* INTO v_src_line
          FROM refill_plan_output rpo
          JOIN machines sm ON sm.machine_id = line.from_machine_id AND sm.official_name = rpo.machine_name
         WHERE rpo.plan_date = line.plan_date
           AND rpo.source_origin = 'internal_transfer'
           AND upper(trim(rpo.action)) IN ('REMOVE','MACHINE TO WAREHOUSE')
           AND lower(trim(rpo.pod_product_name)) = lower(trim(line.pod_product_name))
           AND rpo.quantity = line.quantity
           AND rpo.operator_status = 'approved' AND rpo.dispatched = false
         ORDER BY rpo.id
         LIMIT 1;
        IF NOT FOUND THEN
          v_transfer_skipped := v_transfer_skipped + 1;
          INSERT INTO public.monitoring_alerts (source, severity, payload)
          VALUES ('m2m_push_no_source_line','warning', jsonb_build_object(
            'title', format('M2M dest line has no matching approved source Remove: %s @ %s', line.boonz_product_name, p_machine_name),
            'plan_line_id', line.id, 'plan_date', p_plan_date, 'qty', line.quantity,
            'from_machine_id', line.from_machine_id,
            'detected_by','push_plan_to_dispatch_v7_prd071','detected_at', now()));
          CONTINUE;
        END IF;

        v_src_machine_id := line.from_machine_id;
        v_src_normalized_shelf := regexp_replace(v_src_line.shelf_code, '^([A-Z])([0-9])$', '\1' || '0' || '\2');
        v_src_shelf_id := v_src_line.shelf_id;
        IF v_src_shelf_id IS NULL THEN
          SELECT shelf_id INTO v_src_shelf_id FROM shelf_configurations
           WHERE machine_id = v_src_machine_id AND shelf_code = v_src_normalized_shelf;
        END IF;

        v_transfer_id := gen_random_uuid();
        v_first_remove_id := NULL;
        v_earliest_expiry := NULL;

        -- PRD-125 D2: the source Remove leg lands on the plan's own shelf
        -- (v_src_shelf_id) always. pod_inventory on that shelf supplies
        -- expiry_date / pod_lot_id only, never a different shelf, never a
        -- different product, never a split into multiple legs.
        SELECT pil.expiration_date, pil.pod_inventory_id
          INTO v_remove_lot_expiry, v_remove_lot_id
          FROM public.v_pod_inventory_latest pil
         WHERE pil.machine_id = v_src_machine_id
           AND pil.shelf_id = v_src_shelf_id
           AND pil.status = 'Active'
           AND COALESCE(pil.current_stock,0) > 0
         ORDER BY pil.expiration_date ASC NULLS LAST
         LIMIT 1;

        INSERT INTO refill_dispatching (
          machine_id, shelf_id, pod_product_id, boonz_product_id,
          dispatch_date, action, quantity, include, comment,
          from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
          source_origin, from_machine_id, pod_lot_id,
          is_m2m, m2m_transfer_id, source_machine_id, source_kind, movement_kind,
          packed, picked_up, dispatched, returned, item_added
        ) VALUES (
          v_src_machine_id, v_src_shelf_id, v_pod_product_id, v_boonz_product_id,
          line.plan_date, 'Remove', line.quantity, true,
          CASE WHEN v_remove_lot_expiry IS NULL THEN
            COALESCE(NULLIF(trim(v_src_line.comment),''), format('M2M: %s -> %s', v_src_line.machine_name, p_machine_name))
              || E'\n[EXPIRY-TO-CONFIRM — remainder not attributable to a known batch (PRD-053)]'
          ELSE
            COALESCE(NULLIF(trim(v_src_line.comment),''), format('M2M: %s -> %s', v_src_line.machine_name, p_machine_name))
          END,
          NULL, NULL, v_remove_lot_expiry, false,
          'internal_transfer'::public.source_origin_enum, NULL, v_remove_lot_id,
          true, v_transfer_id, v_src_machine_id, 'm2m', 'transfer_out',
          true, true, true, false, false
        ) RETURNING dispatch_id INTO v_new_dispatch_id;
        v_first_remove_id := v_new_dispatch_id;
        v_earliest_expiry := v_remove_lot_expiry;
        v_count := v_count + 1;

        v_dest_leg_id_first := NULL;
        FOR v_src_group IN
          SELECT rd_src.boonz_product_id AS grp_boonz_product_id,
                 SUM(rd_src.quantity)::int AS grp_qty,
                 MIN(rd_src.expiry_date) AS grp_earliest_expiry,
                 (array_agg(rd_src.dispatch_id ORDER BY rd_src.created_at))[1] AS grp_first_dispatch_id
            FROM public.refill_dispatching rd_src
           WHERE rd_src.m2m_transfer_id = v_transfer_id AND rd_src.is_m2m = true
             AND rd_src.machine_id = v_src_machine_id
           GROUP BY rd_src.boonz_product_id
        LOOP
          INSERT INTO refill_dispatching (
            machine_id, shelf_id, pod_product_id, boonz_product_id,
            dispatch_date, action, quantity, include, comment,
            from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
            source_origin, from_machine_id,
            is_m2m, m2m_transfer_id, m2m_partner_id, source_machine_id, source_kind, movement_kind,
            packed, picked_up, dispatched, returned, item_added
          ) VALUES (
            v_machine_id, v_shelf_id, v_pod_product_id, v_src_group.grp_boonz_product_id,
            line.plan_date, v_action, v_src_group.grp_qty, true,
            COALESCE(NULLIF(trim(v_dispatch_comment),''), format('M2M: %s -> %s', v_src_line.machine_name, p_machine_name))
              || CASE WHEN v_src_group.grp_boonz_product_id <> v_boonz_product_id
                      THEN format(E'\n[FLAVOR-CORRECTED: destination adopts %s pulled at source, plan named %s]',
                             (SELECT bp4.boonz_product_name FROM boonz_products bp4 WHERE bp4.product_id = v_src_group.grp_boonz_product_id),
                             line.boonz_product_name)
                      ELSE '' END,
            NULL, NULL, v_src_group.grp_earliest_expiry, false,
            'internal_transfer'::public.source_origin_enum, v_src_machine_id,
            true, v_transfer_id, v_src_group.grp_first_dispatch_id, v_src_machine_id, 'm2m', 'transfer_in',
            true, false, false, false, false
          ) RETURNING dispatch_id INTO v_dest_leg_id;

          UPDATE refill_dispatching SET m2m_partner_id = v_dest_leg_id
           WHERE m2m_transfer_id = v_transfer_id AND is_m2m = true
             AND machine_id = v_src_machine_id AND boonz_product_id = v_src_group.grp_boonz_product_id;

          IF v_dest_leg_id_first IS NULL THEN v_dest_leg_id_first := v_dest_leg_id; END IF;
          v_count := v_count + 1;
        END LOOP;

        UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_dest_leg_id_first WHERE id = line.id;
        UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_first_remove_id WHERE id = v_src_line.id;
        v_transfer_pairs := v_transfer_pairs + 1;
      EXCEPTION WHEN OTHERS THEN
        v_transfer_skipped := v_transfer_skipped + 1;
        INSERT INTO public.monitoring_alerts (source, severity, payload)
        VALUES ('m2m_push_pair_failure','warning', jsonb_build_object(
          'title', format('M2M paired insert failed at push: %s @ %s', line.boonz_product_name, p_machine_name),
          'plan_line_id', line.id, 'plan_date', p_plan_date, 'error', SQLERRM,
          'detected_by','push_plan_to_dispatch_v7_prd071','detected_at', now()));
      END;
      CONTINUE;
    END IF;

    IF v_action IN ('Remove','Machine To Warehouse') THEN
      SELECT w.current_stock INTO v_lane_weimi_stock
        FROM public.weimi_aisle_snapshots w
       WHERE w.machine_id = v_machine_id
         AND w.slot_code = LEFT(v_normalized_shelf,1) || (SUBSTR(v_normalized_shelf,2)::int)::text
         AND w.snapshot_date BETWEEN line.plan_date - 3 AND line.plan_date + 3
       ORDER BY ABS(w.snapshot_date - line.plan_date) ASC, w.snapshot_at DESC
       LIMIT 1;
      IF v_lane_weimi_stock IS NOT NULL AND line.quantity > v_lane_weimi_stock THEN
        PERFORM public.safe_monitoring_alert('remove_qty_exceeds_lane', 'warning',
          jsonb_build_object('machine', p_machine_name, 'shelf', v_normalized_shelf,
            'pod_product_id', v_pod_product_id, 'plan_qty', line.quantity,
            'lane_stock', v_lane_weimi_stock, 'plan_date', line.plan_date,
            'plan_line_id', line.id, 'detected_by', 'push_plan_to_dispatch'));
      END IF;

      -- PRD-125 D2: the shelf is the plan's shelf (v_shelf_id), always -- never
      -- re-pointed to wherever a pod_inventory lot happens to sit, and never
      -- split into multiple legs. pod_inventory on that shelf supplies
      -- expiry_date / pod_lot_id only; when nothing Active sits there, the row
      -- still lands with expiry_date NULL and EXPIRY-TO-CONFIRM (never a 0-qty
      -- NO-LOT-ON-SHELF row -- that branch is deleted).
      SELECT pil.expiration_date, pil.pod_inventory_id
        INTO v_remove_lot_expiry, v_remove_lot_id
        FROM public.v_pod_inventory_latest pil
       WHERE pil.machine_id = v_machine_id
         AND pil.shelf_id = v_shelf_id
         AND pil.status = 'Active'
         AND COALESCE(pil.current_stock,0) > 0
       ORDER BY pil.expiration_date ASC NULLS LAST
       LIMIT 1;

      INSERT INTO refill_dispatching (
        machine_id, shelf_id, pod_product_id, boonz_product_id,
        dispatch_date, action, quantity, include, comment,
        from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
        source_origin, from_machine_id, pod_lot_id, source_kind, source_warehouse_id, movement_kind,
        return_warehouse_id,
        packed, picked_up, dispatched, returned, item_added
      ) VALUES (
        v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,
        line.plan_date, v_action, line.quantity, true,
        CASE WHEN v_remove_lot_expiry IS NULL THEN
          COALESCE(NULLIF(v_dispatch_comment,'') || E'\n', '') || '[EXPIRY-TO-CONFIRM — remainder not attributable to a known batch (PRD-053)]'
        ELSE v_dispatch_comment END,
        NULL, NULL, v_remove_lot_expiry, false,
        COALESCE(line.source_origin, 'warehouse'::public.source_origin_enum),
        CASE WHEN line.source_origin='internal_transfer' THEN line.from_machine_id ELSE NULL END,
        v_remove_lot_id,
        CASE WHEN v_source_kind = 'wh' AND v_primary_warehouse_id IS NULL THEN 'unknown' ELSE v_source_kind END,
        CASE WHEN v_source_kind = 'wh' THEN v_primary_warehouse_id ELSE NULL END,
        'warehouse_return',
        v_primary_warehouse_id,
        false, false, false, false, false
      ) RETURNING dispatch_id INTO v_new_dispatch_id;
      v_count := v_count + 1; v_remove_split := v_remove_split + 1;
      UPDATE refill_plan_output SET dispatched=true, dispatch_id=v_new_dispatch_id WHERE id=line.id;
      CONTINUE;
    END IF;

    v_pin_eligible := (v_action IN ('Refill','Add New'))
                      AND (COALESCE(line.source_origin::text, 'warehouse') = 'warehouse');
    v_pinned_wh_id := NULL;
    v_pinned_expiry := NULL;
    v_pinned_route_wh := NULL;

    SELECT storage_temp_requirement INTO v_storage_temp
      FROM boonz_products WHERE product_id = v_boonz_product_id;
    v_line_wh_id := CASE WHEN v_storage_temp = 'cold' THEN public.wh_central_id()
                         ELSE v_primary_warehouse_id END;
    v_wh_candidates := CASE WHEN v_storage_temp = 'cold' THEN ARRAY[v_line_wh_id]
                            ELSE ARRAY[v_line_wh_id, v_secondary_warehouse_id] END;

    IF v_pin_eligible AND v_line_wh_id IS NOT NULL THEN
      SELECT f.wh_inventory_id, f.expiration_date, f.warehouse_id
        INTO v_pinned_wh_id, v_pinned_expiry, v_pinned_route_wh
      FROM public.wh_fefo_for_line(
             v_machine_id, v_boonz_product_id, line.plan_date, line.quantity,
             v_wh_candidates) f
      WHERE f.is_satisfiable
        AND f.net_running >= line.quantity
      ORDER BY f.pick_rank
      LIMIT 1;

      IF v_pinned_wh_id IS NULL THEN
        v_procurement_gaps := v_procurement_gaps + 1;
        INSERT INTO public.monitoring_alerts (source, severity, payload)
        VALUES (
          'procurement_gap', 'warning',
          jsonb_build_object(
            'title', format('Procurement gap: %s at %s', line.boonz_product_name, p_machine_name),
            'plan_date', p_plan_date, 'machine_name', p_machine_name, 'machine_id', v_machine_id,
            'boonz_product_id', v_boonz_product_id, 'boonz_product_name', line.boonz_product_name,
            'wh_id', v_line_wh_id, 'action', v_action, 'qty_needed', line.quantity,
            'detected_by', 'push_plan_to_dispatch_FEFO_pin_rc01', 'detected_at', now()
          )
        );
      ELSE
        v_pinned_count := v_pinned_count + 1;
      END IF;
    END IF;

    INSERT INTO refill_dispatching (
      machine_id, shelf_id, pod_product_id, boonz_product_id,
      dispatch_date, action, quantity, include, comment,
      from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
      source_origin, from_machine_id, source_kind, source_warehouse_id, movement_kind,
      packed, picked_up, dispatched, returned, item_added
    ) VALUES (
      v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,
      line.plan_date, v_action, line.quantity, true, v_dispatch_comment,
      v_line_wh_id, v_pinned_wh_id, v_pinned_expiry, v_pin_eligible,
      COALESCE(line.source_origin, 'warehouse'::public.source_origin_enum),
      CASE WHEN line.source_origin='internal_transfer' THEN line.from_machine_id ELSE NULL END,
      CASE WHEN v_source_kind = 'wh' AND v_line_wh_id IS NULL THEN 'unknown' ELSE v_source_kind END,
      CASE WHEN v_source_kind = 'wh' THEN v_line_wh_id ELSE NULL END,
      'warehouse_fill',
      false, false, false, false, false
    )
    ON CONFLICT (dispatch_date, machine_id, shelf_id, boonz_product_id, action)
      WHERE ( include = true AND action IN ('Refill','Add New')
              AND COALESCE(filled_quantity,0)=0
              AND packed=false AND item_added=false AND returned=false
              AND skipped=false AND cancelled=false
              AND created_by_edit=false AND is_m2m=false )
    DO UPDATE SET
      quantity             = EXCLUDED.quantity,
      comment              = EXCLUDED.comment,
      from_wh_inventory_id = EXCLUDED.from_wh_inventory_id,
      expiry_date          = EXCLUDED.expiry_date,
      pinned_at_plan_time  = EXCLUDED.pinned_at_plan_time,
      from_warehouse_id    = EXCLUDED.from_warehouse_id,
      source_kind          = EXCLUDED.source_kind,
      source_warehouse_id  = EXCLUDED.source_warehouse_id
    RETURNING dispatch_id INTO v_new_dispatch_id;

    UPDATE refill_plan_output SET dispatched=true, dispatch_id=v_new_dispatch_id WHERE id=line.id;
    v_count := v_count + 1;
  END LOOP;

  v_prev_via_trigger := current_setting('app.via_trigger', true);
  v_prev_mutation_reason := current_setting('app.mutation_reason', true);
  BEGIN
    v_pairing := public.pair_internal_transfer_m2m(p_plan_date, v_user_id);
  EXCEPTION WHEN OTHERS THEN
    v_pairing := jsonb_build_object('status','error','error', SQLERRM);
    INSERT INTO public.monitoring_alerts (source, severity, payload)
    VALUES ('m2m_pairing_failure', 'warning', jsonb_build_object(
      'title', format('M2M auto-pairing failed on push: %s @ %s', p_machine_name, p_plan_date),
      'plan_date', p_plan_date, 'machine_name', p_machine_name, 'machine_id', v_machine_id,
      'error', SQLERRM, 'detected_by', 'push_plan_to_dispatch_v7_prd071', 'detected_at', now()));
  END;
  BEGIN
    v_bulk_repair := public.repair_remove_leg_shelf_lot_bulk(p_plan_date, p_machine_name,
      'auto-run at push (PRD-120 L5 item 2): close any Remove leg the flavor fallback still left NULL', NULL, false);
  EXCEPTION WHEN OTHERS THEN
    v_bulk_repair := jsonb_build_object('status','error','error', SQLERRM);
    INSERT INTO public.monitoring_alerts (source, severity, payload)
    VALUES ('push_auto_repair_failure', 'warning', jsonb_build_object(
      'title', format('Auto-repair of NULL pod_lot_id Remove legs failed on push: %s @ %s', p_machine_name, p_plan_date),
      'plan_date', p_plan_date, 'machine_name', p_machine_name, 'machine_id', v_machine_id,
      'error', SQLERRM, 'detected_by', 'push_plan_to_dispatch_v14_prd120_l5', 'detected_at', now()));
  END;
  BEGIN
    v_fefo_bind := public.bind_dispatch_fefo(p_plan_date, ARRAY[p_machine_name], v_user_id);
  EXCEPTION WHEN OTHERS THEN
    v_fefo_bind := jsonb_build_object('status','error','error', SQLERRM);
    INSERT INTO public.monitoring_alerts (source, severity, payload)
    VALUES ('push_fefo_bind_failure', 'warning', jsonb_build_object(
      'title', format('Multi-batch FEFO bind failed on push: %s @ %s', p_machine_name, p_plan_date),
      'plan_date', p_plan_date, 'machine_name', p_machine_name, 'machine_id', v_machine_id,
      'error', SQLERRM, 'detected_by', 'push_plan_to_dispatch_v16_prd121_p1_2', 'detected_at', now()));
  END;

  PERFORM set_config('app.rpc_name', 'push_plan_to_dispatch', true);
  PERFORM set_config('app.via_trigger', COALESCE(v_prev_via_trigger, ''), true);
  PERFORM set_config('app.mutation_reason', COALESCE(v_prev_mutation_reason, ''), true);

  RETURN jsonb_build_object(
    'status','ok',
    'machine', p_machine_name,
    'lines_pushed', v_count,
    'lines_skipped_null_product', v_skipped,
    'lines_preserved_manual_edit', v_preserved,
    'lines_pinned_at_plan_time', v_pinned_count,
    'remove_split_lines', v_remove_split,
    'procurement_gaps_logged', v_procurement_gaps,
    'm2m_transfer_pairs', v_transfer_pairs,
    'm2m_transfer_deferred', v_transfer_deferred,
    'm2m_transfer_skipped', v_transfer_skipped,
    'm2m_pairing', v_pairing,
    'weimi_slot_guard', v_slot_guard,
    'lines_tombstoned', v_tombstoned,
    'remove_flavor_corrected', v_flavor_corrected,
    'remove_no_lot_on_shelf', v_no_lot_on_shelf,
    'auto_repair_null_pod_lot', v_bulk_repair,
    'fefo_multi_batch_bind', v_fefo_bind,
    'rpc_version','v20_prd131_f2_movement_kind'
  );
END $function$;
