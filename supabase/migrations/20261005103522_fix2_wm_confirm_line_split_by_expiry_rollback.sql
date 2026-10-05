-- Rollback for 20261005103522_fix2_wm_confirm_line_split_by_expiry.sql: restore
-- wm_confirm_line's exact prior signature and body (no p_batch_breakdown parameter).
--
-- NOTE: dropping the DEFAULT-valued trailing parameter requires DROP + CREATE (a plain
-- CREATE OR REPLACE cannot remove a parameter), so this rollback drops the 10-arg signature
-- first, then recreates the original 9-arg function.

DROP FUNCTION IF EXISTS public.wm_confirm_line(uuid, numeric, date, text, uuid, text, text, uuid, boolean, jsonb);

CREATE OR REPLACE FUNCTION public.wm_confirm_line(p_line_id uuid, p_qty numeric, p_expiry date, p_outcome text, p_target_machine_id uuid DEFAULT NULL::uuid, p_disposal_code text DEFAULT NULL::text, p_reason text DEFAULT NULL::text, p_caller uuid DEFAULT NULL::uuid, p_dry_run boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller, auth.uid());
  v_role text; v_line record; v_target_wh uuid; v_existing warehouse_inventory%ROWTYPE;
  v_wh_inventory_id uuid; v_credited_mode text; v_state text; v_waste_by date;
  v_value_aed numeric; v_event_id uuid;
