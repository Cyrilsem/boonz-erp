-- Rollback capture for 20260925011500_loopv2_a2_fix_cancel_dest_lookup.sql
-- Prior live body of cancel_m2m_transfer (as applied by 20260925010000_loopv2_a1_m2m_cancel.sql),
-- which looked up the destination leg by action IN ('Add New','Add') instead of m2m_partner_id.

CREATE OR REPLACE FUNCTION public.cancel_m2m_transfer(
  p_transfer_id uuid,
  p_reason text,
  p_convert_source_to_return boolean DEFAULT true,
  p_dry_run boolean DEFAULT true
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id      uuid := auth.uid();
  v_role         text;
  v_source       refill_dispatching%ROWTYPE;
  v_dest         refill_dispatching%ROWTYPE;
  v_primary_wh   uuid;
  v_shelf_code   text;
  v_before_source jsonb;
  v_before_dest   jsonb;
  v_return_result jsonb := NULL;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'cancel_m2m_transfer', true);

  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager','warehouse') THEN
      RAISE EXCEPTION 'cancel_m2m_transfer: requires operator_admin / superadmin / manager / warehouse';
    END IF;
  END IF;

  IF p_transfer_id IS NULL THEN
    RAISE EXCEPTION 'cancel_m2m_transfer: p_transfer_id is required';
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'cancel_m2m_transfer: p_reason must be at least 10 characters';
  END IF;

  SELECT * INTO v_source FROM public.refill_dispatching
   WHERE m2m_transfer_id = p_transfer_id AND action = 'Remove' AND COALESCE(is_m2m,false) = true
   ORDER BY created_at ASC LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'cancel_m2m_transfer: no Remove (source) leg found for transfer %', p_transfer_id;
  END IF;

  SELECT * INTO v_dest FROM public.refill_dispatching
   WHERE m2m_transfer_id = p_transfer_id AND action IN ('Add New','Add') AND COALESCE(is_m2m,false) = true
   ORDER BY created_at ASC LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'cancel_m2m_transfer: no Add New (destination) leg found for transfer %', p_transfer_id;
  END IF;

  IF v_source.driver_confirmed_at IS NOT NULL OR v_source.driver_outcome IS NOT NULL
     OR COALESCE(v_source.returned, false) OR COALESCE(v_source.filled_quantity, 0) > 0
     OR v_dest.driver_confirmed_at IS NOT NULL OR v_dest.driver_outcome IS NOT NULL
     OR COALESCE(v_dest.returned, false) OR COALESCE(v_dest.filled_quantity, 0) > 0
  THEN
    RAISE EXCEPTION 'cancel_m2m_transfer: transfer % already has driver activity (source: driver_confirmed_at=%, driver_outcome=%, returned=%, filled_quantity=%; dest: driver_confirmed_at=%, driver_outcome=%, returned=%, filled_quantity=%) -- cannot cancel a transfer the driver has already started',
      p_transfer_id,
      v_source.driver_confirmed_at, v_source.driver_outcome, v_source.returned, v_source.filled_quantity,
      v_dest.driver_confirmed_at, v_dest.driver_outcome, v_dest.returned, v_dest.filled_quantity;
  END IF;

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'status', 'dry_run_ok',
      'transfer_id', p_transfer_id,
      'source_dispatch_id', v_source.dispatch_id,
      'dest_dispatch_id', v_dest.dispatch_id,
      'source_machine_id', v_source.machine_id,
      'source_shelf_id', v_source.shelf_id,
      'boonz_product_id', v_source.boonz_product_id,
      'quantity', v_source.quantity,
      'convert_source_to_return', p_convert_source_to_return,
      'reason', p_reason
    );
  END IF;

  v_before_source := to_jsonb(v_source);
  v_before_dest := to_jsonb(v_dest);

  PERFORM set_config('app.mutation_reason',
    format('cancel_m2m_transfer %s by=%s: %s', p_transfer_id, COALESCE(v_user_id::text,'system'), p_reason), true);

  UPDATE public.refill_dispatching
     SET quantity            = 0,
         skipped             = true,
         skipped_at          = now(),
         skipped_by          = v_user_id,
         skip_reason         = p_reason,
         include             = false,
         edit_count          = edit_count + 1,
         last_edited_by      = v_user_id,
         last_edited_by_role = COALESCE(v_role, 'system'),
         last_edited_at      = now()
   WHERE dispatch_id = v_source.dispatch_id;

  UPDATE public.refill_dispatching
     SET quantity            = 0,
         skipped             = true,
         skipped_at          = now(),
         skipped_by          = v_user_id,
         skip_reason         = p_reason,
         include             = false,
         edit_count          = edit_count + 1,
         last_edited_by      = v_user_id,
         last_edited_by_role = COALESCE(v_role, 'system'),
         last_edited_at      = now()
   WHERE dispatch_id = v_dest.dispatch_id;

  INSERT INTO public.refill_dispatching_edit_log
    (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason)
  VALUES
    (v_source.dispatch_id, v_user_id, COALESCE(v_role, 'system'), 'cancel_m2m_transfer', v_before_source,
     jsonb_build_object('quantity', 0, 'skipped', true, 'include', false), p_reason),
    (v_dest.dispatch_id, v_user_id, COALESCE(v_role, 'system'), 'cancel_m2m_transfer', v_before_dest,
     jsonb_build_object('quantity', 0, 'skipped', true, 'include', false), p_reason);

  IF p_convert_source_to_return THEN
    SELECT primary_warehouse_id INTO v_primary_wh FROM public.machines WHERE machine_id = v_source.machine_id;
    IF v_primary_wh IS NULL THEN
      RAISE EXCEPTION 'cancel_m2m_transfer: source machine % has no primary_warehouse_id, cannot convert to a return', v_source.machine_id;
    END IF;
    SELECT shelf_code INTO v_shelf_code FROM public.shelf_configurations WHERE shelf_id = v_source.shelf_id;
    IF v_shelf_code IS NULL THEN
      RAISE EXCEPTION 'cancel_m2m_transfer: source leg % has no resolvable shelf_code, cannot convert to a return', v_source.dispatch_id;
    END IF;

    v_return_result := public.add_dispatch_row(
      v_source.machine_id, v_shelf_code, v_source.boonz_product_id, v_source.quantity,
      'Remove', v_source.dispatch_date, 'wh', v_primary_wh, NULL, COALESCE(v_role, 'system'),
      format('cancel_m2m_transfer %s converted to warehouse return: %s', p_transfer_id, p_reason),
      NULL, NULL
    );
  END IF;

  RETURN jsonb_build_object(
    'status', 'cancelled',
    'transfer_id', p_transfer_id,
    'source_dispatch_id', v_source.dispatch_id,
    'dest_dispatch_id', v_dest.dispatch_id,
    'converted_to_return', p_convert_source_to_return,
    'return_result', v_return_result
  );
END;
$function$;
