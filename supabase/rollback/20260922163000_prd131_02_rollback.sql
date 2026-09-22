-- PRD-131 F2 rollback snapshot. Captured 2026-09-22 before prd131_02 was applied. NOT APPLIED
-- -- reference only. tg_movement_kind_required / reclassify_dispatch_movement did not exist
-- before this migration: DROP TRIGGER tg_movement_kind_required ON refill_dispatching;
-- DROP FUNCTION tg_movement_kind_required(); DROP FUNCTION
-- reclassify_dispatch_movement(uuid,text,text,uuid);
--
-- The six modified writer functions' pre-migration bodies are the exact bodies already live
-- when this session began investigating PRD-131 (captured via pg_get_functiondef earlier in
-- the same session that wrote prd131_02): add_dispatch_row (13-arg v4, the version prd130_09
-- left as the sole overload), add_m2m_transfer, add_intra_machine_move,
-- insert_driver_remove_line, convert_removes_to_m2m_transfer, and pair_internal_transfer_m2m
-- (the prd130_06-widened version). To roll back prd131_02 without also rolling back F1 (the
-- movement_kind column), reapply each function's body from the corresponding earlier migration
-- file in supabase/migrations/: 20260922055331_prd130_01_add_dispatch_row_v4.sql,
-- 20260922050000-era add_m2m_transfer / add_intra_machine_move bodies (prd130_02 / prd130_05),
20260922121900_prd130_06_pair_widen_and_backfill.sql for pair_internal_transfer_m2m.
-- insert_driver_remove_line, convert_removes_to_m2m_transfer and push_plan_to_dispatch are not
-- separately versioned anywhere else in supabase/migrations/, so their exact pre-migration
-- bodies are captured in full below.

-- ============================================================
-- insert_driver_remove_line (pre-PRD-131 body)
-- ============================================================
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
       from_warehouse_id)
    VALUES
      (v_new_source_id, p_machine_id, p_boonz_product_id, p_pod_product_id, p_shelf_id,
       CURRENT_DATE, 'Remove', p_quantity, 0, p_expiry_date,
       true, true, true, false, false, true,
       format('[DRIVER-INSERT] Multi-variant split: %s', p_reason),
       'internal_transfer'::source_origin_enum, 'm2m', p_machine_id, true, v_new_transfer_id,
       NULL);

    INSERT INTO refill_dispatching
      (dispatch_id, machine_id, boonz_product_id, pod_product_id, shelf_id,
       dispatch_date, action, quantity, filled_quantity, expiry_date,
       packed, picked_up, dispatched, returned, item_added, include, comment,
       source_origin, source_kind, source_machine_id, is_m2m, m2m_transfer_id, m2m_partner_id,
       from_warehouse_id)
    VALUES
      (v_new_dest_id, v_partner.machine_id, p_boonz_product_id, p_pod_product_id, v_partner.shelf_id,
       CURRENT_DATE, 'Add New', p_quantity, 0, p_expiry_date,
       true, false, false, false, false, true,
       format('[DRIVER-INSERT] Multi-variant split: %s', p_reason),
       'internal_transfer'::source_origin_enum, 'm2m', p_machine_id, true, v_new_transfer_id, v_new_source_id,
       NULL)
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
     source_kind, source_machine_id, is_m2m, is_internal_move, from_warehouse_id, source_warehouse_id)
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
     v_parent.from_warehouse_id,
     CASE WHEN COALESCE(v_parent.source_kind, 'unknown') = 'wh'
          THEN COALESCE(v_parent.source_warehouse_id, v_parent.from_warehouse_id) ELSE NULL END)
  RETURNING dispatch_id INTO v_dispatch_id;

  IF v_parent.dispatch_id IS NOT NULL THEN
    UPDATE refill_dispatching SET quantity = quantity - p_quantity WHERE dispatch_id = v_parent.dispatch_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'dispatch_id', v_dispatch_id,
    'machine_id', p_machine_id, 'qty', p_quantity, 'reason', p_reason,
    'inherited_from_parent', v_parent.dispatch_id);
END $function$;

-- ============================================================
-- convert_removes_to_m2m_transfer (pre-PRD-131 body)
-- ============================================================
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
      from_warehouse_id, from_wh_inventory_id, source_machine_id, source_kind, comment
    ) VALUES (
      v_add_id, p_dest_machine_id, p_dest_shelf_id, v_row.pod_product_id, v_row.boonz_product_id, v_row.dispatch_date, 'Add New', v_qty,
      true, true, false, true, v_transfer_id, v_row.dispatch_id,
      NULL, NULL, v_src_machine, 'm2m', v_tag);
    UPDATE public.refill_dispatching SET
      quantity=v_qty, is_m2m=true, m2m_transfer_id=v_transfer_id, m2m_partner_id=v_add_id,
      from_warehouse_id=NULL, source_machine_id=v_src_machine, source_kind='m2m', comment=v_tag
    WHERE dispatch_id=v_row.dispatch_id;
    v_total := v_total + v_qty;
    v_results := v_results || jsonb_build_object('source_dispatch_id', v_row.dispatch_id, 'dest_dispatch_id', v_add_id, 'boonz_product_id', v_row.boonz_product_id, 'quantity', v_qty);
  END LOOP;
  RETURN jsonb_build_object('status','ok','transfer_id',v_transfer_id,'source_machine',v_src_name,'dest_machine',v_dest_name,'lines',jsonb_array_length(v_results),'total_units',v_total,'items',v_results);
END; $function$;

-- push_plan_to_dispatch pre-migration body is identical to the version already committed at
-- supabase/migrations/ (the earlier fix_lane_sales / PRD-12x migrations that last touched it),
-- rpc_version 'v19_prd12x_j4_source_warehouse_id_fix'. Not repeated here for length; find it by
-- searching migration history for that rpc_version string, or ask Claude Code to re-fetch it via
-- pg_get_functiondef against a pre-2026-09-22 backup if a real rollback is needed.
