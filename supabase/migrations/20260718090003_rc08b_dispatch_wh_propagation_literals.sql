-- ============================================================================
-- 20260718090003_rc08b_dispatch_wh_propagation_literals.sql
-- RC-08 MIGRATION B — dispatch WH propagation + hardcoded-literal removal + FEFO/
-- quarantine/expiry label & guard fixes.
--
-- Closes Cody condition:
--   B3  approve_refill_plan is NOT touched here (it is owned by RC-01, which dropped
--       its Step-3 literal). This migration replaces exactly the 8 REMAINING
--       WH_CENTRAL literal sites (9 total − approve). Verified 2026-07-18 the 9 sites
--       are: approve_refill_plan (RC-01), + these 8:
--         (full rewrite, semantic credit-target fix)
--           1. receive_dispatch_line
--           2. return_dispatch_line
--         (de-magic only — literal -> public.wh_central_id(), behaviour-identical)
--           3. auto_generate_refill_plan   (cold-route stamp)
--           4. bind_dispatch_fefo          (COALESCE fallback)
--           5. inject_swap                 (cold-route stamp)
--           6. pack_dispatch_line          (COALESCE fallback)
--           7. receive_purchase_order      (default receiving WH var)
--           8. set_machine_warehouse       (default primary var)
--
-- Also (not literal sites, but the RC-08 propagation + label/guard fixes):
--   - add_dispatch_row: propagate the operator's source WH into from_warehouse_id
--     (was left NULL -> downstream receive/return fell back to WH_CENTRAL). This is
--     what makes the credit-target fix below actually route correctly going forward.
--   - pick_wh_batch_for_machine: add QUAR + not-expired guards; relabel the
--     'unreserved_fifo' pick_reason -> 'unreserved_fefo' (behaviour was already FEFO).
--   - log_manual_refill: exclude quarantined/expired rows from the FEFO draw.
--
-- SCOPING NOTE (explicit, per DARA brief): the 6 de-magic sites are swapped
-- PROGRAMMATICALLY from their LIVE definitions (pg_get_functiondef) at apply time —
-- a single deterministic replacement of the unique 36-char literal. This is safer
-- and more faithful than hand-transcribing 6 large bodies (the repo lags prod). For
-- receive_purchase_order and set_machine_warehouse, RC-08 §8-B's stronger ask
-- (make the WH an EXPLICIT parameter / required default instead of any constant) is
-- a signature/behaviour change beyond a de-magic and is scoped as FOLLOW-UP
-- TICKET RC-08-B2 (not Batch 1).
--
-- BEHAVIOUR CHANGE (receive/return): a NULL from_warehouse_id on a machine with NULL
-- primary_warehouse_id now RAISES instead of silently crediting WH_CENTRAL. Blast
-- radius 2026-07-18 = 0 (null_primary=0 across the active fleet). This is the point:
-- "never silently pick central."
--
-- May apply in the SAME off-peak window as RC-01 (recommended) or immediately after.
-- Not part of the RC-01 pin-atomicity requirement. See APPLY_ORDER.md.
-- Protected entities: refill_dispatching, warehouse_inventory, pod_inventory. Cody review req.
-- Live bodies pulled 2026-07-18; UNCHANGED logic reproduced byte-faithful.
-- ============================================================================
BEGIN;

