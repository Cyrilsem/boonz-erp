-- PRD-120 follow-up F3: add_dispatch_row never set pod_lot_id/expiry_date at all,
-- for ANY action -- it INSERTs into refill_dispatching with neither column in the list.
-- v15's flavor fallback lives entirely inside push_plan_to_dispatch; a Remove leg
-- created via add_dispatch_row (used by the field PWA "add a row not on the plan" flow
-- and by warehouse/operator manual adds) bypasses that lookup completely and lands with
-- pod_lot_id NULL every time, joining the same NULL-pod_lot_id backlog F2 just cleaned
-- up. Live example: dispatch 45d8c556-1471-44e3-97c7-3e616bda4f20, created 2026-09-10.
--
-- Fix: for p_action = 'Remove' only (Refill/Add New are byte-identical to before -- they
-- never used pod_lot_id), route through the same three-tier lookup push_plan_to_dispatch
-- v15 uses against v_pod_inventory_latest:
--   1. Exact machine+boonz_product_id match, oldest expiry first, split across lots if
--      the quantity exceeds one lot's stock (unchanged happy path).
--   2. If that finds ZERO lots at all (v_remaining = p_quantity), shelf-wide fallback:
--      same machine+shelf, ANY Active lot regardless of boonz_product_id, again split
--      across lots if needed. Each split leg's boonz_product_id becomes the lot's real
--      flavor, comment tagged [FLAVOR-CORRECTED: ...].
--   3. If neither finds anything, a single quantity=0 leg is still written (visible on
--      the manifest, no driver action implied), tagged [NO LOT ON SHELF ...].
-- A Remove can now create more than one refill_dispatching row (a real split, same
-- mechanism push_plan_to_dispatch already uses); the response's top-level dispatch_id is
-- the first leg for backward compatibility with existing callers, plus a new `legs` array
-- with every created row's full detail. Each created row gets its own edit_log entry.
--
-- Cody: approve. Articles 1 (still the sole manual-add writer, no new write path), 4
-- (role/reason guards untouched, same validations run first), 8 (every created row still
-- flows through the same INSERT + edit_log pattern, generic audit trigger fires per row),
-- 12 (forward-only; full CREATE OR REPLACE guarded by an md5 check of the live body
-- rather than a chained replace() given the scale of the branch rewrite -- Refill/Add New
-- path is byte-identical to the pre-existing INSERT).
--
-- Verified in a rolled-back transaction: a Remove naming a flavor absent from a
-- multi-flavor lane resolves to a non-NULL pod_lot_id bound to the shelf's real lot.
--
-- Companion fix: driver_add_flagged_row (PRD-053 Phase C) calls add_dispatch_row and
-- flags only (v_res->>'dispatch_id')::uuid for Head Office review. With a Remove that
-- now splits into multiple legs, every leg after the first would silently escape the
-- needs_review flag. Patched to flag every id in v_res->'legs' when present, falling
-- back to the single dispatch_id for the unchanged Refill/Add New path.

DO $mig$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p WHERE p.proname='add_dispatch_row' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'a7f6d848872e0a63be3888b343f880e0' THEN
    RAISE EXCEPTION 'add_dispatch_row drifted (md5 %), refusing blind replace', md5(v_def);
  END IF;
