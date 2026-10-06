-- PRD-139b Item 2B: fail-closed role checks on 15 named writer functions.
--
-- Investigation before writing this (see docs/prds/PRD-139b-log.md for the full account):
-- fetched pg_get_functiondef for all 15 live. Found three distinct bug classes, not the
-- same bug everywhere:
--   (a) no role check at all: pack_dispatch_line, return_dispatch_line,
--       driver_confirm_remove, repurpose_machine.
--   (b) a role check exists but FAILS OPEN when auth.uid() is NULL, because it is
--       wrapped in "IF <uid> IS NOT NULL THEN ... END IF" (or the equivalent
--       "IS NOT NULL AND role NOT IN (...)" / bare "role NOT IN (...)" where NULL NOT IN
--       (...) evaluates to NULL, which PL/pgSQL's IF treats as false, not true):
--       repack_machine, skip_dispatch_line, confirm_machine_packed, edit_dispatch_qty,
--       record_actual_refill (only when BOTH auth.uid() and p_actor are NULL),
--       wm_confirm_line, cancel_po_line.
--   (c) a role check exists and runs unconditionally, but trusts a CLIENT-SUPPLIED
--       caller id over the session identity, so a logged-in low-privilege user could pass
--       someone else's uuid and inherit their role: set_product_mapping_splits (looked up
--       role by p_caller_id only, never checked auth.uid() at all), set_machine_status and
--       wm_confirm_line (both did "COALESCE(p_caller, auth.uid())", preferring the
--       client-supplied value FIRST).
-- mark_picked_up and set_product_mapping_splits's role list (not its caller-id bug) were
-- already correct; set_product_mapping_splits is otherwise fixed here too (class c).
--
-- Role-list deviations from the PRD's literal grouping, decided by checking the FE first
-- (same instruction the PRD gives for set_product_mapping_splits), logged in detail in
-- docs/prds/PRD-139b-log.md:
--   - mark_picked_up: kept field_staff (not just warehouse+admins) -- /field/pickup is a
--     field_staff+warehouse+admin route per this same PRD's Item 3 route map, and
--     mark_picked_up is the only writer that page calls. No change needed here, it was
--     already fail-closed.
--   - skip_dispatch_line: field_staff REMOVED (the PRD groups it with the
--     warehouse-only six). The only caller is the packing page, a warehouse+admin route
--     per Item 3. No real field_staff flow uses it.
--
-- For receive_dispatch_line and return_dispatch_line the role check is inserted as the
-- very first statements in BEGIN, before any other logic -- the double-credit undo guard
-- (shipped 2026-10-05/06) is untouched, byte for byte. Diffed and confirmed in the log.
--
-- All 15 are CREATE OR REPLACE with their existing, unchanged signatures. No new overload.
-- Overload check run after apply.

