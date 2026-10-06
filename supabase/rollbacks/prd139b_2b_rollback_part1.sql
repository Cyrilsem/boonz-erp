-- Rollback for prd139b_2b_role_checks_part1: restores the exact pre-change bodies
-- (fetched via pg_get_functiondef before any edit) for pack_dispatch_line,
-- repack_machine, skip_dispatch_line, confirm_machine_packed, edit_dispatch_qty,
-- receive_dispatch_line, return_dispatch_line, driver_confirm_remove.

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
  v_guard_out jsonb := '[]'::jsonb;
  v_ph_id uuid;
  v_machine_primary_wh uuid;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'pack_dispatch_line', true);
  PERFORM set_config('app.provenance_reason', 'dispatch_pack', true);
  PERFORM set_config('app.source_event_id', p_dispatch_id::text, true);
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
  IF v_dispatch.source_origin = 'vox_at_venue' THEN
    SELECT primary_warehouse_id INTO v_machine_primary_wh FROM machines WHERE machine_id = v_dispatch.machine_id;
    FOR v_pick IN SELECT * FROM jsonb_array_elements(p_picks) LOOP
      v_pick_qty  := COALESCE((v_pick->>'qty')::numeric, 0);
      IF v_pick_qty <= 0 THEN
        v_guard_out := v_guard_out || v_pick;
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
  IF v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
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
  IF v_uid IS NOT NULL AND v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
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
  v_p record;
  v_orphans jsonb := '[]'::jsonb;
  v_orphan_n integer := 0;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','confirm_machine_packed',true);
  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'confirm_machine_packed: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'confirm_machine_packed: p_reason required (>= 10 chars)';
  END IF;
  PERFORM set_config('app.mutation_reason', p_reason, true);
  SELECT machine_id INTO v_machine_id FROM public.machines WHERE official_name = p_machine_name;
  IF v_machine_id IS NULL THEN RAISE EXCEPTION 'confirm_machine_packed: machine % not found', p_machine_name; END IF;
  SELECT * INTO v_p FROM public.v_dispatch_pack_progress
   WHERE machine_id = v_machine_id AND dispatch_date = v_date;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','blocked','machine',p_machine_name,'dispatch_date',v_date,
      'unresolved_count',0,'unresolved','[]'::jsonb,
      'message','No included dispatch lines for this machine and date.');
  END IF;
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
  IF p_final THEN
    UPDATE public.refill_dispatching rd
       SET packed = true
     WHERE rd.machine_id = v_machine_id AND rd.dispatch_date = v_date
       AND COALESCE(rd.cancelled,false) = false AND COALESCE(rd.include,true) = true
       AND COALESCE(rd.skipped,false) = false
       AND rd.action NOT IN ('Refill','Add New','Add')
       AND COALESCE(rd.packed,false) = false;
  END IF;
  IF p_final THEN
    v_orphans   := COALESCE(v_p.orphaned_swap_legs, '[]'::jsonb);
    v_orphan_n  := COALESCE(v_p.orphaned_swap_leg_n, 0);
    IF v_orphan_n > 0 THEN
      UPDATE public.refill_dispatching rd
         SET needs_review  = true,
             review_reason = 'orphaned_swap_leg',
             review_status = 'pending'
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
  IF auth.uid() IS NOT NULL AND v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
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
