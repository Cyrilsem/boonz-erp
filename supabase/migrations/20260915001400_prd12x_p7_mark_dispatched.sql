-- PRD-124 #35 -- Mark All Dispatched cannot mark anything dispatched.
--
-- mark_dispatched(dispatch_ids) mirrors mark_picked_up exactly: flips
-- dispatched=true only on rows with picked_up=true and dispatched=false,
-- returns counts for already-dispatched / not-picked-up / not-found ids.
-- Added to enforce_canonical_dispatch_write's allowlist (it was missing --
-- every call would otherwise have logged a bypass_violation_log row even
-- though nothing was actually blocked).
CREATE OR REPLACE FUNCTION public.mark_dispatched(p_dispatch_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role         text;
  v_caller_id           uuid;
  v_dispatched_count    int := 0;
  v_already_dispatched_ids uuid[];
  v_not_picked_up_ids   uuid[];
  v_not_found_ids       uuid[];
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'mark_dispatched', true);

  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'No authenticated caller');
  END IF;

  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = v_caller_id;
  IF v_caller_role NOT IN ('field_staff', 'warehouse', 'operator_admin', 'superadmin', 'manager') THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'Insufficient role -- requires field_staff / warehouse / admin');
  END IF;

  IF p_dispatch_ids IS NULL OR array_length(p_dispatch_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'p_dispatch_ids must be a non-empty array');
  END IF;

  SELECT array_agg(id) INTO v_not_found_ids
  FROM unnest(p_dispatch_ids) AS id
  WHERE NOT EXISTS (SELECT 1 FROM public.refill_dispatching d WHERE d.dispatch_id = id);

  SELECT array_agg(d.dispatch_id) INTO v_not_picked_up_ids
  FROM public.refill_dispatching d
  WHERE d.dispatch_id = ANY(p_dispatch_ids) AND d.picked_up = false;

  SELECT array_agg(d.dispatch_id) INTO v_already_dispatched_ids
  FROM public.refill_dispatching d
  WHERE d.dispatch_id = ANY(p_dispatch_ids) AND d.picked_up = true AND d.dispatched = true;

  UPDATE public.refill_dispatching
  SET dispatched = true
  WHERE dispatch_id = ANY(p_dispatch_ids)
    AND picked_up   = true
    AND dispatched  = false;

  GET DIAGNOSTICS v_dispatched_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'status',                 'ok',
    'dispatched_count',       v_dispatched_count,
    'already_dispatched_ids', COALESCE(v_already_dispatched_ids, ARRAY[]::uuid[]),
    'not_picked_up_ids',      COALESCE(v_not_picked_up_ids,      ARRAY[]::uuid[]),
    'not_found_ids',          COALESCE(v_not_found_ids,          ARRAY[]::uuid[]),
    'caller_id',              v_caller_id,
    'caller_role',            v_caller_role
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 'error', 'error', SQLERRM, 'detail', SQLSTATE);
END;
$function$;

CREATE OR REPLACE FUNCTION public.enforce_canonical_dispatch_write()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_via_rpc text := current_setting('app.via_rpc', true); v_rpc_name text := current_setting('app.rpc_name', true);
  v_via_trigger text := current_setting('app.via_trigger', true); v_uid uuid := auth.uid(); v_role text;
  v_allowlist text[] := ARRAY[
    'write_refill_plan','pack_dispatch_line','receive_dispatch_line','return_dispatch_line',
    'swap_between_machines','repair_unbound_dispatch','repair_orphan_internal_transfer',
    'cancel_dispatch_line','mark_dispatch_vox_sourced','mark_internal_transfer',
    'sync_dispatch_expiry_from_pinned_wh','add_dispatch_row','approve_refill_plan','auto_generate_refill_plan',
    'edit_dispatch_product','edit_dispatch_qty','edit_dispatch_shelf','inject_swap','push_plan_to_dispatch','remove_dispatch_row',
    'set_dispatch_source','wh_approve_remove_receipt_multivariant','update_dispatch_comment','set_dispatch_include','insert_driver_remove_line',
    'skip_dispatch_line','convert_removes_to_m2m_transfer',
    'mark_picked_up','driver_confirm_remove','wh_approve_remove_receipt','review_driver_addition',
    'release_stale_unpacked_dispatches','decline_dispatch_return','unskip_dispatch_line',
    'confirm_machine_packed',
    'receive_dispatch_line_sourced_v3',
    'driver_substitute_dispatch_line','acknowledge_day_close_event','acknowledge_day_close',
    'mark_internal_move_legs','clear_internal_move_flag',
    'mark_dispatched'];
  v_pre_image jsonb; v_post_image jsonb; v_pk text;
BEGIN
  IF coalesce(v_via_rpc,'')='true' AND coalesce(v_rpc_name,'') = ANY(v_allowlist) THEN RETURN coalesce(NEW, OLD); END IF;
  IF coalesce(v_via_trigger,'') = 'true' THEN RETURN coalesce(NEW, OLD); END IF;
  IF v_uid IS NOT NULL THEN SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid; END IF;
  IF TG_OP='DELETE' THEN v_pre_image := to_jsonb(OLD); v_pk := OLD.dispatch_id::text;
  ELSIF TG_OP='UPDATE' THEN v_pre_image := to_jsonb(OLD); v_post_image := to_jsonb(NEW); v_pk := NEW.dispatch_id::text;
  ELSE v_post_image := to_jsonb(NEW); v_pk := NEW.dispatch_id::text; END IF;
  INSERT INTO public.bypass_violation_log (table_name, operation, actor, caller_role, rpc_name, via_rpc, app_via_trigger, row_pk, pre_image, post_image, client_info)
  VALUES (TG_TABLE_NAME, TG_OP, v_uid, v_role, v_rpc_name, coalesce(v_via_rpc,'')='true', v_via_trigger, v_pk, v_pre_image, v_post_image, current_setting('application_name', true));
  RAISE WARNING 'enforce_canonical_dispatch_write: bypass on %.% (op=%, rpc_name=%, via_rpc=%, actor=%).', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP, coalesce(v_rpc_name,'<null>'), coalesce(v_via_rpc,'<null>'), coalesce(v_uid::text,'<null>');
  RETURN coalesce(NEW, OLD);
END
$function$;
