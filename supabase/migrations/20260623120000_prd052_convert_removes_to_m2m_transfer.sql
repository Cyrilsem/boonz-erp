-- PRD-052: convert plain Removes into a paired M2M transfer (retroactive remediation).
-- Backend only; touches ONLY refill_dispatching. No pod_inventory / warehouse_inventory writes
-- (both machines reconcile physical stock from WEIMI; the physical move already happened, so
-- adjusting pods here would double-count vs swap_between_machines). Mirrors swap_between_machines'
-- born-state for the dest leg, except dispatched=true (the carry already occurred; the driver
-- still confirms receipt at the dest via receive_dispatch_line, which skips WH because is_m2m=true).
--
-- Role: auth.uid() IS NULL (trusted server-side remediation, same posture as cron/n8n DEFINER
-- calls) OR a privileged operator (operator_admin/superadmin/manager).
-- Constitution: Art 1 (new canonical writer for this conversion; added to the
-- enforce_canonical_dispatch_write allowlist), Art 4 (validates inputs + role, sets app.via_rpc
-- + app.rpc_name), Art 6 (never writes warehouse_inventory.status — touches no WH at all),
-- Art 8 (generic write_audit_log trigger fires via app.via_rpc), Art 12 (forward-only),
-- Art 14 (no parallel table).

