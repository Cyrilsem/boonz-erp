-- PRD-120 follow-up G4: L2 substitution (substitute_dispatch_line), warehouse_manager path.
--
-- Live case found 2026-09-11: AMZ-1029 A01, dispatch 4d8e6182 (Zigi Hot Chili, qty 4,
-- PACKED, PINNED) superseded_by a4027459 (Zigi Sea Salted, qty 3, PACKED, pod_lot NULL
-- pin), comment "SUBSTITUTED (relinked) by warehouse_manager". Two real defects, both in
-- substitute_dispatch_line itself, not in the two live rows (which are packed and are NOT
-- touched by this migration):
--
-- 1. The ORIGINAL row is never neutralized. substitute_dispatch_line was designed to keep
--    the original row's product/pod/pin untouched as history (correct) -- but it also
--    never excludes the original from live lane-capacity accounting. Both the original
--    (qty 4) and the replacement (qty 3) stay `include=true`, so anything summing "what's
--    incoming to this shelf" double-counts 7 units for what is operationally ONE delivery
--    of 3 units -- on a lane holding 5 with a 9 cap, that's a real overfill. Fix: the same
--    UPDATE that already sets superseded_by on the original now also sets it skipped
--    (skipped=true, skipped_at, skipped_by, skip_reason, include=false) -- the canonical
--    skip_dispatch_line shape, so every reader that already excludes skipped/not-included
--    rows (which is most of them) stops double-counting it. The row's own quantity and
--    product are left untouched, preserving it as history exactly as designed.
--
-- 2. The replacement's warehouse pin lookup, `pick_wh_batch_for_machine(...)`, has no
--    serving-warehouse restriction at all -- it searches EVERY warehouse in the system.
--    Live repro: calling it today for the same (product, machine, qty) picks a WH_MCC
--    batch even though AMZ-1029's primary_warehouse_id is WH_CENTRAL only (no secondary)
--    -- a batch that warehouse doesn't serve is not a real, deliverable pin. Fix: restrict
--    the picked batch to the machine's own primary/secondary warehouse(s), same model
--    push_plan_to_dispatch's v_wh_candidates already uses (cold-chain routing NOT
--    replicated here -- out of scope, no evidence it's broken for this path).
--
-- 3. When #2 still finds nothing (genuinely no deliverable batch), the function silently
--    inserted the replacement with from_wh_inventory_id NULL, flagged needs_review. The
--    2026-09-07 L2 migration's own comment named this "a policy call for CS, not something
--    to flip unilaterally" -- CS is now making that call for the warehouse_manager path
--    specifically: a warehouse_manager-initiated substitution must RAISE, not silently
--    create an unpinned ghost row. The field_staff/driver path is UNCHANGED -- PRD-112's
--    "never a hard block on the driver" doctrine still holds for driver-initiated
--    substitutions, which keep the existing needs_review/spot-buy fallback.
--
-- Cody: approve. Articles 1 (still the sole substitution writer, no new write path), 4
-- (role/reason guards unchanged, all run before the new logic), 12 (forward-only full
-- CREATE OR REPLACE, guarded by md5 check of the live body -- same justification as the
-- add_dispatch_row rewrite: the change touches multiple non-adjacent parts of the body,
-- a byte-anchored replace() chain would be less legible than the full corrected text).
--
-- Verified in a rolled-back transaction: a fixture substitution on a synthetic row
-- resolves to one row out (pinned, to a serving-warehouse batch), original skipped with a
-- reason recorded.

DO $mig$ DECLARE v_def text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p WHERE p.proname='substitute_dispatch_line' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'b36e3c796b0216aafd3789da53b56869' THEN
    RAISE EXCEPTION 'substitute_dispatch_line drifted (md5 %), refusing blind replace', md5(v_def);
  END IF;
END $mig$;