-- ============================================================
-- 1. pack_dispatch_line -- class (a), no check existed
-- ============================================================
CREATE OR REPLACE FUNCTION public.pack_dispatch_line(p_dispatch_id uuid, p_picks jsonb, p_packed_by uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_dispatch refill_dispatching%ROWTYPE;
  v_pick jsonb;
  v_wh_row warehouse_inventory%ROWTYPE;
  v_pick_qty numeric;
  v_pick_bpid uuid;
  v_total_picked numeric := 0;
  v_first_pick boolean := true;
  v_new_child_id uuid;
  v_picks_used jsonb := '[]'::jsonb;
  v_today date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  v_wh uuid;
  v_resolved jsonb := '[]'::jsonb;
  v_rebinds jsonb := '[]'::jsonb;
  v_sub_id uuid;
  v_fail_reason text;
  v_ok boolean;
  -- v2 vox guard
  v_guard_out jsonb := '[]'::jsonb;
  v_ph_id uuid;
  v_machine_primary_wh uuid;
  v_caller_role text; -- PRD-139b 2B
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'pack_dispatch_line', true);
  PERFORM set_config('app.provenance_reason', 'dispatch_pack', true);
  PERFORM set_config('app.source_event_id', p_dispatch_id::text, true);

  -- PRD-139b 2B: fail-closed role check. Packing is warehouse/admin-only.
  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NULL OR v_caller_role IS NULL
     OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'pack_dispatch_line: forbidden for role %', COALESCE(v_caller_role, 'none (no session)');
  END IF;

  SELECT * INTO v_dispatch FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.skipped = true THEN
    RAISE EXCEPTION 'pack_dispatch_line: dispatch % is SKIPPED (skip_reason: %). Skipped lines cannot be packed; un-skip explicitly first.', p_dispatch_id, COALESCE(v_dispatch.skip_reason, 'no reason recorded');
  END IF;
  IF v_dispatch.cancelled = true THEN
    RAISE EXCEPTION 'pack_dispatch_line: dispatch % is CANCELLED (skip_reason: %). Cancelled lines cannot be packed.', p_dispatch_id, COALESCE(v_dispatch.skip_reason, 'no reason recorded');
  END IF;
  IF COALESCE(v_dispatch.include, true) = false THEN
    RAISE EXCEPTION 'pack_dispatch_line: dispatch % is EXCLUDED (include=false, skip_reason: %). Excluded lines cannot be packed.', p_dispatch_id, COALESCE(v_dispatch.skip_reason, 'no reason recorded');
  END IF;
  IF v_dispatch.packed = true THEN RAISE EXCEPTION 'Already packed'; END IF;
  IF v_dispatch.action NOT IN ('Refill','Add New','Add') THEN
    UPDATE refill_dispatching SET packed = true, pack_outcome = COALESCE(pack_outcome, 'no_pack_needed'::public.pack_outcome_enum) WHERE dispatch_id = p_dispatch_id;
    RETURN jsonb_build_object('status', 'packed_no_pick', 'dispatch_id', p_dispatch_id);
  END IF;

  -- ===== v2 VOX GUARD: venue-supplied lines may only draw from 2099 placeholder rows =====
  IF v_dispatch.source_origin = 'vox_at_venue' THEN
    SELECT primary_warehouse_id INTO v_machine_primary_wh FROM machines WHERE machine_id = v_dispatch.machine_id;
    FOR v_pick IN SELECT * FROM jsonb_array_elements(p_picks) LOOP
      v_pick_qty  := COALESCE((v_pick->>'qty')::numeric, 0);
      IF v_pick_qty <= 0 THEN
        v_guard_out := v_guard_out || v_pick;  -- zero/not-filled picks pass through untouched
        CONTINUE;
      END IF;
      v_pick_bpid := COALESCE((v_pick->>'boonz_product_id')::uuid, v_dispatch.boonz_product_id);
      SELECT wi.wh_inventory_id INTO v_ph_id
        FROM warehouse_inventory wi
       WHERE wi.boonz_product_id = v_pick_bpid
         AND wi.expiration_date = DATE '2099-12-31'
         AND wi.status = 'Active'
         AND NOT COALESCE(wi.quarantined, false)
         AND (wi.reserved_for_machine_id IS NULL OR wi.reserved_for_machine_id = v_dispatch.machine_id)
         AND COALESCE(wi.warehouse_stock, 0) >= v_pick_qty
       ORDER BY (wi.warehouse_id = v_dispatch.from_warehouse_id) DESC NULLS LAST,
                (wi.warehouse_id = v_machine_primary_wh) DESC NULLS LAST,
                wi.warehouse_stock DESC
       LIMIT 1;
      IF v_ph_id IS NULL THEN
        UPDATE refill_dispatching
           SET bind_fail_reason = 'no_venue_placeholder', bind_fail_at = now()
         WHERE dispatch_id = p_dispatch_id;
        RETURN jsonb_build_object('status', 'bind_failed', 'dispatch_id', p_dispatch_id,
                                  'bind_fail_reason', 'no_venue_placeholder',
                                  'boonz_product_id', v_pick_bpid, 'pick_qty', v_pick_qty,
                                  'message', 'vox_at_venue line: no 2099 venue placeholder row available for this product — real batches are protected. Create the placeholder (999) and retry.');
      END IF;
      v_guard_out := v_guard_out || jsonb_set(v_pick, '{wh_inventory_id}', to_jsonb(v_ph_id::text));
    END LOOP;
    p_picks := v_guard_out;
  END IF;
  -- ===== end v2 VOX GUARD =====

  SELECT COALESCE(SUM((p->>'qty')::numeric), 0) INTO v_total_picked FROM jsonb_array_elements(p_picks) p;
  IF v_total_picked < 1 THEN
    UPDATE refill_dispatching
       SET pack_outcome      = 'not_filled',
           filled_quantity   = 0,
           original_quantity = COALESCE(original_quantity, quantity), not_filled_reason = COALESCE(NULLIF((SELECT p->>'reason' FROM jsonb_array_elements(p_picks) p WHERE NULLIF(p->>'reason','') IS NOT NULL LIMIT 1), ''), 'not filled at pack time'),
           bind_fail_reason  = NULL,
           bind_fail_at      = NULL
     WHERE dispatch_id = p_dispatch_id;
    RETURN jsonb_build_object('status', 'not_filled', 'dispatch_id', p_dispatch_id,
                              'planned_quantity', v_dispatch.quantity, 'filled_quantity', 0,
                              'pack_outcome', 'not_filled');
  END IF;
  IF v_total_picked > v_dispatch.quantity THEN RAISE EXCEPTION 'Pick total (%) exceeds planned quantity (%)', v_total_picked, v_dispatch.quantity; END IF;
  PERFORM set_config('app.mutation_reason', format('B3 pack: dispatch %s picking %s units total (planned %s)', p_dispatch_id, v_total_picked, v_dispatch.quantity), true);

  v_wh := COALESCE(v_dispatch.from_warehouse_id, public.wh_central_id()::uuid);
  FOR v_pick IN SELECT * FROM jsonb_array_elements(p_picks) LOOP
    v_pick_qty := (v_pick->>'qty')::numeric;
    IF v_pick_qty <= 0 THEN CONTINUE; END IF;
    IF NULLIF(v_pick->>'wh_inventory_id', '') IS NULL THEN
      RAISE EXCEPTION 'pack_dispatch_line: every pick must include from_wh_inventory_id (BUG-006 prevention). Dispatch %, pick payload: %',
        p_dispatch_id, v_pick;
    END IF;
    v_pick_bpid := COALESCE((v_pick->>'boonz_product_id')::uuid, v_dispatch.boonz_product_id);

    SELECT * INTO v_wh_row FROM warehouse_inventory
     WHERE wh_inventory_id = (v_pick->>'wh_inventory_id')::uuid FOR UPDATE;
    v_ok := FOUND
        AND v_wh_row.status = 'Active'
        AND NOT COALESCE(v_wh_row.quarantined, false)
        AND NOT COALESCE(v_wh_row.manually_quarantined, false)
        AND (v_wh_row.expiration_date IS NULL OR v_wh_row.expiration_date >= v_today)
        AND (v_wh_row.reserved_for_machine_id IS NULL OR v_wh_row.reserved_for_machine_id = v_dispatch.machine_id)
        AND COALESCE(v_wh_row.warehouse_stock, 0) >= v_pick_qty;

    IF NOT v_ok THEN
      -- v2: vox lines never substitute into real batches
      IF v_dispatch.source_origin = 'vox_at_venue' THEN
        UPDATE refill_dispatching
           SET bind_fail_reason = 'no_venue_placeholder', bind_fail_at = now()
         WHERE dispatch_id = p_dispatch_id;
        RETURN jsonb_build_object('status', 'bind_failed', 'dispatch_id', p_dispatch_id,
                                  'bind_fail_reason', 'no_venue_placeholder',
                                  'boonz_product_id', v_pick_bpid, 'pick_qty', v_pick_qty);
      END IF;
      SELECT p.wh_inventory_id INTO v_sub_id
      FROM v_wh_pickable p
      WHERE p.boonz_product_id = v_pick_bpid
        AND p.warehouse_id = v_wh
        AND (p.reserved_for_machine_id IS NULL OR p.reserved_for_machine_id = v_dispatch.machine_id)
        AND COALESCE(p.warehouse_stock, 0) >= v_pick_qty
        AND p.wh_inventory_id <> (v_pick->>'wh_inventory_id')::uuid
      ORDER BY p.expiration_date ASC NULLS LAST, p.warehouse_stock DESC
      LIMIT 1;

      IF v_sub_id IS NOT NULL THEN
        SELECT * INTO v_wh_row FROM warehouse_inventory WHERE wh_inventory_id = v_sub_id FOR UPDATE;
        IF v_wh_row.status = 'Active' AND NOT COALESCE(v_wh_row.quarantined, false)
           AND (v_wh_row.expiration_date IS NULL OR v_wh_row.expiration_date >= v_today)
           AND (v_wh_row.reserved_for_machine_id IS NULL OR v_wh_row.reserved_for_machine_id = v_dispatch.machine_id)
           AND COALESCE(v_wh_row.warehouse_stock, 0) >= v_pick_qty THEN
          v_rebinds := v_rebinds || jsonb_build_object(
            'from', v_pick->>'wh_inventory_id', 'to', v_sub_id, 'qty', v_pick_qty,
            'new_expiry', v_wh_row.expiration_date, 'boonz_product_id', v_pick_bpid);
          v_pick := jsonb_set(v_pick, '{wh_inventory_id}', to_jsonb(v_sub_id::text));
        ELSE
          v_sub_id := NULL;
        END IF;
      END IF;

      IF v_sub_id IS NULL THEN
        SELECT CASE
          WHEN EXISTS (SELECT 1 FROM warehouse_inventory w
                       WHERE w.boonz_product_id = v_pick_bpid AND w.warehouse_id = v_wh
                         AND w.status = 'Active' AND NOT COALESCE(w.quarantined,false)
                         AND (w.expiration_date IS NULL OR w.expiration_date >= v_today)
                         AND COALESCE(w.warehouse_stock,0) >= v_pick_qty
                         AND w.reserved_for_machine_id IS NOT NULL
                         AND w.reserved_for_machine_id <> v_dispatch.machine_id)
            THEN 'pinned_elsewhere'
          WHEN EXISTS (SELECT 1 FROM warehouse_inventory w
                       WHERE w.boonz_product_id = v_pick_bpid AND w.warehouse_id = v_wh
                         AND COALESCE(w.quarantined,false)
                         AND (w.expiration_date IS NULL OR w.expiration_date >= v_today)
                         AND COALESCE(w.warehouse_stock,0) > 0)
            THEN 'quarantined'
          WHEN EXISTS (SELECT 1 FROM warehouse_inventory w
                       WHERE w.boonz_product_id = v_pick_bpid AND w.warehouse_id = v_wh
                         AND NOT COALESCE(w.quarantined,false) AND COALESCE(w.manually_quarantined,false)
                         AND (w.expiration_date IS NULL OR w.expiration_date >= v_today)
                         AND COALESCE(w.warehouse_stock,0) > 0)
            THEN 'manually_quarantined'
          WHEN EXISTS (SELECT 1 FROM warehouse_inventory w
                       WHERE w.boonz_product_id = v_pick_bpid AND w.warehouse_id = v_wh
                         AND w.status <> 'Active' AND NOT COALESCE(w.quarantined,false)
                         AND (w.expiration_date IS NULL OR w.expiration_date >= v_today)
                         AND COALESCE(w.warehouse_stock,0) > 0)
            THEN 'inactive_batch'
          ELSE 'no_stock'
        END INTO v_fail_reason;

        UPDATE refill_dispatching
           SET bind_fail_reason = v_fail_reason, bind_fail_at = now()
         WHERE dispatch_id = p_dispatch_id;
        RETURN jsonb_build_object('status', 'bind_failed', 'dispatch_id', p_dispatch_id,
                                  'bind_fail_reason', v_fail_reason,
                                  'stale_wh_inventory_id', v_pick->>'wh_inventory_id',
                                  'pick_qty', v_pick_qty, 'boonz_product_id', v_pick_bpid,
                                  'planned_quantity', v_dispatch.quantity);
      END IF;
    END IF;

    v_resolved := v_resolved || v_pick;
  END LOOP;

  FOR v_pick IN SELECT * FROM jsonb_array_elements(v_resolved) LOOP
    v_pick_qty := (v_pick->>'qty')::numeric;
    v_pick_bpid := COALESCE((v_pick->>'boonz_product_id')::uuid, v_dispatch.boonz_product_id);
    SELECT * INTO v_wh_row FROM warehouse_inventory WHERE wh_inventory_id = (v_pick->>'wh_inventory_id')::uuid FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'WH row % not found', v_pick->>'wh_inventory_id'; END IF;
    IF COALESCE(v_wh_row.warehouse_stock, 0) < v_pick_qty THEN RAISE EXCEPTION 'WH row % has only % units, cannot pick %', v_wh_row.wh_inventory_id, v_wh_row.warehouse_stock, v_pick_qty; END IF;
    UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) - v_pick_qty, consumer_stock = COALESCE(consumer_stock, 0) + v_pick_qty WHERE wh_inventory_id = v_wh_row.wh_inventory_id;
    IF v_first_pick THEN
      UPDATE refill_dispatching SET packed = false WHERE dispatch_id = p_dispatch_id;
      UPDATE refill_dispatching SET packed = true, expiry_date = v_wh_row.expiration_date, filled_quantity = v_pick_qty, boonz_product_id = v_pick_bpid, quantity = CASE WHEN refill_qa.flag('qty_split_v1')='on' THEN quantity ELSE v_total_picked END, from_wh_inventory_id = v_wh_row.wh_inventory_id, original_quantity = COALESCE(v_dispatch.original_quantity, v_dispatch.quantity), pack_outcome = (CASE WHEN v_total_picked < v_dispatch.quantity THEN 'partial' ELSE 'packed' END)::public.pack_outcome_enum, bind_fail_reason = NULL, bind_fail_at = NULL WHERE dispatch_id = p_dispatch_id;
      v_first_pick := false;
    ELSE
      INSERT INTO refill_dispatching (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action, quantity, filled_quantity, include, packed, picked_up, dispatched, returned, item_added, expiry_date, from_wh_inventory_id, pack_outcome, source_origin, parent_dispatch_id) VALUES (v_dispatch.machine_id, v_dispatch.shelf_id, v_dispatch.pod_product_id, v_pick_bpid, v_dispatch.dispatch_date, v_dispatch.action, v_pick_qty, v_pick_qty, true, true, false, false, false, false, v_wh_row.expiration_date, v_wh_row.wh_inventory_id, 'packed', v_dispatch.source_origin, p_dispatch_id) RETURNING dispatch_id INTO v_new_child_id;
    END IF;
    v_picks_used := v_picks_used || jsonb_build_object('wh_inventory_id', v_wh_row.wh_inventory_id, 'batch_id', v_wh_row.batch_id, 'expiry', v_wh_row.expiration_date, 'qty', v_pick_qty, 'boonz_product_id', v_pick_bpid, 'child_dispatch_id', v_new_child_id);
  END LOOP;
  RETURN jsonb_build_object('status', 'packed', 'dispatch_id', p_dispatch_id, 'total_picked', v_total_picked, 'planned_quantity', v_dispatch.quantity, 'pack_outcome', (CASE WHEN v_total_picked < v_dispatch.quantity THEN 'partial' ELSE 'packed' END), 'picks', v_picks_used, 'rebinds', v_rebinds);
