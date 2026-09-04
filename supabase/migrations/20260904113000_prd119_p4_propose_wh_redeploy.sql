-- PRD-119 P4: the admin Expiry & Waste screen needs a way to open a redeploy
-- proposal directly off an aging warehouse_inventory batch -- distinct from
-- wm_confirm_line's redeploy_pending path, which only fires from a return/
-- tap queue line, not from a WM proactively triaging batches by
-- days-to-expiry. Composes with the already-shipped confirm_disposition_redeploy
-- closer (same redeploy_pending -> redeployed chain).
--
-- Reserves the row via warehouse_inventory.reserved_for_machine_id, the same
-- column wm_confirm_line already uses for its redeploy_pending path -- the
-- established mechanism the dispatch/pick pipeline reads to route a
-- specific batch to a specific machine. This RPC does not itself move stock.
--
-- Caught in testing: the first fixture row picked up the 2099-12-31
-- consignment sentinel and the function silently computed a nonsense
-- waste_by (2099-12-29) from it -- added an explicit guard refusing to
-- redeploy a sentinel-dated row, re-verified against a real dated batch
-- (2028-02-22) after the fix.
--
-- Cody: approve, Articles 1, 4, 6 (no warehouse_inventory.status write), 7.
CREATE OR REPLACE FUNCTION public.propose_wh_redeploy(
  p_wh_inventory_id uuid,
  p_target_machine_id uuid,
  p_qty numeric,
  p_reason text,
  p_caller uuid DEFAULT NULL,
  p_dry_run boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller, auth.uid());
  v_wh public.warehouse_inventory%ROWTYPE;
  v_value numeric;
  v_waste_by date;
  v_event_id uuid;
BEGIN
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles WHERE id = v_user_id
      AND role = ANY(ARRAY['warehouse','operator_admin','superadmin','manager'])
  ) THEN RAISE EXCEPTION 'forbidden: propose_wh_redeploy requires warehouse, operator_admin, superadmin, or manager'; END IF;

  IF p_wh_inventory_id IS NULL THEN RAISE EXCEPTION 'propose_wh_redeploy: p_wh_inventory_id is required'; END IF;
  IF p_target_machine_id IS NULL THEN RAISE EXCEPTION 'propose_wh_redeploy: p_target_machine_id is required'; END IF;
  IF p_qty IS NULL OR p_qty <= 0 THEN RAISE EXCEPTION 'propose_wh_redeploy: p_qty must be > 0'; END IF;
  IF length(COALESCE(p_reason,'')) < 10 THEN RAISE EXCEPTION 'propose_wh_redeploy: p_reason must be at least 10 characters'; END IF;

  SELECT * INTO v_wh FROM public.warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id AND status = 'Active' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'propose_wh_redeploy: % is not an Active warehouse_inventory row', p_wh_inventory_id; END IF;
  IF v_wh.expiration_date IS NULL THEN RAISE EXCEPTION 'propose_wh_redeploy: cannot redeploy an undated (DATE?) batch — read the date first'; END IF;
  IF v_wh.expiration_date = '2099-12-31'::date THEN
    RAISE EXCEPTION 'propose_wh_redeploy: % carries the 2099-12-31 consignment sentinel, not a real expiry — verify the actual batch date before redeploying', p_wh_inventory_id; END IF;
  IF p_qty > COALESCE(v_wh.warehouse_stock, 0) THEN
    RAISE EXCEPTION 'propose_wh_redeploy: p_qty % exceeds warehouse_stock % on this row', p_qty, v_wh.warehouse_stock; END IF;

  v_waste_by := v_wh.expiration_date - 2;
  SELECT avg_cost * p_qty INTO v_value FROM public.boonz_products WHERE product_id = v_wh.boonz_product_id;

  IF p_dry_run THEN
    RETURN jsonb_build_object('status','dry_run_ok','wh_inventory_id',p_wh_inventory_id,'target_machine_id',p_target_machine_id,
      'boonz_product_id', v_wh.boonz_product_id, 'qty', p_qty, 'expiration_date', v_wh.expiration_date,
      'waste_by', v_waste_by, 'value_aed', v_value);
  END IF;

  PERFORM public.set_write_context('propose_wh_redeploy',
    format('propose_wh_redeploy wh_inv=%s target_machine=%s qty=%s by=%s: %s',
      p_wh_inventory_id, p_target_machine_id, p_qty, COALESCE(v_user_id::text,'system'), p_reason),
    'dispatch_return', p_wh_inventory_id::text);

  UPDATE public.warehouse_inventory SET reserved_for_machine_id = p_target_machine_id WHERE wh_inventory_id = p_wh_inventory_id;

  INSERT INTO public.disposition_events (actor, source, boonz_product_id, expiration_date, qty, state,
     target_machine_id, waste_by, value_aed, reason, wh_inventory_id)
  VALUES (v_user_id, 'wh_writeoff', v_wh.boonz_product_id, v_wh.expiration_date, p_qty, 'redeploy_pending',
     p_target_machine_id, v_waste_by, v_value, p_reason, p_wh_inventory_id)
  RETURNING event_id INTO v_event_id;

  RETURN jsonb_build_object('status','proposed','event_id',v_event_id,'target_machine_id',p_target_machine_id,'qty',p_qty,'waste_by',v_waste_by);
END $function$;
