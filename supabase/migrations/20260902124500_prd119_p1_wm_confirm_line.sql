-- PRD-119 P1 §4.1/§7: wm_confirm_line — the canonical confirm door for a
-- v_wm_confirmations queue line. WM taps confirm (or edits qty/date/outcome):
-- credits warehouse_inventory on the batch with THAT expiry (tops up an existing
-- Active row sharing the same expiry, else inserts a new one — never a 2099
-- sentinel, refused outright), writes the disposition_events ledger row, sets
-- reserved_for_machine_id + waste_by for a redeploy, and stamps wh_approved_at on
-- the source dispatch line so it leaves the queue. For outcome=waste, composes the
-- already-canonical warehouse_expire_writeoff rather than duplicating its status/
-- stock-zeroing logic.
--
-- wh_approve_remove_receipt / wh_approve_remove_receipt_multivariant / approve_return
-- are deliberately left untouched and callable — this absorbs their JOB going
-- forward per the PRD, FE routing to the new door is a separate (not yet done) step.
--
-- Cody: approve, Articles 1/4/6/8/12/16 — role gate matches set_wh_quarantine/
-- release_wh_quarantine, never writes warehouse_inventory.status directly (the one
-- status flip observed in testing comes from the already-approved
-- warehouse_expire_writeoff's own trigger, composed not duplicated), reads the
-- canonical v_wm_confirmations view, writes the canonical disposition_events ledger.
-- Verified end-to-end in rolled-back transactions on real rows: waste path (AMZ-1038
-- Kinder Delice qty 4 — queue closes, disposition state=waste, wh_approved_at
-- stamped, stock zeroed) and redeploy_pending path (IFLYMCC->AMZ-1029 Pepsi Regular
-- qty 8 — target_machine_id + waste_by on the ledger row, reserved_for_machine_id
-- set on warehouse_inventory, queue closes).
CREATE FUNCTION public.wm_confirm_line(
  p_line_id uuid, p_qty numeric, p_expiry date, p_outcome text,
  p_target_machine_id uuid DEFAULT NULL::uuid, p_disposal_code text DEFAULT NULL::text,
  p_reason text DEFAULT NULL::text, p_caller uuid DEFAULT NULL::uuid, p_dry_run boolean DEFAULT true
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
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
  IF p_outcome NOT IN ('restocked','redeploy_pending','waste') THEN
    RAISE EXCEPTION 'wm_confirm_line: p_outcome must be restocked | redeploy_pending | waste (got %)', p_outcome; END IF;
  IF p_expiry IS NOT NULL AND p_expiry = '2099-12-31'::date THEN
    RAISE EXCEPTION 'wm_confirm_line: p_expiry cannot be the 2099-12-31 sentinel — supply the real batch date or NULL'; END IF;
  IF p_outcome = 'waste' AND COALESCE(p_disposal_code,'') = '' THEN
    RAISE EXCEPTION 'wm_confirm_line: p_disposal_code is required when p_outcome=waste'; END IF;
  IF p_disposal_code IS NOT NULL AND p_disposal_code NOT IN ('Waste','Returning to supplier','Returned to supplier') THEN
    RAISE EXCEPTION 'wm_confirm_line: p_disposal_code must be Waste|Returning to supplier|Returned to supplier (got %)', p_disposal_code; END IF;
  IF p_outcome = 'redeploy_pending' AND (p_target_machine_id IS NULL OR p_expiry IS NULL) THEN
    RAISE EXCEPTION 'wm_confirm_line: redeploy_pending requires p_target_machine_id and p_expiry'; END IF;
  IF COALESCE(p_reason,'') = '' THEN RAISE EXCEPTION 'wm_confirm_line: p_reason is required'; END IF;
  SELECT * INTO v_line FROM public.v_wm_confirmations WHERE dispatch_id = p_line_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'wm_confirm_line: dispatch % is not an open Warehouse Confirmations line', p_line_id; END IF;
  v_target_wh := (SELECT primary_warehouse_id FROM public.machines WHERE machine_id = v_line.machine_id);
  IF v_target_wh IS NULL THEN RAISE EXCEPTION 'wm_confirm_line: machine % has no primary_warehouse_id', v_line.machine_id; END IF;
  SELECT avg_cost INTO v_value_aed FROM public.boonz_products WHERE product_id = v_line.boonz_product_id;
  v_value_aed := v_value_aed * p_qty;
  v_state := p_outcome;
  v_waste_by := CASE WHEN p_outcome = 'redeploy_pending' THEN p_expiry - 2 ELSE NULL END;
  IF p_dry_run THEN
    RETURN jsonb_build_object('status', 'dry_run_ok', 'dispatch_id', p_line_id, 'machine_id', v_line.machine_id,
      'boonz_product_id', v_line.boonz_product_id, 'qty', p_qty, 'expiry', p_expiry, 'outcome', p_outcome,
      'target_warehouse_id', v_target_wh, 'target_machine_id', p_target_machine_id, 'waste_by', v_waste_by, 'value_aed', v_value_aed);
  END IF;
  PERFORM public.set_write_context('wm_confirm_line',
    format('wm_confirm_line dispatch=%s qty=%s expiry=%s outcome=%s by=%s: %s', p_line_id, p_qty, p_expiry, p_outcome, COALESCE(v_user_id::text,'system'), p_reason),
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
     v_waste_by, v_value_aed, p_reason, p_line_id, v_wh_inventory_id)
  RETURNING event_id INTO v_event_id;
  UPDATE public.refill_dispatching SET wh_approved_at = now(), wh_approved_by = v_user_id WHERE dispatch_id = p_line_id;
  RETURN jsonb_build_object('status', 'confirmed', 'dispatch_id', p_line_id, 'event_id', v_event_id, 'wh_inventory_id', v_wh_inventory_id,
    'credited_mode', v_credited_mode, 'qty', p_qty, 'expiry', p_expiry, 'outcome', p_outcome,
    'target_machine_id', p_target_machine_id, 'waste_by', v_waste_by, 'value_aed', v_value_aed);
END $function$;