END;
$function$;

-- ============================================================
-- 2. repack_machine -- class (b), fail-open on NULL role
-- ============================================================
CREATE OR REPLACE FUNCTION public.repack_machine(p_machine_name text, p_dispatch_date date DEFAULT NULL::date, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role      text;
  v_machine_id       uuid;
  v_today            date := (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date;
  v_target_date      date;
  v_returned_count   int := 0;
  v_failed_returns   int := 0;
  v_resets_done      int := 0;
  v_pushed           int := 0;
  v_dispatched_count int := 0;
  v_row              record;
  v_push_result      jsonb;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','repack_machine',true);
  PERFORM set_config('app.mutation_reason',
    format('repack_machine: %s for %s (reason: %s)',
           p_machine_name,
           COALESCE(p_dispatch_date, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date),
           COALESCE(p_reason,'none')),
    true);

  SELECT role INTO v_caller_role FROM user_profiles WHERE id = auth.uid();
  -- PRD-139b 2B: was "IF v_caller_role NOT IN (...)" -- NULL NOT IN (...) is NULL, which
  -- PL/pgSQL's IF treats as false, so a NULL-role caller fell through unauthorized. Fixed.
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RETURN jsonb_build_object('status','error','error','Insufficient role');
  END IF;

  v_target_date := COALESCE(p_dispatch_date, v_today);

  SELECT machine_id INTO v_machine_id FROM machines WHERE official_name = p_machine_name;
  IF v_machine_id IS NULL THEN
    RETURN jsonb_build_object('status','error','error','Machine not found: ' || p_machine_name);
  END IF;

  SELECT COUNT(*) INTO v_dispatched_count
  FROM refill_dispatching
  WHERE machine_id    = v_machine_id
    AND dispatch_date = v_target_date
    AND dispatched    = true;

  IF v_dispatched_count > 0 THEN
    RETURN jsonb_build_object(
      'status','error',
      'error','cannot_repack_after_dispatch',
      'message', format('Cannot repack %s for %s — %s row(s) already dispatched.',
                        p_machine_name, v_target_date, v_dispatched_count),
      'dispatched_count', v_dispatched_count,
      'machine', p_machine_name,
      'dispatch_date', v_target_date
    );
  END IF;

  -- ---- D-43 HALF 2 (S-191) · PRE-FLIGHT THE CONSTRUCTIVE HALF ----------------
  -- repack is destructive-then-constructive with NO savepoint: the loop below is the
  -- first destructive act, and push_plan_to_dispatch is the constructive one. A caller
  -- authorised for the first and refused by the second leaves the machine frozen with
  -- its rows returned and nothing to replace them. Refuse HERE, before a single row moves.
  -- ⛔ push lets a NULL caller (service role) through its own gate; this pre-flight mirrors
  -- that exactly, or it would refuse the unattended path push itself permits.
  IF auth.uid() IS NOT NULL
     AND NOT (COALESCE(v_caller_role,'') = ANY (public.push_dispatch_authorized_roles())) THEN
    RETURN jsonb_build_object(
      'status','error',
      'error','push_not_authorized',
      'message', format('repack_machine: role %s may start a repack but is not authorised for push_plan_to_dispatch - refusing BEFORE any row is returned (D-43).',
                        COALESCE(v_caller_role,'<none>')),
      'machine', p_machine_name,
      'dispatch_date', v_target_date,
      'returned_count', 0,
      'failed_returns', 0,
      'plan_rows_reset', 0,
      'fresh_dispatch_rows_created', 0,
      'reason', p_reason
    );
  END IF;

  FOR v_row IN
    SELECT dispatch_id, shelf_id, boonz_product_id, action
    FROM refill_dispatching
    WHERE machine_id    = v_machine_id
      AND dispatch_date = v_target_date
      AND packed        = true
      AND picked_up     = false
      AND returned      = false
      AND item_added    = false
      AND COALESCE(is_m2m, false) = false
    ORDER BY created_at
  LOOP
    BEGIN
      PERFORM public.return_dispatch_line(v_row.dispatch_id, 'superseded_by_repack');
      v_returned_count := v_returned_count + 1;
    EXCEPTION WHEN OTHERS THEN
      v_failed_returns := v_failed_returns + 1;
      RAISE WARNING 'repack_machine: return_dispatch_line failed for %, error: %',
        v_row.dispatch_id, SQLERRM;
    END;
  END LOOP;

  UPDATE refill_plan_output rpo
  SET dispatched = false
  WHERE rpo.plan_date        = v_target_date
    AND rpo.machine_name     = p_machine_name
    AND rpo.operator_status  = 'approved'
    AND rpo.dispatched       = true
    AND NOT EXISTS (
      SELECT 1
      FROM refill_dispatching rd
      JOIN machines m ON m.machine_id = rd.machine_id
      LEFT JOIN shelf_configurations sc ON sc.shelf_id = rd.shelf_id
      WHERE m.official_name = rpo.machine_name
        AND rd.dispatch_date = rpo.plan_date
        AND COALESCE(sc.shelf_code,'') = COALESCE(rpo.shelf_code,'')
        AND rd.item_added = true
    );
  GET DIAGNOSTICS v_resets_done = ROW_COUNT;

  IF v_resets_done > 0 THEN
    BEGIN
      v_push_result := public.push_plan_to_dispatch(v_target_date, p_machine_name);
    EXCEPTION WHEN OTHERS THEN
      RETURN jsonb_build_object(
        'status','error','error','push_failed',
        'message', format('repack_machine: returns/resets applied but push_plan_to_dispatch failed: %s', SQLERRM),
        'machine', p_machine_name, 'dispatch_date', v_target_date,
        'returned_count', v_returned_count, 'failed_returns', v_failed_returns,
        'plan_rows_reset', v_resets_done, 'fresh_dispatch_rows_created', 0, 'reason', p_reason);
    END;
    IF COALESCE(v_push_result->>'status','') <> 'ok' THEN
      RETURN jsonb_build_object(
        'status','error','error','push_not_ok',
        'push_result', v_push_result,
        'machine', p_machine_name, 'dispatch_date', v_target_date,
        'returned_count', v_returned_count, 'failed_returns', v_failed_returns,
        'plan_rows_reset', v_resets_done, 'fresh_dispatch_rows_created', 0, 'reason', p_reason);
    END IF;
    v_pushed := COALESCE((v_push_result->>'lines_pushed')::int, 0);
  END IF;

  RETURN jsonb_build_object(
    'status',           'ok',
    'machine',          p_machine_name,
    'dispatch_date',    v_target_date,
    'returned_count',   v_returned_count,
    'failed_returns',   v_failed_returns,
    'plan_rows_reset',  v_resets_done,
    'fresh_dispatch_rows_created', v_pushed,
    'reason',           p_reason
  );
END;
$function$;

-- ============================================================
-- 3. skip_dispatch_line -- class (b) + role-list tightened (field_staff removed,
--    confirmed only the warehouse/admin-only packing page calls this)
-- ============================================================
CREATE OR REPLACE FUNCTION public.skip_dispatch_line(p_dispatch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid  uuid := (SELECT auth.uid());
  v_role text;
  v_row  public.refill_dispatching%ROWTYPE;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'skip_dispatch_line', true);

  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
  IF v_uid IS NULL OR v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'skip_dispatch_line: forbidden for role %', COALESCE(v_role,'unknown');
  END IF;

  IF p_dispatch_id IS NULL THEN
    RAISE EXCEPTION 'p_dispatch_id required';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>= 10 chars)';
  END IF;

  PERFORM set_config('app.mutation_reason', p_reason, true);

  SELECT * INTO v_row FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'skip_dispatch_line: dispatch_id % not found', p_dispatch_id;
  END IF;
  IF v_row.picked_up THEN
    RAISE EXCEPTION 'skip_dispatch_line: dispatch_id % already picked up - too late to skip', p_dispatch_id;
  END IF;
  IF v_row.skipped THEN
    RAISE EXCEPTION 'skip_dispatch_line: dispatch_id % already skipped', p_dispatch_id;
  END IF;
  IF v_row.cancelled THEN
    RAISE EXCEPTION 'skip_dispatch_line: dispatch_id % is cancelled (use the cancel flow)', p_dispatch_id;
  END IF;

  UPDATE public.refill_dispatching
     SET skipped             = true,
         skipped_at          = now(),
         skipped_by          = v_uid,
         skip_reason         = p_reason,
         include             = false,
         edit_count          = edit_count + 1,
         last_edited_by      = v_uid,
         last_edited_by_role = COALESCE(v_role, 'system'),
         last_edited_at      = now()
   WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object(
    'status', 'ok',
    'dispatch_id', p_dispatch_id,
    'skipped', true,
    'reason', p_reason,
    'machine_id', v_row.machine_id,
    'boonz_product_id', v_row.boonz_product_id
  );
END;
$function$;

-- ============================================================
-- 4. confirm_machine_packed -- class (b)
-- ============================================================
CREATE OR REPLACE FUNCTION public.confirm_machine_packed(p_machine_name text, p_dispatch_date date DEFAULT NULL::date, p_packed_by uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text, p_final boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_role text; v_machine_id uuid;
  v_date date := COALESCE(p_dispatch_date, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date);
  v_unresolved jsonb; v_summary jsonb;
  v_p record;                 -- v_dispatch_pack_progress row
  v_orphans jsonb := '[]'::jsonb;
  v_orphan_n integer := 0;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','confirm_machine_packed',true);

  -- PRD-139b 2B: was "IF v_uid IS NOT NULL THEN ... END IF" -- a NULL caller skipped the
  -- check entirely and proceeded. Fixed to fail closed.
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
  IF v_uid IS NULL OR v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'confirm_machine_packed: forbidden for role %', COALESCE(v_role,'unknown');
  END IF;

  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'confirm_machine_packed: p_reason required (>= 10 chars)';
  END IF;
  PERFORM set_config('app.mutation_reason', p_reason, true);
  SELECT machine_id INTO v_machine_id FROM public.machines WHERE official_name = p_machine_name;
  IF v_machine_id IS NULL THEN RAISE EXCEPTION 'confirm_machine_packed: machine % not found', p_machine_name; END IF;

  -- Article 16: the canonical object decides readiness. No inline re-derivation.
  SELECT * INTO v_p FROM public.v_dispatch_pack_progress
   WHERE machine_id = v_machine_id AND dispatch_date = v_date;

  IF NOT FOUND THEN
    -- No included, non-cancelled lines at all for this machine/date.
    RETURN jsonb_build_object('status','blocked','machine',p_machine_name,'dispatch_date',v_date,
      'unresolved_count',0,'unresolved','[]'::jsonb,
      'message','No included dispatch lines for this machine and date.');
  END IF;

  -- Line-level detail for the blocked response. Same predicate as the view.
  SELECT COALESCE(jsonb_agg(jsonb_build_object('dispatch_id', rd.dispatch_id, 'shelf_id', rd.shelf_id,
            'boonz_product_id', rd.boonz_product_id, 'action', rd.action, 'quantity', rd.quantity) ORDER BY rd.shelf_id), '[]'::jsonb)
    INTO v_unresolved
  FROM public.refill_dispatching rd
  WHERE rd.machine_id = v_machine_id AND rd.dispatch_date = v_date
    AND COALESCE(rd.cancelled, false) = false AND COALESCE(rd.include, true) = true
    AND COALESCE(rd.packed, false) = false AND COALESCE(rd.skipped, false) = false
    AND COALESCE(rd.pack_outcome::text, '') <> 'not_filled' AND rd.action IN ('Refill','Add New','Add');

  IF p_final AND NOT v_p.ready_to_pack_close THEN
    RETURN jsonb_build_object('status','blocked','machine',p_machine_name,'dispatch_date',v_date,
      'unresolved_count', v_p.packable_n - v_p.resolved_n,
      'unresolved', v_unresolved,
      'packable_n', v_p.packable_n, 'resolved_n', v_p.resolved_n,
      'driver_action_n', v_p.driver_action_n,
      'message','Finish blocked: some included lines are neither packed nor marked not_filled/skipped. Pack/mark them, or use Save & come back.');
  END IF;

  -- R2/R5: driver-side legs draw nothing from the warehouse. Resolve them here so
  -- the packer never has to tick them, while KEEPING the Remove state machine intact
  -- (mark_picked_up and driver_confirm_remove both require packed=true).
  -- UPDATE is safe: conserve_split_dispatch_quantity is a BEFORE INSERT trigger.
  IF p_final THEN
    UPDATE public.refill_dispatching rd
       SET packed = true
     WHERE rd.machine_id = v_machine_id AND rd.dispatch_date = v_date
       AND COALESCE(rd.cancelled,false) = false AND COALESCE(rd.include,true) = true
       AND COALESCE(rd.skipped,false) = false
       AND rd.action NOT IN ('Refill','Add New','Add')
       AND COALESCE(rd.packed,false) = false;
  END IF;

  -- R4: orphaned swap-leg guard. A live REMOVE whose paired swap-in all died
  -- would ship an EMPTY shelf. Flag it, surface it, propose the skip. Never silent,
  -- never auto-applied - the packer accepts it explicitly via skip_dispatch_line.
  IF p_final THEN
    v_orphans   := COALESCE(v_p.orphaned_swap_legs, '[]'::jsonb);
    v_orphan_n  := COALESCE(v_p.orphaned_swap_leg_n, 0);
    IF v_orphan_n > 0 THEN
      UPDATE public.refill_dispatching rd
         SET needs_review  = true,
             review_reason = 'orphaned_swap_leg',
             review_status = 'pending'   -- matches idx_refill_dispatching_needs_review
       WHERE rd.dispatch_id IN (
               SELECT (x->>'dispatch_id')::uuid FROM jsonb_array_elements(v_orphans) x)
         AND COALESCE(rd.needs_review,false) = false;
    END IF;
  END IF;

  SELECT jsonb_build_object(
    'total_included', COUNT(*) FILTER (WHERE COALESCE(include,true) AND NOT COALESCE(cancelled,false)),
    'packed', COUNT(*) FILTER (WHERE packed AND COALESCE(pack_outcome::text,'packed') NOT IN ('partial','not_filled')),
    'partial', COUNT(*) FILTER (WHERE pack_outcome = 'partial'),
    'not_filled', COUNT(*) FILTER (WHERE pack_outcome = 'not_filled'),
    'skipped', COUNT(*) FILTER (WHERE skipped))
  INTO v_summary FROM public.refill_dispatching
  WHERE machine_id = v_machine_id AND dispatch_date = v_date AND NOT COALESCE(cancelled,false);

  v_summary := v_summary || jsonb_build_object(
    'packable_n', v_p.packable_n, 'resolved_n', v_p.resolved_n,
    'driver_action_n', v_p.driver_action_n, 'no_pack_needed_n', v_p.no_pack_needed_n,
    'orphaned_swap_leg_n', v_orphan_n);

  INSERT INTO public.dispatch_pack_confirmation (machine_id, dispatch_date, confirmed_by, confirmed_at, reason, summary, final)
  VALUES (v_machine_id, v_date, COALESCE(p_packed_by, v_uid), now(), p_reason, v_summary, p_final)
  ON CONFLICT (machine_id, dispatch_date) DO UPDATE
    SET confirmed_by = EXCLUDED.confirmed_by, confirmed_at = now(), reason = EXCLUDED.reason,
        summary = EXCLUDED.summary, final = EXCLUDED.final;

  IF p_final THEN
    RETURN jsonb_build_object('status','ok','confirmed',true,'machine',p_machine_name,'dispatch_date',v_date,
      'pack_state','completed','confirmed_by',COALESCE(p_packed_by, v_uid),
      'packed_n',(v_summary->>'packed')::int,'partial_n',(v_summary->>'partial')::int,
      'skipped_n',(v_summary->>'skipped')::int,'not_filled_n',(v_summary->>'not_filled')::int,
      'packable_n', v_p.packable_n, 'resolved_n', v_p.resolved_n,
      'driver_action_n', v_p.driver_action_n,
      'orphaned_swap_legs', v_orphans, 'orphaned_swap_leg_n', v_orphan_n,
      'needs_review', (v_orphan_n > 0),
      'summary',v_summary);
  ELSE
    RETURN jsonb_build_object('status','saved','saved',true,'machine',p_machine_name,'dispatch_date',v_date,
      'pack_state','in_progress',
      'resolved_n',v_p.resolved_n,'remaining_n', v_p.packable_n - v_p.resolved_n,
      'packable_n', v_p.packable_n, 'driver_action_n', v_p.driver_action_n,
      'summary',v_summary);
  END IF;
END; $function$;

-- ============================================================
-- 5. edit_dispatch_qty -- class (b)
-- ============================================================
CREATE OR REPLACE FUNCTION public.edit_dispatch_qty(p_dispatch_id uuid, p_new_qty numeric, p_edit_role text, p_reason text DEFAULT NULL::text, p_conductor_session text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row    refill_dispatching%ROWTYPE;
  v_role   text;
  v_before jsonb;
  v_after  jsonb;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','edit_dispatch_qty',true);

  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  -- PRD-139b 2B: was "IF auth.uid() IS NOT NULL AND v_role NOT IN (...)" -- NULL caller
  -- skipped the check. Fixed to fail closed.
  IF auth.uid() IS NULL OR v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'forbidden: edit_dispatch_qty requires warehouse / operator_admin / superadmin / manager';
  END IF;

  IF p_new_qty IS NULL OR p_new_qty < 0 THEN RAISE EXCEPTION 'invalid p_new_qty'; END IF;
  IF p_edit_role NOT IN ('driver','warehouse_manager','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'invalid p_edit_role';
  END IF;

  SELECT * INTO v_row FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'dispatch % not found', p_dispatch_id; END IF;
  IF v_row.item_added THEN
    RAISE EXCEPTION 'dispatch % already item_added — edit blocked', p_dispatch_id;
  END IF;
  IF COALESCE(v_row.packed, false) = true THEN
    RAISE EXCEPTION 'edit_dispatch_qty: dispatch % is already PACKED (filled_quantity=%, pack_outcome=%). Quantity edits on packed lines are blocked. Use repack_machine to unwind & re-pack, or return_dispatch_line to send the packed stock back to the warehouse.',
      p_dispatch_id, v_row.filled_quantity, v_row.pack_outcome;
  END IF;

  v_before := jsonb_build_object('quantity', v_row.quantity);

  UPDATE public.refill_dispatching
  SET quantity            = p_new_qty,
      original_quantity   = COALESCE(original_quantity, v_row.quantity),
      edit_count          = edit_count + 1,
      last_edited_by      = auth.uid(),
      last_edited_by_role = p_edit_role,
      last_edited_at      = now()
  WHERE dispatch_id = p_dispatch_id;

  v_after := jsonb_build_object('quantity', p_new_qty);

  INSERT INTO public.refill_dispatching_edit_log
    (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
  VALUES
    (p_dispatch_id, auth.uid(), p_edit_role, 'qty', v_before, v_after, p_reason, p_conductor_session);

  RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'edit_kind','qty',
                            'before', v_before, 'after', v_after);
END $function$;

-- ============================================================
-- 6. mark_picked_up -- no change, already fail-closed. Not reissued.
-- ============================================================

-- ============================================================
-- 7. receive_dispatch_line -- class (a), role check inserted at the very top,
--    double-credit undo guard (2026-10-05/06) untouched below it, byte for byte.
-- ============================================================
CREATE OR REPLACE FUNCTION public.receive_dispatch_line(p_dispatch_id uuid, p_filled_quantity numeric, p_received_by uuid DEFAULT NULL::uuid, p_batch_breakdown jsonb DEFAULT NULL::jsonb, p_override boolean DEFAULT false, p_override_reason text DEFAULT NULL::text)
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
  v_target_wh uuid; v_pod_archived int := 0;
  v_breakdown_total numeric := 0;
  v_entry jsonb; v_entry_qty numeric; v_entry_expiry date; v_entry_wh_id uuid;
  v_existing_row warehouse_inventory%ROWTYPE;
  v_credit_summary jsonb := '[]'::jsonb;
  v_effective_expiry date;
  v_prior_active_merged int := 0;
  v_supply text;
  v_is_fill boolean;
  v_gate text;
  v_overfill_debits jsonb := '[]'::jsonb;
  v_fefo record;
  v_need numeric;
  v_take numeric;
  v_return_audit_ts timestamptz;
  v_wh_audit record;
  v_delta numeric;
  v_undo_total numeric := 0;
  v_undo_row warehouse_inventory%ROWTYPE;
  v_caller_role text; -- PRD-139b 2B
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'receive_dispatch_line', true);
  PERFORM set_config('app.provenance_reason', 'dispatch_receive', true);
  PERFORM set_config('app.source_event_id', p_dispatch_id::text, true);

  -- PRD-139b 2B: fail-closed role check, inserted at the top only. Everything below this
  -- block, including the 2026-10-05/06 return-then-receive double-credit undo guard, is
  -- byte-for-byte unchanged (diffed in docs/prds/PRD-139b-log.md).
  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NULL OR v_caller_role IS NULL
     OR v_caller_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'receive_dispatch_line: forbidden for role %', COALESCE(v_caller_role, 'none (no session)');
  END IF;

  SELECT * INTO v_dispatch FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.item_added = true THEN RAISE EXCEPTION 'Dispatch % already received', p_dispatch_id; END IF;

  IF v_dispatch.returned = true THEN
    SELECT occurred_at INTO v_return_audit_ts FROM write_audit_log
     WHERE table_name = 'refill_dispatching' AND row_pk = p_dispatch_id::text AND rpc_name = 'return_dispatch_line'
     ORDER BY occurred_at DESC LIMIT 1;
    IF v_return_audit_ts IS NULL THEN
      RAISE EXCEPTION 'receive_dispatch_line: dispatch % is returned=true but no return_dispatch_line audit trail was found for it, refusing to auto-undo an unexplained return. Clear "returned" manually first if that is genuinely safe.', p_dispatch_id;
    END IF;

    FOR v_wh_audit IN
      SELECT row_pk AS wh_id,
             (payload -> 'old' ->> 'warehouse_stock')::numeric AS old_stock,
             (payload -> 'new' ->> 'warehouse_stock')::numeric AS new_stock
        FROM write_audit_log
       WHERE table_name = 'warehouse_inventory'
         AND rpc_name = 'return_dispatch_line'
         AND occurred_at = v_return_audit_ts
         AND (payload -> 'new' ->> 'boonz_product_id')::uuid = v_dispatch.boonz_product_id
    LOOP
      v_delta := v_wh_audit.new_stock - v_wh_audit.old_stock;
      IF v_delta IS NULL OR v_delta <= 0 THEN CONTINUE; END IF;
      SELECT * INTO v_undo_row FROM warehouse_inventory
       WHERE wh_inventory_id = v_wh_audit.wh_id::uuid AND status = 'Active' FOR UPDATE;
      IF NOT FOUND OR COALESCE(v_undo_row.warehouse_stock, 0) < v_delta THEN
        RAISE EXCEPTION 'receive_dispatch_line: cannot auto-undo dispatch %''s return, % unit(s) credited to warehouse_inventory row % are no longer available there (already picked, moved, or wasted since). Refusing to double-count; reconcile manually before receiving.', p_dispatch_id, v_delta, v_wh_audit.wh_id;
      END IF;
      UPDATE warehouse_inventory SET warehouse_stock = warehouse_stock - v_delta WHERE wh_inventory_id = v_wh_audit.wh_id::uuid;
      v_undo_total := v_undo_total + v_delta;
    END LOOP;

    IF v_undo_total = 0 THEN
      RAISE EXCEPTION 'receive_dispatch_line: dispatch % is returned=true but no warehouse_inventory credit could be found in its return_dispatch_line audit trail to undo, refusing to proceed blind.', p_dispatch_id;
    END IF;

    PERFORM set_config('app.mutation_reason',
      format('receive_dispatch_line UNDO: reversing %s unit(s) that return_dispatch_line credited at %s for dispatch %s, before re-receiving it now',
        v_undo_total, v_return_audit_ts, p_dispatch_id), true);
    UPDATE refill_dispatching SET returned = false, return_reason = NULL WHERE dispatch_id = p_dispatch_id;
    v_dispatch.returned := false;
    v_dispatch.return_reason := NULL;
  END IF;

  IF p_filled_quantity < 0 THEN RAISE EXCEPTION 'filled_quantity cannot be negative'; END IF;
  v_planned := v_dispatch.quantity;
  v_return_delta := GREATEST(v_planned - p_filled_quantity, 0);
  v_overfill := GREATEST(p_filled_quantity - v_planned, 0);
  v_path := 'b2_fallback';
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
    PERFORM public.log_expiry_entry_suspect('receive_dispatch_line', v_dispatch.dispatch_date,
      v_effective_expiry, jsonb_build_object('dispatch_id', p_dispatch_id, 'machine_id', v_dispatch.machine_id,
        'boonz_product_id', v_dispatch.boonz_product_id, 'action', v_dispatch.action));
  END IF;
  PERFORM set_config('app.mutation_reason', format('B3 receive: dispatch %s, filled %s / planned %s by %s (breakdown=%s, effective_expiry=%s)', p_dispatch_id, p_filled_quantity, v_planned, COALESCE(p_received_by::text, 'system'), p_batch_breakdown IS NOT NULL, v_effective_expiry), true);
  v_is_fill := v_dispatch.action IN ('Refill','Add New','Add') AND NOT COALESCE(v_dispatch.is_m2m, false);
  v_gate := COALESCE(refill_qa.flag('rc07_receive_gate'), 'off');
  IF v_is_fill AND v_gate = 'on'
     AND NOT (COALESCE(v_dispatch.packed, false) AND COALESCE(v_dispatch.picked_up, false)) THEN
    IF p_override IS TRUE AND COALESCE(NULLIF(btrim(p_override_reason), ''), '') <> '' THEN
      PERFORM set_config('app.receive_override_reason', p_override_reason, true);
      PERFORM set_config('app.mutation_reason',
        format('B4 receive OVERRIDE: dispatch %s force-received unpacked (packed=%s picked_up=%s) reason: %s',
               p_dispatch_id, COALESCE(v_dispatch.packed,false), COALESCE(v_dispatch.picked_up,false), p_override_reason), true);
    ELSE
      RAISE EXCEPTION 'receive_dispatch_line: dispatch % is not in a receivable state (packed=%, picked_up=%). A fill line must be PACKED and PICKED UP before receive. Pass p_override:=true with p_override_reason to force-receive (audited).',
        p_dispatch_id, COALESCE(v_dispatch.packed,false), COALESCE(v_dispatch.picked_up,false);
    END IF;
  END IF;
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
            PERFORM set_config('app.provenance_reason', CASE WHEN v_dispatch.wh_approved_at IS NOT NULL THEN 'dispatch_receive' ELSE 'dispatch_return_unverified' END, true);
            INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id) VALUES (v_dispatch.boonz_product_id, v_return_delta, v_effective_expiry, 'Active', format('RETURN-%s', v_dispatch.dispatch_date), CURRENT_DATE, v_target_wh);
            PERFORM set_config('app.provenance_reason','dispatch_receive', true);
          END IF;
        END IF;
      END IF;
    END IF;
    IF v_overfill > 0 THEN
      v_need := v_overfill;
      FOR v_fefo IN
        SELECT f.wh_inventory_id, f.warehouse_stock, f.batch_id, f.expiration_date
        FROM public.wh_fefo_for_line(
               v_dispatch.machine_id, v_dispatch.boonz_product_id,
               COALESCE(v_dispatch.dispatch_date, CURRENT_DATE),
               v_overfill, ARRAY[v_target_wh]) f
        ORDER BY f.pick_rank
      LOOP
        EXIT WHEN v_need <= 0;
        v_take := LEAST(v_need, GREATEST(COALESCE(v_fefo.warehouse_stock,0), 0));
        IF v_take <= 0 THEN CONTINUE; END IF;
        UPDATE warehouse_inventory
           SET warehouse_stock = COALESCE(warehouse_stock, 0) - v_take
         WHERE wh_inventory_id = v_fefo.wh_inventory_id;
        v_overfill_debits := v_overfill_debits || jsonb_build_object(
          'wh_inventory_id', v_fefo.wh_inventory_id, 'batch_id', v_fefo.batch_id,
          'expiry', v_fefo.expiration_date, 'qty', v_take);
        v_need := v_need - v_take;
      END LOOP;
      IF v_need > 0 THEN
        RAISE EXCEPTION 'receive_dispatch_line: overfill of % unit(s) for boonz_product=% cannot be debited, warehouse % is short by % unit(s) across all pickable FEFO batches. Refusing to silently debit an arbitrary/zero row.',
          v_overfill, v_dispatch.boonz_product_id, v_target_wh, v_need;
      END IF;
    END IF;
   ELSE
     v_path := 'add_m2m_no_wh_draw';
   END IF;
    IF p_filled_quantity > 0 THEN
      UPDATE pod_inventory
         SET current_stock = current_stock + p_filled_quantity,
             estimated_remaining = current_stock + p_filled_quantity,
             snapshot_at = now()
       WHERE machine_id = v_dispatch.machine_id AND shelf_id = v_dispatch.shelf_id
         AND boonz_product_id = v_dispatch.boonz_product_id AND status = 'Active'
         AND ((expiration_date = v_effective_expiry) OR (expiration_date IS NULL AND v_effective_expiry IS NULL))
       RETURNING pod_inventory_id INTO v_pod_id;
      IF NOT FOUND THEN
        INSERT INTO pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date,
          current_stock, estimated_remaining, expiration_date, batch_id, status, snapshot_at, created_at)
        VALUES (v_dispatch.machine_id, v_dispatch.shelf_id, v_dispatch.boonz_product_id, CURRENT_DATE,
          p_filled_quantity, p_filled_quantity, v_effective_expiry,
          format('DISPATCH-%s', v_dispatch.dispatch_date), 'Active', now(), now())
        RETURNING pod_inventory_id INTO v_pod_id;
      END IF;
      v_prior_active_merged := 0;
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
          PERFORM public.log_expiry_entry_suspect('receive_dispatch_line_breakdown', v_dispatch.dispatch_date,
            v_entry_expiry, jsonb_build_object('dispatch_id', p_dispatch_id, 'machine_id', v_dispatch.machine_id,
              'boonz_product_id', v_dispatch.boonz_product_id));
          SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date = v_entry_expiry ORDER BY created_at ASC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_entry_qty WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
          ELSE
            PERFORM set_config('app.provenance_reason', CASE WHEN v_dispatch.wh_approved_at IS NOT NULL THEN 'dispatch_receive' ELSE 'dispatch_return_unverified' END, true);
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
          PERFORM set_config('app.provenance_reason', CASE WHEN v_dispatch.wh_approved_at IS NOT NULL THEN 'dispatch_receive' ELSE 'dispatch_return_unverified' END, true);
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
  UPDATE refill_dispatching
     SET filled_quantity = p_filled_quantity, item_added = true, dispatched = true, packed = true, picked_up = true,
         remainder_credited = true,
         pack_outcome = CASE
           WHEN v_dispatch.action IN ('Refill','Add New','Add') AND NOT COALESCE(v_dispatch.is_m2m, false)
             THEN (CASE WHEN p_filled_quantity < v_planned THEN 'partial' ELSE 'packed' END)::public.pack_outcome_enum
           ELSE pack_outcome
         END
   WHERE dispatch_id = p_dispatch_id;
  RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'action', v_dispatch.action, 'filled_quantity', p_filled_quantity, 'planned_quantity', v_planned, 'return_delta', v_return_delta, 'overfill', v_overfill, 'pod_inventory_id', v_pod_id, 'pod_archived', v_pod_archived, 'prior_active_merged', v_prior_active_merged, 'consumer_drained', v_consumer_drawn, 'path', v_path, 'effective_expiry', v_effective_expiry, 'received_by', p_received_by, 'credit_summary', v_credit_summary, 'overfill_debits', v_overfill_debits, 'wh_credit_skipped', CASE WHEN COALESCE(v_dispatch.is_m2m,false) THEN 'm2m' WHEN v_supply = 'venue_team' THEN 'venue_team' ELSE NULL END, 'status', 'received', 'undo_prior_return_qty', v_undo_total);