CREATE OR REPLACE FUNCTION public.substitute_dispatch_line(
  p_dispatch_id uuid, p_new_boonz_product_id uuid, p_filled_qty numeric, p_reason text,
  p_actor uuid DEFAULT NULL, p_source_tag text DEFAULT NULL, p_dry_run boolean DEFAULT true
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_caller       uuid := (SELECT auth.uid());
  v_role         text;
  v_edit_role    text;
  v_actor        uuid;
  v_row          public.refill_dispatching%ROWTYPE;
  v_today        date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  v_old_name     text;
  v_new_name     text;
  v_new_pod      uuid;
  v_new_pod_name text;
  v_machine_name text;
  v_shelf_code   text;
  v_supply       text;
  v_needs_review boolean := false;
  v_review_rsn   text    := NULL;
  v_new_wh_inv   uuid    := NULL;
  v_new_expiry   date    := NULL;
  v_venue_line   boolean := false;
  v_pack_outcome public.pack_outcome_enum;
  v_comment      text;
  v_skip_reason  text;
  v_new_dispatch_id uuid;
  v_driver_name  text;
  v_event_id     uuid;
  v_gap_event_id uuid := NULL;
  v_pick         record;
  v_primary_wh   uuid;
  v_secondary_wh uuid;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'substitute_dispatch_line', true);

  IF p_dispatch_id IS NULL THEN RAISE EXCEPTION 'substitute_dispatch_line: p_dispatch_id required'; END IF;
  IF p_new_boonz_product_id IS NULL THEN RAISE EXCEPTION 'substitute_dispatch_line: p_new_boonz_product_id required'; END IF;
  IF p_filled_qty IS NULL OR p_filled_qty <= 0 THEN
    RAISE EXCEPTION 'substitute_dispatch_line: p_filled_qty must be > 0 (a zero fill is the not-filled flow, not a substitution)';
  END IF;
  IF p_source_tag IS NOT NULL AND p_source_tag NOT IN ('venue','wh','spot') THEN
    RAISE EXCEPTION 'substitute_dispatch_line: p_source_tag must be venue | wh | spot (got %)', p_source_tag;
  END IF;

  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'substitute_dispatch_line: anonymous caller refused';
  END IF;
  SELECT up.role INTO v_role FROM public.user_profiles up WHERE up.id = v_caller;
  IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'substitute_dispatch_line: role % not authorized', COALESCE(v_role,'none');
  END IF;

  IF p_actor IS NOT NULL AND p_actor <> v_caller AND v_role NOT IN ('operator_admin','superadmin','manager') THEN
    v_actor := v_caller;
  ELSE
    v_actor := COALESCE(p_actor, v_caller);
  END IF;
  v_edit_role := CASE WHEN v_role = 'field_staff' THEN 'driver'
                      WHEN v_role = 'warehouse'   THEN 'warehouse_manager'
                      ELSE v_role END;

  SELECT * INTO v_row FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'substitute_dispatch_line: dispatch % not found', p_dispatch_id; END IF;

  IF v_row.dispatch_date < v_today THEN
    RAISE EXCEPTION 'substitute_dispatch_line: dispatch % is dated % and today (Dubai) is % - a closed day cannot be substituted',
      p_dispatch_id, v_row.dispatch_date, v_today;
  END IF;
  IF COALESCE(v_row.cancelled, false) OR COALESCE(v_row.skipped, false) OR COALESCE(v_row.returned, false) THEN
    RAISE EXCEPTION 'substitute_dispatch_line: dispatch % is cancelled/skipped/returned - nothing to substitute', p_dispatch_id;
  END IF;
  IF v_row.superseded_by IS NOT NULL THEN
    RAISE EXCEPTION 'substitute_dispatch_line: dispatch % was already superseded by %', p_dispatch_id, v_row.superseded_by;
  END IF;
  IF COALESCE(v_row.action,'') NOT IN ('Refill','Add New') THEN
    RAISE EXCEPTION 'substitute_dispatch_line: action % is not substitutable (Refill / Add New only)', COALESCE(v_row.action,'<null>');
  END IF;
  IF v_row.boonz_product_id = p_new_boonz_product_id THEN
    RAISE EXCEPTION 'substitute_dispatch_line: new product is the product already on the line - use repin_dispatch_batch for a same-product batch change';
  END IF;

  SELECT bp.boonz_product_name INTO v_new_name FROM public.boonz_products bp WHERE bp.product_id = p_new_boonz_product_id;
  IF v_new_name IS NULL THEN RAISE EXCEPTION 'substitute_dispatch_line: boonz product % not found', p_new_boonz_product_id; END IF;
  SELECT bp.boonz_product_name INTO v_old_name FROM public.boonz_products bp WHERE bp.product_id = v_row.boonz_product_id;

  SELECT up.full_name INTO v_driver_name FROM public.user_profiles up WHERE up.id = v_actor;
  SELECT m.official_name, m.primary_warehouse_id, m.secondary_warehouse_id
    INTO v_machine_name, v_primary_wh, v_secondary_wh
  FROM public.machines m WHERE m.machine_id = v_row.machine_id;
  SELECT sc.shelf_code INTO v_shelf_code FROM public.shelf_configurations sc WHERE sc.shelf_id = v_row.shelf_id;

  SELECT sl.pod_product_id INTO v_new_pod
  FROM public.slot_lifecycle sl
  WHERE sl.machine_id = v_row.machine_id AND sl.shelf_id = v_row.shelf_id
    AND sl.is_current = true AND sl.archived = false
    AND EXISTS (SELECT 1 FROM public.product_mapping pm2
      WHERE pm2.pod_product_id = sl.pod_product_id AND pm2.boonz_product_id = p_new_boonz_product_id AND pm2.status = 'Active')
  ORDER BY sl.rotated_in_at DESC NULLS LAST LIMIT 1;

  IF v_new_pod IS NULL THEN
    SELECT pm.pod_product_id INTO v_new_pod
    FROM public.product_mapping pm
    WHERE pm.boonz_product_id = p_new_boonz_product_id AND pm.status = 'Active'
      AND (pm.machine_id = v_row.machine_id OR pm.machine_id IS NULL)
    ORDER BY (pm.machine_id = v_row.machine_id) DESC NULLS LAST, pm.is_global_default DESC LIMIT 1;
  END IF;

  IF v_new_pod IS NULL THEN
    v_new_pod := v_row.pod_product_id;
    v_needs_review := true;
    v_review_rsn := 'substitution_unmapped_product';
  END IF;
  SELECT pp.pod_product_name INTO v_new_pod_name FROM public.pod_products pp WHERE pp.pod_product_id = v_new_pod;

  SELECT pm.source_of_supply INTO v_supply
  FROM public.product_mapping pm
  WHERE pm.boonz_product_id = p_new_boonz_product_id AND pm.status = 'Active'
    AND (pm.machine_id = v_row.machine_id OR pm.machine_id IS NULL)
  ORDER BY (pm.machine_id = v_row.machine_id) DESC NULLS LAST, pm.is_global_default DESC LIMIT 1;

  v_venue_line := (v_row.source_origin = 'vox_at_venue'::public.source_origin_enum)
                  OR v_supply = 'venue_team' OR p_source_tag = 'venue';

  IF v_venue_line THEN
    SELECT wi.wh_inventory_id, wi.expiration_date INTO v_new_wh_inv, v_new_expiry
    FROM public.warehouse_inventory wi
    WHERE wi.boonz_product_id = p_new_boonz_product_id AND wi.wh_location = 'VOX_SOURCED' AND wi.status = 'Active'
    ORDER BY wi.expiration_date ASC NULLS LAST LIMIT 1;
  ELSE
    -- PRD-120 G4 fix: restrict to the machine's own serving warehouse(s). The unrestricted
    -- pick_wh_batch_for_machine() call previously let a substitution pin to a warehouse
    -- that doesn't physically serve this machine (live repro: AMZ-1029, primary=WH_CENTRAL
    -- only, picked a WH_MCC batch) -- not a real, deliverable pin.
    SELECT p.wh_inventory_id, p.expiration_date INTO v_pick
    FROM public.pick_wh_batch_for_machine(p_new_boonz_product_id, v_row.machine_id, p_filled_qty, NULL) p
    JOIN public.warehouse_inventory wi2 ON wi2.wh_inventory_id = p.wh_inventory_id
    WHERE wi2.warehouse_id = ANY (ARRAY[v_primary_wh, v_secondary_wh])
    ORDER BY p.pick_rank LIMIT 1;
    IF v_pick IS NOT NULL THEN
      v_new_wh_inv := v_pick.wh_inventory_id;
      v_new_expiry := v_pick.expiration_date;
    END IF;
  END IF;

  IF v_new_wh_inv IS NULL THEN
    -- PRD-120 G4: a warehouse_manager-initiated substitution must never leave a Refill /
    -- Add New line unpinned -- refuse rather than create a ghost row. The driver/field_staff
    -- path is untouched: PRD-112's "never a hard block on the driver" doctrine still holds,
    -- so it keeps the existing needs_review / spot-buy fallback with a possibly-NULL pin.
    IF v_edit_role = 'warehouse_manager' THEN
      RAISE EXCEPTION 'substitute_dispatch_line: no deliverable warehouse batch found for % at % (serving warehouse(s) only) - a warehouse_manager substitution must pin a real batch, not an unpinned ghost row',
        v_new_name, COALESCE(v_machine_name, v_row.machine_id::text);
    END IF;
    v_needs_review := true;
    v_review_rsn := COALESCE(v_review_rsn, CASE WHEN p_source_tag = 'spot' THEN 'substitution_spot_buy' ELSE 'substitution_stock_unverified' END);
  END IF;

  v_pack_outcome := v_row.pack_outcome;
  IF v_pack_outcome = 'not_filled'::public.pack_outcome_enum THEN
    v_pack_outcome := CASE WHEN p_filled_qty >= COALESCE(v_row.quantity, 0) THEN 'packed'::public.pack_outcome_enum ELSE 'partial'::public.pack_outcome_enum END;
  END IF;

  v_comment := format('SUBSTITUTED (relinked) by %s: %s -> %s (%s)', v_edit_role,
    COALESCE(v_old_name, '?'), v_new_name, COALESCE(NULLIF(btrim(COALESCE(p_reason,'')), ''), 'no reason given'));
  v_skip_reason := format('superseded by substitution %s -> %s', COALESCE(v_old_name,'?'), v_new_name);

  IF p_dry_run THEN
    RETURN jsonb_build_object('status','dry_run_ok','dispatch_id',p_dispatch_id,
      'old_product', v_old_name, 'new_product', v_new_name,
      'new_wh_inventory_id', v_new_wh_inv, 'new_expiry', v_new_expiry,
      'needs_review', v_needs_review, 'review_reason', v_review_rsn, 'venue_line', v_venue_line,
      'original_will_be_skipped', true, 'skip_reason', v_skip_reason);
  END IF;

  PERFORM set_config('app.mutation_reason', v_comment, true);

  INSERT INTO public.refill_dispatching (
    dispatch_date, machine_id, shelf_id, boonz_product_id, pod_product_id, action, quantity,
    filled_quantity, from_wh_inventory_id, from_warehouse_id, expiry_date, source_origin,
    packed, picked_up, pack_outcome, driver_confirmed_qty, driver_confirmed_at, driver_confirmed_by,
    original_boonz_product_id, include, comment, needs_review, review_status, review_reason,
    last_edited_by, last_edited_by_role, last_edited_at
  ) VALUES (
    v_row.dispatch_date, v_row.machine_id, v_row.shelf_id, p_new_boonz_product_id, v_new_pod, v_row.action, p_filled_qty,
    p_filled_qty, v_new_wh_inv, v_row.from_warehouse_id, v_new_expiry,
    CASE WHEN v_venue_line THEN 'vox_at_venue'::public.source_origin_enum ELSE v_row.source_origin END,
    v_row.packed, v_row.picked_up, v_pack_outcome, p_filled_qty, now(), v_actor,
    COALESCE(v_row.original_boonz_product_id, v_row.boonz_product_id), true, v_comment,
    v_needs_review, CASE WHEN v_needs_review THEN 'pending' ELSE 'none' END, v_review_rsn,
    v_caller, v_edit_role, now()
  ) RETURNING dispatch_id INTO v_new_dispatch_id;

  -- PRD-120 G4 fix: neutralize the original row's contribution to live lane-capacity
  -- accounting (skipped=true, include=false), same shape skip_dispatch_line already uses,
  -- while preserving its product/pin as untouched history exactly as before.
  UPDATE public.refill_dispatching
     SET superseded_by       = v_new_dispatch_id,
         comment             = CASE WHEN COALESCE(btrim(comment),'') = '' THEN v_comment ELSE comment || E'\n' || v_comment END,
         skipped             = true,
         skipped_at          = now(),
         skipped_by          = v_caller,
         skip_reason         = v_skip_reason,
         include             = false,
         edit_count          = COALESCE(edit_count, 0) + 1,
         last_edited_by      = v_caller,
         last_edited_by_role = v_edit_role,
         last_edited_at      = now()
   WHERE dispatch_id = p_dispatch_id;

  UPDATE public.refill_plan_output
     SET boonz_product_id = p_new_boonz_product_id, boonz_product_name = v_new_name,
         pod_product_id = v_new_pod, pod_product_name = COALESCE(v_new_pod_name, pod_product_name)
   WHERE dispatch_id = p_dispatch_id;

  INSERT INTO public.refill_dispatching_edit_log
    (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
  VALUES
    (p_dispatch_id, v_caller, v_edit_role, 'product',
     jsonb_build_object('boonz_product_id', v_row.boonz_product_id, 'boonz_product_name', v_old_name),
     jsonb_build_object('superseded_by', v_new_dispatch_id, 'new_boonz_product_id', p_new_boonz_product_id, 'new_boonz_product_name', v_new_name,
       'skipped', true, 'skip_reason', v_skip_reason),
     COALESCE(p_reason, 'substitution'), NULL);

  INSERT INTO public.day_close_events (event_date, machine_id, dispatch_id, kind, payload, created_by)
  VALUES (v_row.dispatch_date, v_row.machine_id, v_new_dispatch_id, 'substitution',
    jsonb_build_object('machine_name', v_machine_name, 'shelf_code', v_shelf_code, 'shelf_id', v_row.shelf_id,
      'old_dispatch_id', p_dispatch_id, 'old_boonz_product_id', v_row.boonz_product_id, 'old_boonz_product_name', v_old_name,
      'new_boonz_product_id', p_new_boonz_product_id, 'new_boonz_product_name', v_new_name,
      'planned_qty', v_row.quantity, 'filled_qty', p_filled_qty, 'reason', p_reason, 'source_tag', p_source_tag,
      'venue_line', v_venue_line, 'driver', v_actor, 'driver_name', v_driver_name,
      'needs_review', v_needs_review, 'review_reason', v_review_rsn,
      'new_from_wh_inventory_id', v_new_wh_inv), v_caller)
  RETURNING id INTO v_event_id;

  IF v_needs_review AND v_review_rsn IN ('substitution_spot_buy','substitution_stock_unverified') THEN
    INSERT INTO public.day_close_events (event_date, machine_id, dispatch_id, kind, payload, created_by)
    VALUES (v_row.dispatch_date, v_row.machine_id, v_new_dispatch_id,
      CASE WHEN v_review_rsn = 'substitution_spot_buy' THEN 'spot_buy' ELSE 'stock_unverified' END,
      jsonb_build_object('machine_name', v_machine_name, 'shelf_code', v_shelf_code, 'new_boonz_product_name', v_new_name,
        'filled_qty', p_filled_qty, 'review_reason', v_review_rsn, 'substitution_event_id', v_event_id), v_caller)
    RETURNING id INTO v_gap_event_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'old_dispatch_id', p_dispatch_id, 'new_dispatch_id', v_new_dispatch_id,
    'machine_name', v_machine_name, 'shelf_code', v_shelf_code,
    'old_product', v_old_name, 'new_product', v_new_name,
    'new_wh_inventory_id', v_new_wh_inv, 'needs_review', v_needs_review, 'review_reason', v_review_rsn,
    'original_skipped', true, 'skip_reason', v_skip_reason,
    'day_close_event_id', v_event_id, 'gap_event_id', v_gap_event_id, 'comment', v_comment);
END
$function$;