-- ── B-1: add_dispatch_row — propagate source WH into from_warehouse_id ────────
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

  -- >>> FIX D START — resolve pod from the SHELF BINDING, not the mapping default <<<
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
  -- >>> FIX D END <<<

  INSERT INTO public.refill_dispatching
    (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action,
     quantity, packed, dispatched, picked_up, returned, item_added, include,
     source_kind, source_warehouse_id, source_machine_id, is_m2m, created_by_edit,
     from_warehouse_id,                                                              -- RC-08 B-1: propagate route WH
     last_edited_by, last_edited_by_role, last_edited_at, edit_count)
  VALUES
    (p_machine_id, v_shelf_id, v_pod_product_id, p_boonz_product_id, p_dispatch_date, p_action,
     p_quantity, false, false, false, false, false, true,
     p_source_kind, p_source_warehouse_id, p_source_machine_id, (p_source_kind IN ('m2m','truck_transfer')), true,
     CASE WHEN p_source_kind = 'wh' THEN p_source_warehouse_id ELSE NULL END,        -- RC-08 B-1
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

-- ── B-2: pick_wh_batch_for_machine — QUAR + not-expired guards + FEFO label ───
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
      WHEN reserved_for_machine_id IS NULL THEN 'unreserved_fefo'                    -- RC-08 B-2: label matches FEFO order
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
    AND NOT COALESCE(quarantined, false)                                            -- RC-08 B-2: QUAR
    AND (expiration_date IS NULL
         OR expiration_date >= (now() AT TIME ZONE 'Asia/Dubai')::date)             -- RC-08 B-2: not-expired (Dubai basis, matches v_wh_pickable)
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

-- ── B-3: log_manual_refill — exclude quarantined/expired from the FEFO draw ───
CREATE OR REPLACE FUNCTION public.log_manual_refill(p_machine_name text, p_source_warehouse_id uuid, p_refill_date date, p_lines jsonb, p_reason text DEFAULT 'manual_refill_backlog'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role text; v_machine_id uuid; v_wh_name text; v_line jsonb; v_bpid uuid; v_qty numeric; v_exp date; v_shelf_code text; v_shelf_id uuid; v_product_name text;
  v_remaining numeric; v_src_row warehouse_inventory%ROWTYPE; v_pick numeric; v_pod_id uuid;
  v_lines_processed int := 0; v_total_units numeric := 0; v_wh_decremented numeric := 0; v_results jsonb := '[]'::jsonb;
  v_new_purchase boolean; v_new_wh_id uuid;  -- PRD-036 Phase B
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'log_manual_refill', true);
  PERFORM set_config('app.provenance_reason', 'manual_adjust', true);
  SELECT role INTO v_role FROM user_profiles WHERE id = auth.uid();
  IF v_role IS NULL OR v_role NOT IN ('warehouse', 'operator_admin', 'superadmin', 'manager') THEN RAISE EXCEPTION 'Unauthorized: role "%" cannot log manual refills', COALESCE(v_role, 'none'); END IF;
  SELECT machine_id INTO v_machine_id FROM machines WHERE official_name = p_machine_name;
  IF v_machine_id IS NULL THEN RAISE EXCEPTION 'Machine "%" not found', p_machine_name; END IF;
  SELECT name INTO v_wh_name FROM warehouses WHERE warehouse_id = p_source_warehouse_id;
  IF v_wh_name IS NULL THEN RAISE EXCEPTION 'Warehouse % not found', p_source_warehouse_id; END IF;
  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN RAISE EXCEPTION 'p_lines must be a non-empty JSON array'; END IF;
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_bpid := (v_line->>'boonz_product_id')::uuid;
    v_qty := (v_line->>'qty')::numeric;
    v_exp := (v_line->>'expiration_date')::date;
    v_shelf_code := v_line->>'shelf_code';
    v_new_purchase := COALESCE((v_line->>'new_purchase')::boolean, false);  -- PRD-036 Phase B
    IF v_bpid IS NULL THEN RAISE EXCEPTION 'boonz_product_id required in every line'; END IF;
    IF v_qty IS NULL OR v_qty <= 0 THEN RAISE EXCEPTION 'qty must be > 0'; END IF;
    IF v_shelf_code IS NULL THEN RAISE EXCEPTION 'shelf_code required in every line'; END IF;
    IF v_new_purchase AND v_exp IS NULL THEN RAISE EXCEPTION 'new_purchase line requires expiration_date (boonz_product %)', v_bpid; END IF;
    SELECT boonz_product_name INTO v_product_name FROM boonz_products WHERE product_id = v_bpid;
    IF v_product_name IS NULL THEN RAISE EXCEPTION 'boonz_product_id % not found', v_bpid; END IF;
    SELECT shelf_id INTO v_shelf_id FROM shelf_configurations WHERE machine_id = v_machine_id AND shelf_code = v_shelf_code;
    v_remaining := v_qty;

    IF v_new_purchase THEN
      INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id)
      VALUES (v_bpid, v_qty, v_exp, 'Active', format('NEW-PURCHASE-%s', p_refill_date), CURRENT_DATE, p_source_warehouse_id)
      RETURNING wh_inventory_id INTO v_new_wh_id;
      PERFORM set_config('app.source_event_id', v_new_wh_id::text, true);
      INSERT INTO inventory_audit_log (wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason)
      VALUES (v_new_wh_id, v_bpid, auth.uid(), 0, v_qty, format('Manual NEW PURCHASE receipt at %s: %s units of %s (exp %s) — %s', v_wh_name, v_qty, v_product_name, v_exp, p_reason));
      UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) - v_qty WHERE wh_inventory_id = v_new_wh_id;
      INSERT INTO inventory_audit_log (wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason)
      VALUES (v_new_wh_id, v_bpid, auth.uid(), v_qty, 0, format('Manual NEW PURCHASE OUT to %s/%s: %s units of %s — %s', p_machine_name, v_shelf_code, v_qty, v_product_name, p_reason));
      v_remaining := 0;
      v_wh_decremented := v_wh_decremented + v_qty;
    ELSE
      -- RC-08 B-3: exclude quarantined + expired rows from the FEFO draw (was: any Active w/ stock)
      FOR v_src_row IN SELECT * FROM warehouse_inventory WHERE boonz_product_id = v_bpid AND warehouse_id = p_source_warehouse_id AND status = 'Active' AND COALESCE(warehouse_stock, 0) > 0 AND NOT COALESCE(quarantined, false) AND (expiration_date >= p_refill_date OR expiration_date IS NULL) ORDER BY expiration_date ASC NULLS LAST, created_at ASC FOR UPDATE LOOP
        EXIT WHEN v_remaining <= 0;
        v_pick := LEAST(v_remaining, v_src_row.warehouse_stock);
        PERFORM set_config('app.source_event_id', v_src_row.wh_inventory_id::text, true);
        UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) - v_pick WHERE wh_inventory_id = v_src_row.wh_inventory_id;
        INSERT INTO inventory_audit_log (wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason) VALUES (v_src_row.wh_inventory_id, v_bpid, auth.uid(), v_src_row.warehouse_stock, v_src_row.warehouse_stock - v_pick, format('Manual refill OUT to %s/%s: %s units of %s — %s', p_machine_name, v_shelf_code, v_pick, v_product_name, p_reason));
        v_remaining := v_remaining - v_pick;
        v_wh_decremented := v_wh_decremented + v_pick;
      END LOOP;
    END IF;

    INSERT INTO pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, estimated_remaining, expiration_date, batch_id, status, snapshot_at) VALUES (v_machine_id, v_shelf_id, v_bpid, p_refill_date, v_qty, v_qty, v_exp, CASE WHEN v_new_purchase THEN format('NEW-PURCHASE-%s', p_refill_date) ELSE format('MANUAL-REFILL-%s', p_refill_date) END, 'Active', now()) RETURNING pod_inventory_id INTO v_pod_id;
    INSERT INTO pod_inventory_audit_log (pod_inventory_id, machine_id, shelf_id, boonz_product_id, expiration_date, source, operation, old_stock, new_stock, delta, old_status, new_status, actor, reference_id, notes) VALUES (v_pod_id, v_machine_id, v_shelf_id, v_bpid, v_exp, 'refill', 'insert', 0, v_qty, v_qty, NULL, 'Active', auth.uid(), format('manual-refill-%s-%s', p_machine_name, p_refill_date), format('%s: %s x %s on %s — %s%s', v_product_name, v_qty, v_shelf_code, p_refill_date, p_reason, CASE WHEN v_new_purchase THEN ' [new purchase]' ELSE '' END));
    v_lines_processed := v_lines_processed + 1;
    v_total_units := v_total_units + v_qty;
    v_results := v_results || jsonb_build_object('shelf_code', v_shelf_code, 'product', v_product_name, 'qty', v_qty, 'pod_inventory_id', v_pod_id, 'new_purchase', v_new_purchase, 'wh_decremented', v_qty - GREATEST(v_remaining, 0), 'wh_shortfall', GREATEST(v_remaining, 0));
  END LOOP;
  RETURN jsonb_build_object('status', 'ok', 'machine', p_machine_name, 'source_warehouse', v_wh_name, 'refill_date', p_refill_date, 'lines_processed', v_lines_processed, 'total_units_to_pod', v_total_units, 'total_wh_decremented', v_wh_decremented, 'shortfall_warning', CASE WHEN v_wh_decremented < v_total_units THEN format('WH had %s less than the %s refilled — physical count may be needed', v_total_units - v_wh_decremented, v_total_units) ELSE NULL END, 'details', v_results);