END;
$function$;

-- ============================================================
-- 8. return_dispatch_line -- class (a), role check inserted at the very top.
--    Everything below unchanged, including the item_added=true refusal guard that was
--    already live (confirmed, not re-derived here).
-- ============================================================
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
  v_target_wh uuid;
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
  v_origin_credited boolean := false;
  v_caller_role text; -- PRD-139b 2B
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'return_dispatch_line', true);
  PERFORM set_config('app.provenance_reason', 'dispatch_return', true);
  PERFORM set_config('app.source_event_id', p_dispatch_id::text, true);

  -- PRD-139b 2B: fail-closed role check, inserted at the top only. Everything below is
  -- byte-for-byte unchanged (diffed in docs/prds/PRD-139b-log.md).
  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NULL OR v_caller_role IS NULL
     OR v_caller_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'return_dispatch_line: forbidden for role %', COALESCE(v_caller_role, 'none (no session)');
  END IF;

  SELECT * INTO v_dispatch FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.returned = true THEN RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'status', 'already_returned', 'message', 'This dispatch was already returned, no changes made'); END IF;
  -- ── PRD-113 A8 ────────────────────────────────────────────────────────────
  -- The Remove branch below credits warehouse_inventory with ABS(quantity) — this is the
  -- "confirmed removal" path, and it is reachable straight from the driver's own button
  -- on /field/dispatching. For an in-machine move those units go to another shelf of the
  -- SAME machine and never reach the warehouse, so that credit is phantom stock.
  -- Refused in the same shape as the PRD-070 is_m2m block immediately below: a structured
  -- 'refused' object rather than a RAISE, because the driver page submits many lines in one
  -- pass and one refused leg must not abort the rest of the trip.
  IF v_dispatch.action = 'Remove'
     AND COALESCE(public.is_internal_move_dispatch(p_dispatch_id), false) THEN
    RETURN jsonb_build_object(
      'dispatch_id', p_dispatch_id,
      'status',      'refused',
      'reason',      'internal_move_return_blocked',
      'machine_id',  v_dispatch.machine_id,
      'shelf_id',    v_dispatch.shelf_id,
      'message',     'This leg is an in-machine move: the units go to another shelf of this '
                  || 'same machine and never reach the warehouse. Crediting them would create '
                  || 'phantom warehouse stock. If it really is a warehouse return, call '
                  || 'clear_internal_move_flag(dispatch_id, reason) first.');
  END IF;
  IF COALESCE(v_dispatch.is_m2m, false) = true THEN
    RETURN jsonb_build_object(
      'dispatch_id', p_dispatch_id,
      'status', 'refused',
      'reason', 'm2m_return_blocked',
      'm2m_transfer_id', v_dispatch.m2m_transfer_id,
      'sibling_leg_dispatch_id',
        (SELECT r2.dispatch_id FROM public.refill_dispatching r2
          WHERE r2.m2m_transfer_id = v_dispatch.m2m_transfer_id
            AND r2.dispatch_id <> p_dispatch_id
          ORDER BY r2.dispatch_id LIMIT 1),
      'message', 'This is a machine-to-machine (M2M) transfer leg. Returning it here would mint warehouse stock for units physically at the partner machine. Unwind the transfer PAIR via the M2M flow (PRD-056), not return_dispatch_line.');
  END IF;
  IF v_dispatch.item_added = true THEN
    RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'status', 'refused', 'reason', 'already_received',
      'message', format('Dispatch %s already received (item_added=true); nothing to return.', p_dispatch_id));
  END IF;
  IF (v_dispatch.skipped = true OR v_dispatch.cancelled = true OR COALESCE(v_dispatch.include, true) = false)
     AND v_dispatch.packed = false AND v_dispatch.picked_up = false THEN
    RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'status', 'refused', 'reason', 'never_physical',
      'state', CASE WHEN v_dispatch.skipped THEN 'SKIPPED' WHEN v_dispatch.cancelled THEN 'CANCELLED' ELSE 'EXCLUDED' END,
      'skip_reason', COALESCE(v_dispatch.skip_reason, 'no reason recorded'),
      'message', format('Dispatch %s is %s and was never packed or picked up. Nothing physical to return.',
        p_dispatch_id, CASE WHEN v_dispatch.skipped THEN 'SKIPPED' WHEN v_dispatch.cancelled THEN 'CANCELLED' ELSE 'EXCLUDED (include=false)' END));
  END IF;
  IF p_returned_by IS NULL AND v_dispatch.packed = false AND v_dispatch.picked_up = false THEN
    RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'status', 'refused', 'reason', 'no_actor_non_physical',
      'message', format('Dispatch %s has no actor (system call) and was never packed or picked up. Refusing system return of a non-physical line.', p_dispatch_id));
  END IF;

  -- PRD-121 Phase 2 P1.5: every real return (past this point, we are actually going to
  -- commit one) must carry a reason. Non-empty, not a length floor -- this is a controlled
  -- FE dropdown (RETURN_REASONS), not free text; its shortest legitimate value is "Other".
  IF p_return_reason IS NULL OR length(trim(p_return_reason)) = 0 THEN
    RAISE EXCEPTION 'return_dispatch_line: p_return_reason is required for dispatch %', p_dispatch_id;
  END IF;

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
    -- PRD-137 F2: "Could not remove" means the driver never got the product off the shelf.
    -- Nothing physical happened, so credit nothing and touch no inventory table.
    IF p_return_reason = 'Could not remove' THEN
      v_return_qty := 0;
      v_path := 'could_not_remove';
    ELSE
    v_return_qty := ABS(v_dispatch.quantity);
    v_path := 'remove';
    PERFORM set_config('app.mutation_reason', format('return_dispatch_line REMOVE: dispatch %s, %s units (reason: %s, by: %s, breakdown=%s, effective_expiry=%s)', p_dispatch_id, v_return_qty, COALESCE(p_return_reason, 'confirmed_removal'), COALESCE(p_returned_by::text, 'system'), p_batch_breakdown IS NOT NULL, v_effective_expiry), true);
    IF v_return_qty > 0 THEN
      IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN
        SELECT * INTO v_existing_row FROM warehouse_inventory WHERE wh_inventory_id = v_dispatch.from_wh_inventory_id FOR UPDATE;
        IF FOUND THEN
          v_path := 'remove_reactivate_origin';
          UPDATE warehouse_inventory
             SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_qty,
                 status = CASE WHEN status = 'Inactive' THEN 'Active' ELSE status END
           WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
          v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_existing_row.wh_inventory_id, 'expiry', v_existing_row.expiration_date, 'qty', v_return_qty, 'mode', 'reactivated_origin');
          v_origin_credited := true;
        END IF;
      END IF;
      IF NOT v_origin_credited THEN
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
    END IF;
    UPDATE pod_inventory SET status = 'Inactive', removal_reason = format('removed_via_dispatch_%s', p_dispatch_id) WHERE machine_id = v_dispatch.machine_id AND boonz_product_id = v_dispatch.boonz_product_id AND (shelf_id = v_dispatch.shelf_id OR v_dispatch.shelf_id IS NULL) AND status = 'Active';
    GET DIAGNOSTICS v_pod_archived = ROW_COUNT;
    END IF;
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
  UPDATE refill_dispatching SET returned = true, dispatched = true, filled_quantity = 0, return_reason = p_return_reason,
         pack_outcome = 'returned'::public.pack_outcome_enum
   WHERE dispatch_id = p_dispatch_id;
  RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'action', v_dispatch.action, 'return_qty', v_return_qty, 'return_reason', p_return_reason, 'returned_by', p_returned_by, 'consumer_drained', v_consumer_row.wh_inventory_id IS NOT NULL, 'pod_archived', v_pod_archived, 'path', v_path, 'effective_expiry', v_effective_expiry, 'credit_summary', v_credit_summary, 'status', 'returned');
