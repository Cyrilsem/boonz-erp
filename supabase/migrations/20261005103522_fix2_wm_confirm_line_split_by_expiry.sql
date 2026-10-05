-- ONE-SHOT FIX BATCH, FIX 2: Split by expiry on warehouse returns review.
-- Rollback: supabase/migrations/20261005103522_fix2_wm_confirm_line_split_by_expiry_rollback.sql
--
-- CS OVERRIDE 2026-10-05 14:34 Dubai: applied outside the 22:00-06:00 window. Reason: all of
-- today's refills are completed and no field activity is in progress. See CHANGELOG.md.
--
-- Classification: wm_confirm_line is SECURITY DEFINER, warehouse-confirmation function. Cody
-- review: Approve (Articles 1, 4, 6, 8, 12).
--
-- LIVE-APPLY CORRECTION: `CREATE OR REPLACE FUNCTION` with an added trailing parameter does
-- NOT replace a function in Postgres when the resulting argument list differs from every
-- existing overload -- it creates a SECOND, ambiguous overload alongside the original 9-arg
-- signature (caught live by check_ambiguous_function_overloads() immediately after applying).
-- This migration therefore explicitly DROPs the stale 9-arg signature first, so only the
-- single 10-arg function (p_batch_breakdown DEFAULT NULL) exists afterward -- every existing
-- 9-arg caller keeps working identically, now resolving to the one function instead of an
-- ambiguous pair.
--
-- Problem: a return line takes exactly one qty + one expiry. Real returns mix batches (e.g.
-- 2026-10-03 Sunbites Olive & Oregano from HUAWEI-2003-0000-B1 B15: 1 x 2027-01-16, 1 x
-- 2027-02-06), forcing the warehouse manager to either lose the split or force both units onto
-- one wrong expiry.
--
-- Fix: extend wm_confirm_line with an optional p_batch_breakdown jsonb array of
-- {qty, expiration_date}, appended as the last parameter (DEFAULT NULL) -- no new overload,
-- existing callers (wm_confirm_line_split, every current single-expiry caller) are unaffected.
-- When provided, it is ONLY valid on the general credit-to-stock branch -- explicitly rejected
-- for the two acknowledge-only sources (refill_return_ack, quarantine_batch), since those never
-- touch warehouse_inventory and a breakdown would have nothing meaningful to apply to (would
-- double-credit stock already moved by return_dispatch_line, per the Fork 2 safety finding this
-- session). Validates: a non-empty array, every row qty > 0, sum(breakdown qty) = p_qty exactly,
-- every row has a non-NULL expiration_date that isn't the 2099-12-31 sentinel (same rule as the
-- existing p_expiry check). Each row runs through the EXACT SAME merge-or-insert logic the
-- single-expiry path already uses (same Active-batch lookup by product+warehouse+expiry,
-- row-locked, same provenance_reason='dispatch_return'/'expiry_writeoff' via the existing
-- set_write_context call -- unchanged, called once before the branch so it covers every
-- per-row write in the loop), the same per-outcome handling (waste calls
-- warehouse_expire_writeoff per row's own wh_inventory_id; redeploy_pending sets
-- reserved_for_machine_id per row), and inserts ONE disposition_events row per sub-row, each
-- linked back to the original return line via the same dispatch_id/wh_inventory_id columns the
-- single-row path already uses. The original line-closing step (refill_dispatching
-- wh_approved_at/wh_approved_by for dispatch_return sources, or disposition_events
-- superseded_by_event for other sources) runs exactly once after the loop, same as before.

DROP FUNCTION IF EXISTS public.wm_confirm_line(uuid, numeric, date, text, uuid, text, text, uuid, boolean);