END;
$function$;

-- ── B-4: receive_dispatch_line — credit target from the dispatch's machine ────
-- (was: silent WH_CENTRAL fallback -> mis-credited VOX returns). RAISE if unresolvable.
CREATE OR REPLACE FUNCTION public.receive_dispatch_line(p_dispatch_id uuid, p_filled_quantity numeric, p_received_by uuid DEFAULT NULL::uuid, p_batch_breakdown jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_dispatch refill_dispatching%ROWTYPE;
  v_planned numeric; v_return_delta numeric; v_overfill numeric;
  v_consumer_row warehouse_inventory%ROWTYPE;
  v_wh_row warehouse_inventory%ROWTYPE;
  v_pod_id uuid; v_consumer_drawn numeric := 0; v_path text;
  v_target_wh uuid; v_pod_archived int := 0;                                         -- RC-08 B-4: v_default_wh literal removed
  v_breakdown_total numeric := 0;
  v_entry jsonb; v_entry_qty numeric; v_entry_expiry date; v_entry_wh_id uuid;
  v_existing_row warehouse_inventory%ROWTYPE;
  v_credit_summary jsonb := '[]'::jsonb;
  v_effective_expiry date;
  v_prior_active_merged int := 0;
  v_supply text;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'receive_dispatch_line', true);
  PERFORM set_config('app.provenance_reason', 'dispatch_receive', true);
  PERFORM set_config('app.source_event_id', p_dispatch_id::text, true);
  SELECT * INTO v_dispatch FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.item_added = true THEN RAISE EXCEPTION 'Dispatch % already received', p_dispatch_id; END IF;
  IF p_filled_quantity < 0 THEN RAISE EXCEPTION 'filled_quantity cannot be negative'; END IF;
  v_planned := v_dispatch.quantity;
  v_return_delta := GREATEST(v_planned - p_filled_quantity, 0);
  v_overfill := GREATEST(p_filled_quantity - v_planned, 0);
  v_path := 'b2_fallback';
  -- RC-08 B-4: credit target = the row's own route WH, else the machine's primary WH.
  -- Never the hardcoded WH_CENTRAL. If unresolvable, RAISE (do not silently pick central).
  v_target_wh := COALESCE(
    v_dispatch.from_warehouse_id,
    (SELECT primary_warehouse_id FROM public.machines WHERE machine_id = v_dispatch.machine_id));
  IF v_target_wh IS NULL THEN
    RAISE EXCEPTION 'receive_dispatch_line: cannot resolve credit warehouse for dispatch % (from_warehouse_id NULL and machine % has no primary_warehouse_id). Refusing to silently credit WH_CENTRAL.', p_dispatch_id, v_dispatch.machine_id;
  END IF;
  IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN
    SELECT expiration_date INTO v_effective_expiry FROM warehouse_inventory WHERE wh_inventory_id = v_dispatch.from_wh_inventory_id;
  ELSE
    v_effective_expiry := v_dispatch.expiry_date;
  END IF;
  PERFORM set_config('app.mutation_reason', format('B3 receive: dispatch %s — filled %s / planned %s by %s (breakdown=%s, effective_expiry=%s)', p_dispatch_id, p_filled_quantity, v_planned, COALESCE(p_received_by::text, 'system'), p_batch_breakdown IS NOT NULL, v_effective_expiry), true);
  IF v_dispatch.action IN ('Refill','Add New','Add') THEN
   IF NOT COALESCE(v_dispatch.is_m2m, false) THEN
    IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN
      SELECT * INTO v_consumer_row FROM warehouse_inventory WHERE wh_inventory_id = v_dispatch.from_wh_inventory_id FOR UPDATE;
      IF FOUND AND COALESCE(v_consumer_row.consumer_stock, 0) > 0 THEN v_path := 'b3_consumer_pinned'; ELSE v_consumer_row := NULL; END IF;
    END IF;
    IF v_consumer_row.wh_inventory_id IS NULL THEN
      SELECT * INTO v_consumer_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND COALESCE(consumer_stock, 0) > 0 AND (reserved_for_machine_id = v_dispatch.machine_id OR reserved_for_machine_id IS NULL) AND (expiration_date = v_effective_expiry OR v_effective_expiry IS NULL) ORDER BY (reserved_for_machine_id = v_dispatch.machine_id) DESC, consumer_stock DESC, reserved_at ASC LIMIT 1 FOR UPDATE;
      IF FOUND THEN v_path := 'b3_consumer_legacy'; END IF;
    END IF;
    IF v_consumer_row.wh_inventory_id IS NOT NULL THEN
      v_consumer_drawn := LEAST(p_filled_quantity, v_consumer_row.consumer_stock);
      UPDATE warehouse_inventory SET consumer_stock = GREATEST(COALESCE(consumer_stock, 0) - (v_consumer_drawn + v_return_delta), 0), warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_delta, reserved_for_machine_id = CASE WHEN COALESCE(consumer_stock, 0) - (v_consumer_drawn + v_return_delta) <= 0 THEN NULL ELSE reserved_for_machine_id END, reserved_at = CASE WHEN COALESCE(consumer_stock, 0) - (v_consumer_drawn + v_return_delta) <= 0 THEN NULL ELSE reserved_at END WHERE wh_inventory_id = v_consumer_row.wh_inventory_id;
    ELSE
      IF v_return_delta > 0 THEN
        SELECT * INTO v_wh_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND status = 'Active' AND (expiration_date = v_effective_expiry OR v_effective_expiry IS NULL) ORDER BY (expiration_date = v_effective_expiry) DESC NULLS LAST, created_at DESC LIMIT 1 FOR UPDATE;
        IF FOUND THEN
          UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_delta WHERE wh_inventory_id = v_wh_row.wh_inventory_id;
        ELSE
          SELECT * INTO v_wh_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND (expiration_date = v_effective_expiry OR v_effective_expiry IS NULL) ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_delta WHERE wh_inventory_id = v_wh_row.wh_inventory_id;
          ELSE
            PERFORM set_config('app.provenance_reason','dispatch_return_unverified', true);
            INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id) VALUES (v_dispatch.boonz_product_id, v_return_delta, v_effective_expiry, 'Active', format('RETURN-%s', v_dispatch.dispatch_date), CURRENT_DATE, v_target_wh);
            PERFORM set_config('app.provenance_reason','dispatch_receive', true);
          END IF;
        END IF;
      END IF;
    END IF;
    IF v_overfill > 0 THEN
      UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) - v_overfill WHERE wh_inventory_id = (SELECT wh_inventory_id FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND status = 'Active' AND COALESCE(warehouse_stock, 0) >= v_overfill AND (expiration_date = v_effective_expiry OR v_effective_expiry IS NULL) ORDER BY expiration_date ASC NULLS LAST LIMIT 1 FOR UPDATE);
    END IF;
   ELSE
     v_path := 'add_m2m_no_wh_draw';
   END IF;
    IF p_filled_quantity > 0 THEN
      WITH archived AS (UPDATE pod_inventory SET status = 'Inactive', removal_reason = format('merged_into_dispatch_%s_%s', v_dispatch.dispatch_date, p_dispatch_id::text), snapshot_at = now() WHERE machine_id = v_dispatch.machine_id AND shelf_id = v_dispatch.shelf_id AND boonz_product_id = v_dispatch.boonz_product_id AND status = 'Active' RETURNING current_stock, expiration_date), merge_stats AS (SELECT COALESCE(SUM(current_stock), 0)::numeric AS prior_qty, COUNT(*)::int AS prior_n, MIN(expiration_date) AS oldest_expiry FROM archived)
      INSERT INTO pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, estimated_remaining, expiration_date, batch_id, status, snapshot_at, created_at) SELECT v_dispatch.machine_id, v_dispatch.shelf_id, v_dispatch.boonz_product_id, CURRENT_DATE, p_filled_quantity + ms.prior_qty, p_filled_quantity + ms.prior_qty, LEAST(v_effective_expiry, COALESCE(ms.oldest_expiry, v_effective_expiry)), CASE WHEN ms.prior_n > 0 THEN format('MERGED-DISPATCH-%s', v_dispatch.dispatch_date) ELSE format('DISPATCH-%s', v_dispatch.dispatch_date) END, 'Active', now(), now() FROM merge_stats ms RETURNING pod_inventory_id INTO v_pod_id;
      SELECT prior_n INTO v_prior_active_merged FROM (SELECT COUNT(*)::int AS prior_n FROM pod_inventory WHERE machine_id = v_dispatch.machine_id AND shelf_id = v_dispatch.shelf_id AND boonz_product_id = v_dispatch.boonz_product_id AND status = 'Inactive' AND removal_reason = format('merged_into_dispatch_%s_%s', v_dispatch.dispatch_date, p_dispatch_id::text)) AS s;
    END IF;
  ELSIF v_dispatch.action = 'Remove' THEN
    v_path := 'remove_single_expiry';
    SELECT source_of_supply INTO v_supply FROM public.product_mapping
     WHERE boonz_product_id = v_dispatch.boonz_product_id AND status = 'Active'
       AND (machine_id = v_dispatch.machine_id OR is_global_default)
     ORDER BY (machine_id = v_dispatch.machine_id) DESC, is_global_default ASC LIMIT 1;
    IF COALESCE(v_dispatch.is_m2m, false) THEN
      v_path := 'remove_m2m_no_wh_credit';
    ELSIF v_supply = 'venue_team' THEN
      v_path := 'remove_venue_team_no_wh_credit';
      INSERT INTO public.vox_return_log
        (dispatch_id, machine_id, boonz_product_id, qty, expiry_date, source_of_supply, received_by, reason)
      VALUES
        (p_dispatch_id, v_dispatch.machine_id, v_dispatch.boonz_product_id, p_filled_quantity,
         v_effective_expiry, v_supply, p_received_by,
         format('VOX venue_team REMOVE receipt; WH credit skipped (dispatch %s)', p_dispatch_id));
    ELSIF p_filled_quantity > 0 THEN
      IF p_batch_breakdown IS NOT NULL AND jsonb_typeof(p_batch_breakdown) = 'array' THEN
        v_path := 'remove_breakdown';
        SELECT COALESCE(SUM((e->>'qty')::numeric), 0) INTO v_breakdown_total FROM jsonb_array_elements(p_batch_breakdown) e;
        IF v_breakdown_total <> p_filled_quantity THEN RAISE EXCEPTION 'Breakdown total (%) must equal filled_quantity (%)', v_breakdown_total, p_filled_quantity; END IF;
        FOR v_entry IN SELECT * FROM jsonb_array_elements(p_batch_breakdown) LOOP
          v_entry_qty := (v_entry->>'qty')::numeric;
          IF v_entry_qty <= 0 THEN CONTINUE; END IF;
          v_entry_expiry := NULLIF(v_entry->>'expiry', '')::date;
          v_entry_wh_id := NULLIF(v_entry->>'wh_inventory_id', '')::uuid;
          IF v_entry_wh_id IS NOT NULL THEN
            SELECT * INTO v_existing_row FROM warehouse_inventory WHERE wh_inventory_id = v_entry_wh_id FOR UPDATE;
            IF NOT FOUND THEN RAISE EXCEPTION 'Breakdown row id % not found', v_entry_wh_id; END IF;
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_entry_qty, status = CASE WHEN status = 'Inactive' THEN 'Active' ELSE status END WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
            v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_existing_row.wh_inventory_id, 'expiry', v_existing_row.expiration_date, 'qty', v_entry_qty);
            CONTINUE;
          END IF;
          IF v_entry_expiry IS NULL THEN RAISE EXCEPTION 'Breakdown entry must include expiry or wh_inventory_id (got %)', v_entry; END IF;
          SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date = v_entry_expiry ORDER BY created_at ASC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_entry_qty WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
            v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_existing_row.wh_inventory_id, 'expiry', v_entry_expiry, 'qty', v_entry_qty, 'mode', 'existing');
          ELSE
            PERFORM set_config('app.provenance_reason','dispatch_return_unverified', true);
            INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id) VALUES (v_dispatch.boonz_product_id, v_entry_qty, v_entry_expiry, 'Active', format('REMOVE-RECEIVE-%s', v_dispatch.dispatch_date), CURRENT_DATE, v_target_wh) RETURNING wh_inventory_id INTO v_entry_wh_id;
            PERFORM set_config('app.provenance_reason','dispatch_receive', true);
            v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_entry_wh_id, 'expiry', v_entry_expiry, 'qty', v_entry_qty, 'mode', 'inserted');
          END IF;
        END LOOP;
      ELSIF v_effective_expiry IS NOT NULL THEN
        SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date = v_effective_expiry ORDER BY created_at ASC LIMIT 1 FOR UPDATE;
        IF FOUND THEN
          UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + p_filled_quantity WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
        ELSE
          PERFORM set_config('app.provenance_reason','dispatch_return_unverified', true);
          INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id) VALUES (v_dispatch.boonz_product_id, p_filled_quantity, v_effective_expiry, 'Active', format('REMOVE-RECEIVE-%s', v_dispatch.dispatch_date), CURRENT_DATE, v_target_wh);
          PERFORM set_config('app.provenance_reason','dispatch_receive', true);
        END IF;
      ELSE
        v_path := 'remove_fefo_fallback';
        SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date IS NOT NULL ORDER BY expiration_date ASC LIMIT 1 FOR UPDATE;
        IF FOUND THEN
          UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + p_filled_quantity WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
        ELSE
          SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + p_filled_quantity WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
          ELSE
            RAISE EXCEPTION 'Cannot receive REMOVE dispatch %: effective_expiry is NULL and no Active warehouse_inventory row exists for boonz_product=%, warehouse=%. Pass p_batch_breakdown with explicit expiry.', p_dispatch_id, v_dispatch.boonz_product_id, v_target_wh;
          END IF;
        END IF;
      END IF;
    END IF;
    UPDATE pod_inventory SET status = 'Inactive', removal_reason = format('removed_via_dispatch_%s', p_dispatch_id) WHERE machine_id = v_dispatch.machine_id AND boonz_product_id = v_dispatch.boonz_product_id AND (shelf_id = v_dispatch.shelf_id OR v_dispatch.shelf_id IS NULL) AND status = 'Active';
    GET DIAGNOSTICS v_pod_archived = ROW_COUNT;
  END IF;
  UPDATE refill_dispatching SET filled_quantity = p_filled_quantity, item_added = true, dispatched = true, packed = true, picked_up = true WHERE dispatch_id = p_dispatch_id;
  RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'action', v_dispatch.action, 'filled_quantity', p_filled_quantity, 'planned_quantity', v_planned, 'return_delta', v_return_delta, 'overfill', v_overfill, 'pod_inventory_id', v_pod_id, 'pod_archived', v_pod_archived, 'prior_active_merged', v_prior_active_merged, 'consumer_drained', v_consumer_drawn, 'path', v_path, 'effective_expiry', v_effective_expiry, 'received_by', p_received_by, 'credit_summary', v_credit_summary, 'wh_credit_skipped', CASE WHEN COALESCE(v_dispatch.is_m2m,false) THEN 'm2m' WHEN v_supply = 'venue_team' THEN 'venue_team' ELSE NULL END, 'status', 'received');