CREATE OR REPLACE FUNCTION public.convert_removes_to_m2m_transfer(
  p_dispatch_ids uuid[],
  p_dest_machine_id uuid,
  p_dest_shelf_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid         uuid := auth.uid();
  v_transfer_id uuid := gen_random_uuid();
  v_n           int;
  v_src_machine uuid;
  v_src_name    text;
  v_dest_name   text;
  v_row         refill_dispatching%ROWTYPE;
  v_add_id      uuid;
  v_qty         numeric;
  v_total       numeric := 0;
  v_results     jsonb := '[]'::jsonb;
  v_tag         text;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'convert_removes_to_m2m_transfer', true);

  -- Role gate (null-uid = trusted server-side remediation path).
  IF v_uid IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = v_uid AND role = ANY (ARRAY['operator_admin','superadmin','manager'])
  ) THEN
    RAISE EXCEPTION 'Unauthorized: operator_admin/superadmin/manager required';
  END IF;

  IF p_dispatch_ids IS NULL OR array_length(p_dispatch_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'p_dispatch_ids must be a non-empty array';
  END IF;

  -- Destination must exist and the shelf must belong to the dest machine.
  SELECT official_name INTO v_dest_name FROM public.machines WHERE machine_id = p_dest_machine_id;
  IF v_dest_name IS NULL THEN RAISE EXCEPTION 'Dest machine not found: %', p_dest_machine_id; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.shelf_configurations
    WHERE shelf_id = p_dest_shelf_id AND machine_id = p_dest_machine_id
  ) THEN
    RAISE EXCEPTION 'Dest shelf % not found on dest machine %', p_dest_shelf_id, p_dest_machine_id;
  END IF;

  -- Batch validation (atomic; any failure raises and rolls the whole tx back).
  SELECT count(*) INTO v_n FROM public.refill_dispatching WHERE dispatch_id = ANY(p_dispatch_ids);
  IF v_n <> array_length(p_dispatch_ids, 1) THEN
    RAISE EXCEPTION 'Some dispatch_ids not found (% of % exist)', v_n, array_length(p_dispatch_ids, 1);
  END IF;
  IF EXISTS (SELECT 1 FROM public.refill_dispatching WHERE dispatch_id = ANY(p_dispatch_ids) AND action <> 'Remove') THEN
    RAISE EXCEPTION 'All rows must be action=Remove';
  END IF;
  IF EXISTS (SELECT 1 FROM public.refill_dispatching WHERE dispatch_id = ANY(p_dispatch_ids) AND COALESCE(is_m2m,false) = true) THEN
    RAISE EXCEPTION 'Idempotency: one or more rows are already is_m2m=true (already converted)';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.refill_dispatching
    WHERE dispatch_id = ANY(p_dispatch_ids)
      AND (item_added = true OR COALESCE(cancelled,false) = true OR COALESCE(returned,false) = true)
  ) THEN
    RAISE EXCEPTION 'All rows must have item_added=false, cancelled=false, returned=false';
  END IF;
  SELECT count(DISTINCT machine_id) INTO v_n FROM public.refill_dispatching WHERE dispatch_id = ANY(p_dispatch_ids);
  IF v_n <> 1 THEN RAISE EXCEPTION 'All rows must share one source machine (found % distinct)', v_n; END IF;
  SELECT machine_id INTO v_src_machine FROM public.refill_dispatching WHERE dispatch_id = ANY(p_dispatch_ids) LIMIT 1;
  IF v_src_machine = p_dest_machine_id THEN RAISE EXCEPTION 'Source and destination machine must differ'; END IF;
  SELECT official_name INTO v_src_name FROM public.machines WHERE machine_id = v_src_machine;

  v_tag := format('M2M retro %s -> %s: %s', v_src_name, v_dest_name, p_reason);

  FOR v_row IN
    SELECT * FROM public.refill_dispatching WHERE dispatch_id = ANY(p_dispatch_ids) ORDER BY dispatch_id
  LOOP
    v_qty   := COALESCE(v_row.driver_confirmed_qty, v_row.quantity);
    v_add_id := gen_random_uuid();

    -- (b) dest Add New leg (mirror swap_between_machines born-state; dispatched=true: carry done).
    -- m2m_consistency CHECK (is_m2m=true) requires: from_warehouse_id NULL, source_kind in
    -- {m2m,truck_transfer} (or NULL), source_machine_id NOT NULL. Matches the existing
    -- warehouse+m2m pattern; source_origin left default so block_orphan_internal_transfer
    -- (fires only on internal_transfer + NULL transfer_id) never trips.
    INSERT INTO public.refill_dispatching (
      dispatch_id, machine_id, shelf_id, pod_product_id, boonz_product_id,
      dispatch_date, action, quantity,
      packed, dispatched, picked_up,
      is_m2m, m2m_transfer_id, m2m_partner_id,
      from_warehouse_id, from_wh_inventory_id, source_machine_id, source_kind, comment
    ) VALUES (
      v_add_id, p_dest_machine_id, p_dest_shelf_id, v_row.pod_product_id, v_row.boonz_product_id,
      v_row.dispatch_date, 'Add New', v_qty,
      true, true, false,
      true, v_transfer_id, v_row.dispatch_id,
      NULL, NULL, v_src_machine, 'm2m', v_tag
    );

    -- (a) convert source + (c) bidirectional link source.partner = dest.
    -- Also satisfy m2m_consistency on the flipped source row (was source_kind='unknown',
    -- source_machine_id NULL, and one row had a non-null from_warehouse_id).
    UPDATE public.refill_dispatching SET
      quantity          = v_qty,
      is_m2m            = true,
      m2m_transfer_id   = v_transfer_id,
      m2m_partner_id    = v_add_id,
      from_warehouse_id = NULL,
      source_machine_id = v_src_machine,
      source_kind       = 'm2m',
      comment           = v_tag
    WHERE dispatch_id = v_row.dispatch_id;

    v_total   := v_total + v_qty;
    v_results := v_results || jsonb_build_object(
      'source_dispatch_id', v_row.dispatch_id,
      'dest_dispatch_id',   v_add_id,
      'boonz_product_id',   v_row.boonz_product_id,
      'quantity',           v_qty
    );
  END LOOP;

  RETURN jsonb_build_object(
    'status',         'ok',
    'transfer_id',    v_transfer_id,
    'source_machine', v_src_name,
    'dest_machine',   v_dest_name,
    'lines',          jsonb_array_length(v_results),
    'total_units',    v_total,
    'items',          v_results
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.convert_removes_to_m2m_transfer(uuid[], uuid, uuid, text) FROM public;
GRANT EXECUTE ON FUNCTION public.convert_removes_to_m2m_transfer(uuid[], uuid, uuid, text) TO authenticated, service_role;

-- Add the new canonical writer to the enforce_canonical_dispatch_write allowlist (same migration).
CREATE OR REPLACE FUNCTION public.enforce_canonical_dispatch_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_via_rpc text     := current_setting('app.via_rpc', true);
  v_rpc_name text    := current_setting('app.rpc_name', true);
  v_via_trigger text := current_setting('app.via_trigger', true);
  v_uid uuid         := auth.uid();
  v_role text;
  v_allowlist text[] := ARRAY[
    'write_refill_plan','pack_dispatch_line','receive_dispatch_line','return_dispatch_line',
    'swap_between_machines','repair_unbound_dispatch','repair_orphan_internal_transfer',
    'cancel_dispatch_line','mark_dispatch_vox_sourced','mark_internal_transfer',
    'sync_dispatch_expiry_from_pinned_wh',
    'add_dispatch_row','approve_refill_plan','auto_generate_refill_plan',
    'edit_dispatch_product','edit_dispatch_qty','edit_dispatch_shelf',
    'inject_swap','push_plan_to_dispatch','remove_dispatch_row',
    'set_dispatch_source','wh_approve_remove_receipt_multivariant',
    'update_dispatch_comment','set_dispatch_include','insert_driver_remove_line',
    'skip_dispatch_line',
    'convert_removes_to_m2m_transfer'  -- PRD-052
  ];
  v_pre_image jsonb; v_post_image jsonb; v_pk text;
BEGIN
  IF coalesce(v_via_rpc,'')='true' AND coalesce(v_rpc_name,'') = ANY(v_allowlist) THEN
    RETURN coalesce(NEW, OLD);
  END IF;
  IF coalesce(v_via_trigger,'') = 'true' THEN RETURN coalesce(NEW, OLD); END IF;

  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
  END IF;
  IF TG_OP='DELETE' THEN v_pre_image := to_jsonb(OLD); v_pk := OLD.dispatch_id::text;
  ELSIF TG_OP='UPDATE' THEN v_pre_image := to_jsonb(OLD); v_post_image := to_jsonb(NEW); v_pk := NEW.dispatch_id::text;
  ELSE v_post_image := to_jsonb(NEW); v_pk := NEW.dispatch_id::text;
  END IF;

  INSERT INTO public.bypass_violation_log
    (table_name, operation, actor, caller_role, rpc_name, via_rpc, app_via_trigger, row_pk, pre_image, post_image, client_info)
  VALUES
    (TG_TABLE_NAME, TG_OP, v_uid, v_role, v_rpc_name, coalesce(v_via_rpc,'')='true', v_via_trigger,
     v_pk, v_pre_image, v_post_image, current_setting('application_name', true));

  RAISE WARNING 'enforce_canonical_dispatch_write: bypass on %.% (op=%, rpc_name=%, via_rpc=%, actor=%).',
    TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP, coalesce(v_rpc_name,'<null>'), coalesce(v_via_rpc,'<null>'), coalesce(v_uid::text,'<null>');
  RETURN coalesce(NEW, OLD);
END $function$;