END $mig$;

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
  v_remaining         numeric;
  v_take              numeric;
  v_batch             RECORD;
  v_legs              jsonb := '[]'::jsonb;
  v_leg_after         jsonb;
  v_first_id          uuid;
  v_flavor_corrected  int := 0;
  v_no_lot_on_shelf   int := 0;
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

  -- p_action = 'Remove': PRD-120 F3 -- same three-tier lot lookup as
  -- push_plan_to_dispatch v15, instead of the old no-pod_lot_id single INSERT.
  v_remaining := p_quantity;
  v_first_id := NULL;

  FOR v_batch IN
    SELECT pil.expiration_date, pil.current_stock, pil.shelf_id AS lot_shelf_id, pil.pod_inventory_id
      FROM public.v_pod_inventory_latest pil
     WHERE pil.machine_id = p_machine_id
       AND pil.boonz_product_id = p_boonz_product_id
       AND pil.status = 'Active'
       AND COALESCE(pil.current_stock,0) > 0
     ORDER BY pil.expiration_date ASC NULLS LAST
  LOOP
    EXIT WHEN v_remaining <= 0;
    v_take := LEAST(v_batch.current_stock, v_remaining);
    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action,
       quantity, packed, dispatched, picked_up, returned, item_added, include,
       source_kind, source_warehouse_id, source_machine_id, is_m2m, created_by_edit,
       from_warehouse_id, expiry_date, pod_lot_id,
       last_edited_by, last_edited_by_role, last_edited_at, edit_count)
    VALUES
      (p_machine_id, COALESCE(v_batch.lot_shelf_id, v_shelf_id), v_pod_product_id, p_boonz_product_id, p_dispatch_date, p_action,
       v_take, false, false, false, false, false, true,
       p_source_kind, p_source_warehouse_id, p_source_machine_id, (p_source_kind = 'truck_transfer' OR (p_source_kind = 'm2m' AND p_source_machine_id IS DISTINCT FROM p_machine_id)), true,
       CASE WHEN p_source_kind = 'wh' THEN p_source_warehouse_id ELSE NULL END, v_batch.expiration_date, v_batch.pod_inventory_id,
       auth.uid(), p_edit_role, now(), 0)
    RETURNING dispatch_id INTO v_new_id;
    IF v_first_id IS NULL THEN v_first_id := v_new_id; END IF;
    v_leg_after := jsonb_build_object(
      'dispatch_id', v_new_id, 'machine_id', p_machine_id, 'shelf_id', COALESCE(v_batch.lot_shelf_id, v_shelf_id),
      'boonz_product_id', p_boonz_product_id, 'pod_product_id', v_pod_product_id,
      'quantity', v_take, 'action', p_action, 'pod_lot_id', v_batch.pod_inventory_id,
      'expiry_date', v_batch.expiration_date, 'flavor_corrected', false);
    v_legs := v_legs || jsonb_build_array(v_leg_after);
    INSERT INTO public.refill_dispatching_edit_log
      (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
    VALUES (v_new_id, auth.uid(), p_edit_role, 'add', NULL, v_leg_after, p_reason, p_conductor_session);
    v_remaining := v_remaining - v_take;
  END LOOP;

  IF v_remaining = p_quantity THEN
    FOR v_batch IN
      SELECT pil.expiration_date, pil.current_stock, pil.shelf_id AS lot_shelf_id,
             pil.pod_inventory_id, pil.boonz_product_id AS lot_boonz_product_id
        FROM public.v_pod_inventory_latest pil
       WHERE pil.machine_id = p_machine_id
         AND pil.shelf_id = v_shelf_id
         AND pil.status = 'Active'
         AND COALESCE(pil.current_stock,0) > 0
       ORDER BY pil.expiration_date ASC NULLS LAST
    LOOP
      EXIT WHEN v_remaining <= 0;
      v_take := LEAST(v_batch.current_stock, v_remaining);
      INSERT INTO public.refill_dispatching
        (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action,
         quantity, packed, dispatched, picked_up, returned, item_added, include, comment,
         source_kind, source_warehouse_id, source_machine_id, is_m2m, created_by_edit,
         from_warehouse_id, expiry_date, pod_lot_id,
         last_edited_by, last_edited_by_role, last_edited_at, edit_count)
      VALUES
        (p_machine_id, COALESCE(v_batch.lot_shelf_id, v_shelf_id), v_pod_product_id, v_batch.lot_boonz_product_id, p_dispatch_date, p_action,
         v_take, false, false, false, false, false, true,
         format('[FLAVOR-CORRECTED: requested %s, shelf actually holds %s]',
           (SELECT bp.boonz_product_name FROM public.boonz_products bp WHERE bp.product_id = p_boonz_product_id),
           (SELECT bp2.boonz_product_name FROM public.boonz_products bp2 WHERE bp2.product_id = v_batch.lot_boonz_product_id)),
         p_source_kind, p_source_warehouse_id, p_source_machine_id, (p_source_kind = 'truck_transfer' OR (p_source_kind = 'm2m' AND p_source_machine_id IS DISTINCT FROM p_machine_id)), true,
         CASE WHEN p_source_kind = 'wh' THEN p_source_warehouse_id ELSE NULL END, v_batch.expiration_date, v_batch.pod_inventory_id,
         auth.uid(), p_edit_role, now(), 0)
      RETURNING dispatch_id INTO v_new_id;
      IF v_first_id IS NULL THEN v_first_id := v_new_id; END IF;
      v_leg_after := jsonb_build_object(
        'dispatch_id', v_new_id, 'machine_id', p_machine_id, 'shelf_id', COALESCE(v_batch.lot_shelf_id, v_shelf_id),
        'boonz_product_id', v_batch.lot_boonz_product_id, 'pod_product_id', v_pod_product_id,
        'quantity', v_take, 'action', p_action, 'pod_lot_id', v_batch.pod_inventory_id,
        'expiry_date', v_batch.expiration_date, 'flavor_corrected', true,
        'requested_boonz_product_id', p_boonz_product_id);
      v_legs := v_legs || jsonb_build_array(v_leg_after);
      INSERT INTO public.refill_dispatching_edit_log
        (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
      VALUES (v_new_id, auth.uid(), p_edit_role, 'add', NULL, v_leg_after, p_reason, p_conductor_session);
      v_remaining := v_remaining - v_take;
      v_flavor_corrected := v_flavor_corrected + 1;
    END LOOP;
  END IF;

  IF v_remaining > 0 THEN
    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action,
       quantity, packed, dispatched, picked_up, returned, item_added, include, comment,
       source_kind, source_warehouse_id, source_machine_id, is_m2m, created_by_edit,
       from_warehouse_id,
       last_edited_by, last_edited_by_role, last_edited_at, edit_count)
    VALUES
      (p_machine_id, v_shelf_id, v_pod_product_id, p_boonz_product_id, p_dispatch_date, p_action,
       CASE WHEN v_remaining = p_quantity THEN 0 ELSE v_remaining END, false, false, false, false, false, true,
       CASE WHEN v_remaining = p_quantity
         THEN '[NO LOT ON SHELF — nothing to remove here; resolved automatically, no driver action needed]'
         ELSE '[EXPIRY-TO-CONFIRM — remainder not attributable to a known batch (PRD-053)]' END,
       p_source_kind, p_source_warehouse_id, p_source_machine_id, (p_source_kind = 'truck_transfer' OR (p_source_kind = 'm2m' AND p_source_machine_id IS DISTINCT FROM p_machine_id)), true,
       CASE WHEN p_source_kind = 'wh' THEN p_source_warehouse_id ELSE NULL END,
       auth.uid(), p_edit_role, now(), 0)
    RETURNING dispatch_id INTO v_new_id;
    IF v_first_id IS NULL THEN v_first_id := v_new_id; END IF;
    v_leg_after := jsonb_build_object(
      'dispatch_id', v_new_id, 'machine_id', p_machine_id, 'shelf_id', v_shelf_id,
      'boonz_product_id', p_boonz_product_id, 'pod_product_id', v_pod_product_id,
      'quantity', CASE WHEN v_remaining = p_quantity THEN 0 ELSE v_remaining END, 'action', p_action,
      'pod_lot_id', NULL, 'expiry_date', NULL,
      'flavor_corrected', false, 'no_lot_on_shelf', (v_remaining = p_quantity));
    v_legs := v_legs || jsonb_build_array(v_leg_after);
    INSERT INTO public.refill_dispatching_edit_log
      (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
    VALUES (v_new_id, auth.uid(), p_edit_role, 'add', NULL, v_leg_after, p_reason, p_conductor_session);
    IF v_remaining = p_quantity THEN v_no_lot_on_shelf := v_no_lot_on_shelf + 1; END IF;
  END IF;

  RETURN jsonb_build_object(
    'dispatch_id', v_first_id, 'edit_kind','add', 'legs', v_legs,
    'remove_flavor_corrected', v_flavor_corrected, 'remove_no_lot_on_shelf', v_no_lot_on_shelf,
    'rpc_version','v2_prd120_f3_lot_bind');
END
$function$;

DO $mig$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p WHERE p.proname='driver_add_flagged_row' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '8922e064393d561ce2af94aa7af13853' THEN
    RAISE EXCEPTION 'driver_add_flagged_row drifted (md5 %), refusing blind replace', md5(v_def);
  END IF;
END $mig$;

CREATE OR REPLACE FUNCTION public.driver_add_flagged_row(p_machine_id uuid, p_shelf_code text, p_boonz_product_id uuid, p_quantity numeric, p_action text, p_dispatch_date date, p_source_kind text DEFAULT 'unknown'::text, p_source_warehouse_id uuid DEFAULT NULL::uuid, p_source_machine_id uuid DEFAULT NULL::uuid, p_edit_role text DEFAULT NULL::text, p_reason text DEFAULT NULL::text, p_conductor_session text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_res  jsonb;
  v_id   uuid;
  v_n    int;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'driver_add_flagged_row', true);

  v_res := public.add_dispatch_row(
    p_machine_id, p_shelf_code, p_boonz_product_id, p_quantity, p_action,
    p_dispatch_date, p_source_kind, p_source_warehouse_id, p_source_machine_id,
    p_edit_role, COALESCE(p_reason, 'driver addition beyond plan (PRD-053)'), p_conductor_session);

  IF v_res ? 'legs' AND jsonb_array_length(v_res->'legs') > 0 THEN
    PERFORM set_config('app.mutation_reason',
      COALESCE(p_reason, 'PRD-053 driver addition flagged for Head Office review'), true);
    UPDATE public.refill_dispatching
       SET needs_review  = true,
           review_reason = 'driver_addition',
           review_status = 'pending'
     WHERE dispatch_id IN (
       SELECT (leg->>'dispatch_id')::uuid FROM jsonb_array_elements(v_res->'legs') leg
     );
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_res || jsonb_build_object('needs_review', true, 'review_reason', 'driver_addition', 'review_status', 'pending', 'flagged_legs', v_n);
  END IF;

  v_id := (v_res->>'dispatch_id')::uuid;
  IF v_id IS NULL THEN
    RETURN v_res;
  END IF;

  PERFORM set_config('app.mutation_reason',
    COALESCE(p_reason, 'PRD-053 driver addition flagged for Head Office review'), true);
  UPDATE public.refill_dispatching
     SET needs_review  = true,
         review_reason = 'driver_addition',
         review_status = 'pending'
   WHERE dispatch_id = v_id;

  RETURN v_res || jsonb_build_object('needs_review', true, 'review_reason', 'driver_addition', 'review_status', 'pending');
END;
$function$;