BEGIN
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles WHERE id = v_user_id
      AND role = ANY(ARRAY['warehouse','operator_admin','superadmin','manager'])
  ) THEN RAISE EXCEPTION 'forbidden: wm_confirm_line requires warehouse, operator_admin, superadmin, or manager'; END IF;
  IF p_line_id IS NULL THEN RAISE EXCEPTION 'wm_confirm_line: p_line_id is required'; END IF;
  IF p_qty IS NULL OR p_qty <= 0 THEN RAISE EXCEPTION 'wm_confirm_line: p_qty must be > 0'; END IF;
  IF p_outcome NOT IN ('restocked','redeploy_pending','waste','acknowledged') THEN
    RAISE EXCEPTION 'wm_confirm_line: p_outcome must be restocked | redeploy_pending | waste | acknowledged (got %)', p_outcome; END IF;
  IF p_expiry IS NOT NULL AND p_expiry = '2099-12-31'::date THEN
    RAISE EXCEPTION 'wm_confirm_line: p_expiry cannot be the 2099-12-31 sentinel — supply the real batch date or NULL'; END IF;
  IF p_outcome = 'waste' AND COALESCE(p_disposal_code,'') = '' THEN
    RAISE EXCEPTION 'wm_confirm_line: p_disposal_code is required when p_outcome=waste'; END IF;
  IF p_disposal_code IS NOT NULL AND p_disposal_code NOT IN ('Waste','Returning to supplier','Returned to supplier') THEN
    RAISE EXCEPTION 'wm_confirm_line: p_disposal_code must be Waste|Returning to supplier|Returned to supplier (got %)', p_disposal_code; END IF;
  IF p_outcome = 'redeploy_pending' AND (p_target_machine_id IS NULL OR p_expiry IS NULL) THEN
    RAISE EXCEPTION 'wm_confirm_line: redeploy_pending requires p_target_machine_id and p_expiry'; END IF;
  IF COALESCE(p_reason,'') = '' THEN RAISE EXCEPTION 'wm_confirm_line: p_reason is required'; END IF;

  SELECT * INTO v_line FROM public.v_wm_confirmations WHERE line_id = p_line_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'wm_confirm_line: % is not an open Warehouse Confirmations line', p_line_id; END IF;

  IF v_line.source IN ('refill_return_ack', 'quarantine_batch') THEN
    IF p_outcome <> 'acknowledged' THEN
      RAISE EXCEPTION 'wm_confirm_line: source % only accepts p_outcome=acknowledged (got %)', v_line.source, p_outcome;
    END IF;

    IF p_dry_run THEN
      RETURN jsonb_build_object('status', 'dry_run_ok', 'line_id', p_line_id, 'source', v_line.source,
        'boonz_product_id', v_line.boonz_product_id, 'qty', p_qty, 'outcome', 'acknowledged');
    END IF;

    IF v_line.source = 'refill_return_ack' THEN
      PERFORM public.set_write_context('wm_confirm_line',
        format('wm_confirm_line line=%s source=%s qty=%s outcome=acknowledged by=%s: %s',
          p_line_id, v_line.source, p_qty, COALESCE(v_user_id::text,'system'), p_reason),
        'dispatch_return', p_line_id::text);
      UPDATE public.refill_dispatching SET wh_approved_at = now(), wh_approved_by = v_user_id
       WHERE dispatch_id = p_line_id;
    ELSE
      PERFORM set_config('app.via_rpc',  'true', true);
      PERFORM set_config('app.rpc_name', 'wm_confirm_line', true);
      PERFORM set_config('app.mutation_reason',
        format('wm_confirm_line line=%s source=quarantine_batch qty=%s outcome=acknowledged by=%s: %s',
          p_line_id, p_qty, COALESCE(v_user_id::text,'system'), p_reason), true);
      UPDATE public.warehouse_inventory SET provenance_reason = 'manual_adjust'
       WHERE wh_inventory_id = p_line_id;
    END IF;

    INSERT INTO public.disposition_events (actor, source, machine_id, shelf_id, boonz_product_id, expiration_date, qty, state, reason, dispatch_id, wh_inventory_id)
    VALUES (v_user_id, 'return_receipt', v_line.machine_id, v_line.shelf_id, v_line.boonz_product_id, p_expiry, p_qty,
      'restocked', format('[%s] %s', v_line.source, p_reason),
      CASE WHEN v_line.source = 'refill_return_ack' THEN p_line_id ELSE NULL END,
      CASE WHEN v_line.source = 'quarantine_batch' THEN p_line_id ELSE NULL END)
    RETURNING event_id INTO v_event_id;

    RETURN jsonb_build_object('status', 'confirmed', 'line_id', p_line_id, 'source', v_line.source, 'event_id', v_event_id, 'outcome', 'acknowledged', 'qty', p_qty);
  END IF;

  v_target_wh := (SELECT primary_warehouse_id FROM public.machines WHERE machine_id = v_line.machine_id);
  IF v_target_wh IS NULL THEN RAISE EXCEPTION 'wm_confirm_line: machine % has no primary_warehouse_id', v_line.machine_id; END IF;
  SELECT avg_cost INTO v_value_aed FROM public.boonz_products WHERE product_id = v_line.boonz_product_id;
  v_value_aed := v_value_aed * p_qty;
  v_state := p_outcome;
  v_waste_by := CASE WHEN p_outcome = 'redeploy_pending' THEN p_expiry - 2 ELSE NULL END;

  IF p_dry_run THEN
    RETURN jsonb_build_object('status', 'dry_run_ok', 'line_id', p_line_id, 'source', v_line.source, 'machine_id', v_line.machine_id,
      'boonz_product_id', v_line.boonz_product_id, 'qty', p_qty, 'expiry', p_expiry, 'outcome', p_outcome,
      'target_warehouse_id', v_target_wh, 'target_machine_id', p_target_machine_id, 'waste_by', v_waste_by, 'value_aed', v_value_aed);
  END IF;

  PERFORM public.set_write_context('wm_confirm_line',
    format('wm_confirm_line line=%s source=%s qty=%s expiry=%s outcome=%s by=%s: %s',
      p_line_id, v_line.source, p_qty, p_expiry, p_outcome, COALESCE(v_user_id::text,'system'), p_reason),
    CASE WHEN p_outcome = 'waste' THEN 'expiry_writeoff' ELSE 'dispatch_return' END, p_line_id::text);

  SELECT * INTO v_existing FROM public.warehouse_inventory
   WHERE boonz_product_id = v_line.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active'
     AND ((expiration_date = p_expiry) OR (expiration_date IS NULL AND p_expiry IS NULL))
   ORDER BY created_at ASC LIMIT 1 FOR UPDATE;

  IF FOUND THEN
    v_credited_mode := 'topped_up'; v_wh_inventory_id := v_existing.wh_inventory_id;
    UPDATE public.warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock,0) + p_qty,
      reserved_for_machine_id = CASE WHEN p_outcome = 'redeploy_pending' THEN p_target_machine_id ELSE reserved_for_machine_id END
     WHERE wh_inventory_id = v_wh_inventory_id;
  ELSE
    v_credited_mode := 'inserted';
    INSERT INTO public.warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id, reserved_for_machine_id)
    VALUES (v_line.boonz_product_id, p_qty, p_expiry, 'Active', format('WM-CONFIRM-%s', p_line_id), CURRENT_DATE, v_target_wh,
      CASE WHEN p_outcome = 'redeploy_pending' THEN p_target_machine_id ELSE NULL END)
    RETURNING wh_inventory_id INTO v_wh_inventory_id;
  END IF;

  IF p_outcome = 'waste' THEN PERFORM public.warehouse_expire_writeoff(v_wh_inventory_id, p_reason, v_user_id, p_disposal_code); END IF;

  INSERT INTO public.disposition_events (actor, source, machine_id, shelf_id, boonz_product_id, expiration_date, qty, state,
     disposal_code, target_machine_id, waste_by, value_aed, reason, dispatch_id, wh_inventory_id)
  VALUES (v_user_id, 'return_receipt', v_line.machine_id, v_line.shelf_id, v_line.boonz_product_id, p_expiry, p_qty, v_state,
     CASE WHEN p_outcome = 'waste' THEN p_disposal_code ELSE NULL END,
     CASE WHEN p_outcome = 'redeploy_pending' THEN p_target_machine_id ELSE NULL END,
     v_waste_by, v_value_aed, p_reason, v_line.dispatch_id, v_wh_inventory_id)
  RETURNING event_id INTO v_event_id;

  IF v_line.source = 'dispatch_return' THEN
    UPDATE public.refill_dispatching SET wh_approved_at = now(), wh_approved_by = v_user_id WHERE dispatch_id = p_line_id;
  ELSE
    UPDATE public.disposition_events SET superseded_by_event = v_event_id WHERE event_id = p_line_id;
  END IF;

  RETURN jsonb_build_object('status', 'confirmed', 'line_id', p_line_id, 'source', v_line.source, 'event_id', v_event_id,
    'wh_inventory_id', v_wh_inventory_id, 'credited_mode', v_credited_mode,
    'qty', p_qty, 'expiry', p_expiry, 'outcome', p_outcome,
    'target_machine_id', p_target_machine_id, 'waste_by', v_waste_by, 'value_aed', v_value_aed);
END $function$;