END;
$function$;

-- ============================================================
-- 9. driver_confirm_remove -- class (a), role check at the very top.
-- ============================================================
CREATE OR REPLACE FUNCTION public.driver_confirm_remove(p_dispatch_id uuid, p_qty_removed numeric, p_batch_breakdown jsonb DEFAULT NULL::jsonb, p_driver_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_dispatch refill_dispatching%ROWTYPE;
  v_today date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  v_caller_role text; -- PRD-139b 2B
BEGIN
  -- PRD-139b 2B: fail-closed role check, inserted at the top. No role check existed before.
  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NULL OR v_caller_role IS NULL
     OR v_caller_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'driver_confirm_remove: forbidden for role %', COALESCE(v_caller_role, 'none (no session)');
  END IF;

  SELECT * INTO v_dispatch FROM refill_dispatching
  WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.action <> 'Remove' THEN
    RAISE EXCEPTION 'driver_confirm_remove only works for action=Remove (got %)', v_dispatch.action;
  END IF;
  IF NOT v_dispatch.packed THEN RAISE EXCEPTION 'Dispatch not yet packed'; END IF;
  IF NOT v_dispatch.picked_up THEN RAISE EXCEPTION 'Dispatch not yet picked up'; END IF;
  IF v_dispatch.driver_confirmed_at IS NOT NULL THEN
    RAISE EXCEPTION 'Dispatch already driver-confirmed at % with qty %',
      v_dispatch.driver_confirmed_at, v_dispatch.driver_confirmed_qty;
  END IF;
  IF v_dispatch.item_added OR v_dispatch.returned THEN
    RAISE EXCEPTION 'Dispatch already terminal (item_added=% returned=%)',
      v_dispatch.item_added, v_dispatch.returned;
  END IF;
  IF p_qty_removed IS NULL OR p_qty_removed < 0 THEN
    RAISE EXCEPTION 'p_qty_removed must be >= 0 (use return_dispatch_line if no items removed)';
  END IF;

  -- R5a: a per-variant expiry/qty breakdown is required when the line's own bound expiry is
  -- missing or within 7 days, so the driver enters what they actually read off the pack instead
  -- of the system trusting a stale or absent bound expiry.
  IF COALESCE(jsonb_array_length(p_batch_breakdown), 0) = 0
     AND (v_dispatch.expiry_date IS NULL OR v_dispatch.expiry_date <= v_today + 7) THEN
    RAISE EXCEPTION 'driver_confirm_remove: this line''s bound expiry is % (or missing) - enter the expiry and quantity read off the pack for each variant via p_batch_breakdown before confirming',
      COALESCE(v_dispatch.expiry_date::text, 'NULL');
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'driver_confirm_remove', true);
  PERFORM set_config('app.mutation_reason',
    format('driver_confirm_remove by %s: %s units removed%s',
      COALESCE(p_driver_id::text, 'driver'), p_qty_removed,
      CASE WHEN p_notes IS NOT NULL THEN ' - ' || p_notes ELSE '' END), true);

  UPDATE refill_dispatching SET
    driver_confirmed_qty = p_qty_removed,
    driver_confirmed_at = now(),
    driver_confirmed_by = p_driver_id,
    driver_confirmed_breakdown = p_batch_breakdown,
    dispatched = true,  -- driver-side complete
    comment = COALESCE(comment, '') ||
              CASE WHEN p_notes IS NOT NULL THEN E'\n[Driver: ' || p_notes || ']' ELSE '' END
  WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object(
    'status', 'driver_confirmed_pending_wh_approval',
    'dispatch_id', p_dispatch_id,
    'qty_removed', p_qty_removed,
    'driver_id', p_driver_id,
    'next_step', 'WH manager reviews in Inventory tab and calls wh_approve_remove_receipt or wh_approve_remove_receipt_multivariant'
  );
END;
$function$;