CREATE OR REPLACE FUNCTION public.wm_confirm_line(
  p_line_id uuid,
  p_qty numeric,
  p_expiry date,
  p_outcome text,
  p_target_machine_id uuid DEFAULT NULL::uuid,
  p_disposal_code text DEFAULT NULL::text,
  p_reason text DEFAULT NULL::text,
  p_caller uuid DEFAULT NULL::uuid,
  p_dry_run boolean DEFAULT true,
  p_batch_breakdown jsonb DEFAULT NULL::jsonb
)
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
  v_row jsonb; v_row_idx integer; v_row_qty numeric; v_row_expiry date;
  v_breakdown_sum numeric; v_last_event_id uuid; v_events jsonb := '[]'::jsonb;
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

  -- ONE-SHOT FIX BATCH, FIX 2: validate the optional batch breakdown up front, before touching
  -- v_wm_confirmations, so a bad breakdown never gets as far as a role/line lookup.
  IF p_batch_breakdown IS NOT NULL THEN
    IF jsonb_typeof(p_batch_breakdown) <> 'array' OR jsonb_array_length(p_batch_breakdown) = 0 THEN
      RAISE EXCEPTION 'wm_confirm_line: p_batch_breakdown must be a non-empty jsonb array';
    END IF;
    v_breakdown_sum := 0;
    FOR v_row_idx IN 0 .. jsonb_array_length(p_batch_breakdown) - 1 LOOP
      v_row := p_batch_breakdown -> v_row_idx;
      v_row_qty := (v_row ->> 'qty')::numeric;
      IF v_row_qty IS NULL OR v_row_qty <= 0 THEN
        RAISE EXCEPTION 'wm_confirm_line: p_batch_breakdown[%].qty must be > 0', v_row_idx;
      END IF;
      IF (v_row ->> 'expiration_date') IS NULL THEN
        RAISE EXCEPTION 'wm_confirm_line: p_batch_breakdown[%].expiration_date is required', v_row_idx;
      END IF;
      IF (v_row ->> 'expiration_date')::date = '2099-12-31'::date THEN
        RAISE EXCEPTION 'wm_confirm_line: p_batch_breakdown[%].expiration_date cannot be the 2099-12-31 sentinel', v_row_idx;
      END IF;
      v_breakdown_sum := v_breakdown_sum + v_row_qty;
    END LOOP;
    IF v_breakdown_sum <> p_qty THEN
      RAISE EXCEPTION 'wm_confirm_line: p_batch_breakdown rows sum to % but p_qty is %', v_breakdown_sum, p_qty;
    END IF;
  END IF;

  SELECT * INTO v_line FROM public.v_wm_confirmations WHERE line_id = p_line_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'wm_confirm_line: % is not an open Warehouse Confirmations line', p_line_id; END IF;

  -- PRD-137 F3: acknowledge-only sources. Never credit warehouse_inventory again -- the stock
  -- movement already happened (return_dispatch_line for refill_return_ack, or the row already
  -- exists for quarantine_batch). This confirmation step is the missing human review, nothing else.
  IF v_line.source IN ('refill_return_ack', 'quarantine_batch') THEN
    IF p_batch_breakdown IS NOT NULL THEN
      RAISE EXCEPTION 'wm_confirm_line: p_batch_breakdown is not supported for source % (acknowledge-only, no warehouse_inventory credit)', v_line.source;
    END IF;
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
      -- quarantine_batch: same transition release_wh_quarantine uses, including its exact
      -- set_config call shape (via_rpc/rpc_name/mutation_reason only, no app.provenance_reason).
      -- A generic warehouse_inventory trigger stamps provenance_reason FROM the
      -- app.provenance_reason GUC when it's set, which would silently override this branch's
      -- own 'manual_adjust' value back to whatever set_write_context's 3rd arg says -- confirmed
      -- in testing (using 'dispatch_return' there reverted this UPDATE's value on write).
      -- quarantined is a GENERATED column derived from provenance_reason (PRD-098); flipping
      -- provenance_reason releases it, no separate quarantined write.
      PERFORM set_config('app.via_rpc',  'true', true);
      PERFORM set_config('app.rpc_name', 'wm_confirm_line', true);
      PERFORM set_config('app.mutation_reason',
        format('wm_confirm_line line=%s source=quarantine_batch qty=%s outcome=acknowledged by=%s: %s',
          p_line_id, p_qty, COALESCE(v_user_id::text,'system'), p_reason), true);
      UPDATE public.warehouse_inventory SET provenance_reason = 'manual_adjust'
       WHERE wh_inventory_id = p_line_id;
    END IF;

    -- disposition_events.source and .state both have their own fixed-enum CHECK constraints
    -- that don't know about these two new v_wm_confirmations source names -- reuse
    -- source='return_receipt' and state='restocked' (the stock is already sitting in
    -- warehouse_inventory; acknowledging it is functionally the same terminal state as any
    -- other confirmed restock) and keep the real distinction in reason instead.
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
  v_state := p_outcome;

  IF p_dry_run THEN
    IF p_batch_breakdown IS NOT NULL THEN
      RETURN jsonb_build_object('status', 'dry_run_ok', 'line_id', p_line_id, 'source', v_line.source, 'machine_id', v_line.machine_id,
        'boonz_product_id', v_line.boonz_product_id, 'qty', p_qty, 'outcome', p_outcome,
        'target_warehouse_id', v_target_wh, 'target_machine_id', p_target_machine_id,
        'batch_breakdown', p_batch_breakdown);
    END IF;
    v_waste_by := CASE WHEN p_outcome = 'redeploy_pending' THEN p_expiry - 2 ELSE NULL END;
    RETURN jsonb_build_object('status', 'dry_run_ok', 'line_id', p_line_id, 'source', v_line.source, 'machine_id', v_line.machine_id,
      'boonz_product_id', v_line.boonz_product_id, 'qty', p_qty, 'expiry', p_expiry, 'outcome', p_outcome,
      'target_warehouse_id', v_target_wh, 'target_machine_id', p_target_machine_id, 'waste_by', v_waste_by, 'value_aed', v_value_aed * p_qty);
  END IF;

  PERFORM public.set_write_context('wm_confirm_line',
    format('wm_confirm_line line=%s source=%s qty=%s expiry=%s outcome=%s by=%s: %s',
      p_line_id, v_line.source, p_qty, p_expiry, p_outcome, COALESCE(v_user_id::text,'system'), p_reason),
    CASE WHEN p_outcome = 'waste' THEN 'expiry_writeoff' ELSE 'dispatch_return' END, p_line_id::text);

  IF p_batch_breakdown IS NOT NULL THEN
    -- ONE-SHOT FIX BATCH, FIX 2: one merge-or-insert + outcome + audit row per sub-row, each
    -- applying the identical logic the single-expiry path below uses for its one row.
    FOR v_row_idx IN 0 .. jsonb_array_length(p_batch_breakdown) - 1 LOOP
      v_row := p_batch_breakdown -> v_row_idx;
      v_row_qty := (v_row ->> 'qty')::numeric;
      v_row_expiry := (v_row ->> 'expiration_date')::date;

      SELECT * INTO v_existing FROM public.warehouse_inventory
       WHERE boonz_product_id = v_line.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active'
         AND expiration_date = v_row_expiry
       ORDER BY created_at ASC LIMIT 1 FOR UPDATE;

      IF FOUND THEN
        v_credited_mode := 'topped_up'; v_wh_inventory_id := v_existing.wh_inventory_id;
        UPDATE public.warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock,0) + v_row_qty,
          reserved_for_machine_id = CASE WHEN p_outcome = 'redeploy_pending' THEN p_target_machine_id ELSE reserved_for_machine_id END
         WHERE wh_inventory_id = v_wh_inventory_id;
      ELSE
        v_credited_mode := 'inserted';
        INSERT INTO public.warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id, reserved_for_machine_id)
        VALUES (v_line.boonz_product_id, v_row_qty, v_row_expiry, 'Active', format('WM-CONFIRM-%s-%s', p_line_id, v_row_idx), CURRENT_DATE, v_target_wh,
          CASE WHEN p_outcome = 'redeploy_pending' THEN p_target_machine_id ELSE NULL END)
        RETURNING wh_inventory_id INTO v_wh_inventory_id;
      END IF;

      IF p_outcome = 'waste' THEN PERFORM public.warehouse_expire_writeoff(v_wh_inventory_id, p_reason, v_user_id, p_disposal_code); END IF;

      v_waste_by := CASE WHEN p_outcome = 'redeploy_pending' THEN v_row_expiry - 2 ELSE NULL END;
      INSERT INTO public.disposition_events (actor, source, machine_id, shelf_id, boonz_product_id, expiration_date, qty, state,
         disposal_code, target_machine_id, waste_by, value_aed, reason, dispatch_id, wh_inventory_id)
      VALUES (v_user_id, 'return_receipt', v_line.machine_id, v_line.shelf_id, v_line.boonz_product_id, v_row_expiry, v_row_qty, v_state,
         CASE WHEN p_outcome = 'waste' THEN p_disposal_code ELSE NULL END,
         CASE WHEN p_outcome = 'redeploy_pending' THEN p_target_machine_id ELSE NULL END,
         v_waste_by, v_value_aed * v_row_qty, p_reason, v_line.dispatch_id, v_wh_inventory_id)
      RETURNING event_id INTO v_event_id;

      v_last_event_id := v_event_id;
      v_events := v_events || jsonb_build_object('wh_inventory_id', v_wh_inventory_id, 'credited_mode', v_credited_mode,
        'qty', v_row_qty, 'expiry', v_row_expiry, 'event_id', v_event_id);
    END LOOP;

    IF v_line.source = 'dispatch_return' THEN
      UPDATE public.refill_dispatching SET wh_approved_at = now(), wh_approved_by = v_user_id WHERE dispatch_id = p_line_id;
    ELSE
      UPDATE public.disposition_events SET superseded_by_event = v_last_event_id WHERE event_id = p_line_id;
    END IF;

    RETURN jsonb_build_object('status', 'confirmed', 'line_id', p_line_id, 'source', v_line.source,
      'qty', p_qty, 'outcome', p_outcome, 'target_machine_id', p_target_machine_id, 'batches', v_events);
  END IF;

  v_waste_by := CASE WHEN p_outcome = 'redeploy_pending' THEN p_expiry - 2 ELSE NULL END;
  v_value_aed := v_value_aed * p_qty;

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