END;
$function$;

-- ── B-5: return_dispatch_line — credit target from the dispatch's machine ─────
CREATE OR REPLACE FUNCTION public.return_dispatch_line(p_dispatch_id uuid, p_return_reason text DEFAULT NULL::text, p_returned_by uuid DEFAULT NULL::uuid, p_batch_breakdown jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_dispatch refill_dispatching%ROWTYPE;
  v_consumer_row warehouse_inventory%ROWTYPE;
  v_return_qty numeric;
  v_target_wh uuid;                                                                 -- RC-08 B-5: v_default_wh literal removed
  v_pod_archived int := 0;
  v_path text := 'unknown';
  v_breakdown_total numeric := 0;
  v_entry jsonb;
  v_entry_qty numeric;
  v_entry_expiry date;
  v_entry_wh_id uuid;
  v_existing_row warehouse_inventory%ROWTYPE;
  v_credit_summary jsonb := '[]'::jsonb;
  v_effective_expiry date;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'return_dispatch_line', true);
  PERFORM set_config('app.provenance_reason', 'dispatch_return', true);
  PERFORM set_config('app.source_event_id', p_dispatch_id::text, true);
  SELECT * INTO v_dispatch FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.returned = true THEN RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'status', 'already_returned', 'message', 'This dispatch was already returned, no changes made'); END IF;
  IF v_dispatch.item_added = true THEN RAISE EXCEPTION 'Dispatch % already received (item_added=true), cannot return', p_dispatch_id; END IF;
  IF (v_dispatch.skipped = true OR v_dispatch.cancelled = true OR COALESCE(v_dispatch.include, true) = false)
     AND v_dispatch.packed = false AND v_dispatch.picked_up = false THEN
    RAISE EXCEPTION 'return_dispatch_line: dispatch % is % (skip_reason: %) and was never packed or picked up. Nothing physical to return.',
      p_dispatch_id,
      CASE WHEN v_dispatch.skipped THEN 'SKIPPED' WHEN v_dispatch.cancelled THEN 'CANCELLED' ELSE 'EXCLUDED (include=false)' END,
      COALESCE(v_dispatch.skip_reason, 'no reason recorded');
  END IF;
  IF p_returned_by IS NULL AND v_dispatch.packed = false AND v_dispatch.picked_up = false THEN
    RAISE EXCEPTION 'return_dispatch_line: dispatch % has no actor (system call) and was never packed or picked up. Refusing system return of a non-physical line.', p_dispatch_id;
  END IF;

  -- RC-08 B-5: credit target = row's own route WH, else machine primary WH. Never central. RAISE if NULL.
  v_target_wh := COALESCE(
    v_dispatch.from_warehouse_id,
    (SELECT primary_warehouse_id FROM public.machines WHERE machine_id = v_dispatch.machine_id));
  IF v_target_wh IS NULL THEN
    RAISE EXCEPTION 'return_dispatch_line: cannot resolve credit warehouse for dispatch % (from_warehouse_id NULL and machine % has no primary_warehouse_id). Refusing to silently credit WH_CENTRAL.', p_dispatch_id, v_dispatch.machine_id;
  END IF;
  IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN
    SELECT expiration_date INTO v_effective_expiry FROM warehouse_inventory WHERE wh_inventory_id = v_dispatch.from_wh_inventory_id;
  ELSE
    v_effective_expiry := v_dispatch.expiry_date;
  END IF;
  IF v_dispatch.action = 'Remove' THEN
    v_return_qty := ABS(v_dispatch.quantity);
    v_path := 'remove';
    PERFORM set_config('app.mutation_reason', format('return_dispatch_line REMOVE: dispatch %s, %s units (reason: %s, by: %s, breakdown=%s, effective_expiry=%s)', p_dispatch_id, v_return_qty, COALESCE(p_return_reason, 'confirmed_removal'), COALESCE(p_returned_by::text, 'system'), p_batch_breakdown IS NOT NULL, v_effective_expiry), true);
    IF v_return_qty > 0 THEN
      IF p_batch_breakdown IS NOT NULL AND jsonb_typeof(p_batch_breakdown) = 'array' THEN
        v_path := 'remove_breakdown';
        SELECT COALESCE(SUM((e->>'qty')::numeric), 0) INTO v_breakdown_total FROM jsonb_array_elements(p_batch_breakdown) e;
        IF v_breakdown_total <> v_return_qty THEN RAISE EXCEPTION 'Breakdown total (%) must equal dispatch quantity (%)', v_breakdown_total, v_return_qty; END IF;
        FOR v_entry IN SELECT * FROM jsonb_array_elements(p_batch_breakdown) LOOP
          v_entry_qty := (v_entry->>'qty')::numeric;
          IF v_entry_qty <= 0 THEN CONTINUE; END IF;
          v_entry_expiry := NULLIF(v_entry->>'expiry', '')::date;
          v_entry_wh_id := NULLIF(v_entry->>'wh_inventory_id', '')::uuid;
          IF v_entry_wh_id IS NOT NULL THEN
            SELECT * INTO v_existing_row FROM warehouse_inventory WHERE wh_inventory_id = v_entry_wh_id FOR UPDATE;
            IF NOT FOUND THEN RAISE EXCEPTION 'Breakdown row id % not found', v_entry_wh_id; END IF;
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_entry_qty, status = CASE WHEN status = 'Inactive' THEN 'Active' ELSE status END WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
            v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_existing_row.wh_inventory_id, 'expiry', v_existing_row.expiration_date, 'qty', v_entry_qty);
            CONTINUE;
          END IF;
          IF v_entry_expiry IS NULL THEN RAISE EXCEPTION 'Breakdown entry must include either expiry or wh_inventory_id (got %)', v_entry; END IF;
          SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date = v_entry_expiry ORDER BY created_at ASC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_entry_qty WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
            v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_existing_row.wh_inventory_id, 'expiry', v_entry_expiry, 'qty', v_entry_qty, 'mode', 'existing');
          ELSE
            PERFORM set_config('app.provenance_reason','dispatch_return_unverified', true);
            INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id) VALUES (v_dispatch.boonz_product_id, v_entry_qty, v_entry_expiry, 'Active', format('REMOVE-RETURN-%s', v_dispatch.dispatch_date), CURRENT_DATE, v_target_wh) RETURNING wh_inventory_id INTO v_entry_wh_id;
            PERFORM set_config('app.provenance_reason','dispatch_return', true);
            v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_entry_wh_id, 'expiry', v_entry_expiry, 'qty', v_entry_qty, 'mode', 'inserted');
          END IF;
        END LOOP;
      ELSIF v_effective_expiry IS NOT NULL THEN
        v_path := 'remove_single_expiry';
        SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date = v_effective_expiry ORDER BY created_at ASC LIMIT 1 FOR UPDATE;
        IF FOUND THEN
          UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_qty WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
        ELSE
          PERFORM set_config('app.provenance_reason','dispatch_return_unverified', true);
          INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id) VALUES (v_dispatch.boonz_product_id, v_return_qty, v_effective_expiry, 'Active', format('REMOVE-RETURN-%s', v_dispatch.dispatch_date), CURRENT_DATE, v_target_wh);
          PERFORM set_config('app.provenance_reason','dispatch_return', true);
        END IF;
      ELSE
        v_path := 'remove_fefo_fallback';
        SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date IS NOT NULL ORDER BY expiration_date ASC LIMIT 1 FOR UPDATE;
        IF FOUND THEN
          UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_qty WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
        ELSE
          SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_qty WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
          ELSE
            RAISE EXCEPTION 'Cannot return REMOVE dispatch %: effective_expiry is NULL and no Active warehouse_inventory row exists for boonz_product=%, warehouse=%. Pass p_batch_breakdown with explicit expiry.', p_dispatch_id, v_dispatch.boonz_product_id, v_target_wh;
          END IF;
        END IF;
      END IF;
    END IF;
    UPDATE pod_inventory SET status = 'Inactive', removal_reason = format('removed_via_dispatch_%s', p_dispatch_id) WHERE machine_id = v_dispatch.machine_id AND boonz_product_id = v_dispatch.boonz_product_id AND (shelf_id = v_dispatch.shelf_id OR v_dispatch.shelf_id IS NULL) AND status = 'Active';
    GET DIAGNOSTICS v_pod_archived = ROW_COUNT;
  ELSE
    v_return_qty := COALESCE(v_dispatch.filled_quantity, v_dispatch.quantity);
    PERFORM set_config('app.mutation_reason', format('return_dispatch_line: dispatch %s, %s units (reason: %s, by: %s, effective_expiry=%s)', p_dispatch_id, v_return_qty, COALESCE(p_return_reason, 'none'), COALESCE(p_returned_by::text, 'system'), v_effective_expiry), true);
    IF v_return_qty > 0 THEN
      IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN
        SELECT * INTO v_consumer_row FROM warehouse_inventory WHERE wh_inventory_id = v_dispatch.from_wh_inventory_id FOR UPDATE;
        IF FOUND AND COALESCE(v_consumer_row.consumer_stock, 0) > 0 THEN v_path := 'pinned'; ELSE v_consumer_row := NULL; END IF;
      END IF;
      IF v_consumer_row.wh_inventory_id IS NULL THEN
        SELECT * INTO v_consumer_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND COALESCE(consumer_stock, 0) > 0 AND (reserved_for_machine_id = v_dispatch.machine_id OR reserved_for_machine_id IS NULL) AND (expiration_date = v_effective_expiry OR v_effective_expiry IS NULL) ORDER BY (reserved_for_machine_id = v_dispatch.machine_id) DESC, consumer_stock DESC LIMIT 1 FOR UPDATE;
        IF FOUND THEN v_path := 'legacy'; END IF;
      END IF;
      IF v_consumer_row.wh_inventory_id IS NOT NULL THEN
        UPDATE warehouse_inventory SET consumer_stock  = GREATEST(COALESCE(consumer_stock, 0) - v_return_qty, 0), warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_qty, reserved_for_machine_id = CASE WHEN COALESCE(consumer_stock, 0) - v_return_qty <= 0 THEN NULL ELSE reserved_for_machine_id END, reserved_at = CASE WHEN COALESCE(consumer_stock, 0) - v_return_qty <= 0 THEN NULL ELSE reserved_at END WHERE wh_inventory_id = v_consumer_row.wh_inventory_id;
      END IF;
    END IF;
  END IF;
  UPDATE refill_dispatching SET returned = true, dispatched = true, filled_quantity = 0, return_reason = p_return_reason WHERE dispatch_id = p_dispatch_id;
  RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'action', v_dispatch.action, 'return_qty', v_return_qty, 'return_reason', p_return_reason, 'returned_by', p_returned_by, 'consumer_drained', v_consumer_row.wh_inventory_id IS NOT NULL, 'pod_archived', v_pod_archived, 'path', v_path, 'effective_expiry', v_effective_expiry, 'credit_summary', v_credit_summary, 'status', 'returned');
