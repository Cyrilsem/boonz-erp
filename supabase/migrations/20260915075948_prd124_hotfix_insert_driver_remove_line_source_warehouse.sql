-- CS hotfix, applied live at 11:55 Dubai (2026-09-15) directly via the
-- Supabase dashboard, pulled into the repo here for the ledger per ONE-LOOP-3.
--
-- The Phase 2 source_kind backfill had set source_kind='wh' on rows with no
-- source_warehouse_id, which meant insert_driver_remove_line's plain
-- (non-M2M) branch -- which only ever copied v_parent.source_kind straight
-- through -- produced a child row with source_kind='wh' and
-- source_warehouse_id NULL, violating refill_dispatching_source_consistency_chk
-- on every driver-inserted Remove line whose parent had been backfilled.
--
-- Fix: the plain branch now derives source_warehouse_id from the parent
-- (source_warehouse_id, else from_warehouse_id) and falls back to
-- source_kind='unknown' when neither exists, instead of blindly copying a
-- source_kind that the row can no longer satisfy.

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
       AND NOT COALESCE(rd.item_added, false)
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