END;
$function$;

-- ── B-6: de-magic the 6 remaining WH_CENTRAL literal sites -> wh_central_id() ─
-- Byte-safe: re-creates each from its LIVE definition with ONE deterministic
-- replacement of the unique 36-char literal. approve_refill_plan is EXCLUDED (RC-01).
-- receive/return handled above (semantic). Fails loudly if the expected 6 aren't all hit.
DO $rc08b_demagic$
DECLARE
  r          record;
  v_new_def  text;
  v_hit      int := 0;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname, pg_get_functiondef(p.oid) AS def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('auto_generate_refill_plan','bind_dispatch_fefo','inject_swap',
                        'pack_dispatch_line','receive_purchase_order','set_machine_warehouse')
      AND p.prosrc LIKE '%4bebef68-9e36-4a5c-9c2c-142f8dbdae85%'
  LOOP
    v_new_def := replace(r.def,
                         '''4bebef68-9e36-4a5c-9c2c-142f8dbdae85''',
                         'public.wh_central_id()');
    EXECUTE v_new_def;
    v_hit := v_hit + 1;
  END LOOP;

  IF v_hit <> 6 THEN
    RAISE EXCEPTION 'RC-08 B-6: expected 6 de-magic sites, replaced % — abort (live inventory drifted from 2026-07-18).', v_hit;
  END IF;
END
$rc08b_demagic$;

-- ── B-7: post-condition — ZERO functions may still carry the literal ──────────
DO $rc08b_assert$
DECLARE v_left int;
BEGIN
  SELECT count(*) INTO v_left
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosrc LIKE '%4bebef68-9e36-4a5c-9c2c-142f8dbdae85%';
  IF v_left <> 0 THEN
    RAISE EXCEPTION 'RC-08 B-7: % function(s) still contain the WH_CENTRAL literal after B (expected 0). Abort.', v_left;
  END IF;
END
$rc08b_assert$;

COMMIT;

-- FOLLOW-UP TICKET RC-08-B2 (NOT Batch 1): give receive_purchase_order an explicit
-- p_warehouse_id parameter and make set_machine_warehouse's default primary explicit/
-- required, instead of relying on wh_central_id() as a silent default. Signature change
-- -> caller coordination with Stax -> out of the Batch-1 window.
