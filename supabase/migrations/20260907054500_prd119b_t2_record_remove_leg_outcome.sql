-- PRD-119b T2 (E2): driver "done" on a Remove leg wrote nothing to the lot
-- ledger and created no WM Confirmations line (20 legs, 0 outcomes, 04-07
-- Sep). New `record_remove_leg_outcome(p_dispatch_id, p_driver_outcome IN
-- ('done','partial','not_done'), p_driver_outcome_qty, p_caller, p_dry_run)`.
--
-- "One writer for both paths" per T2's exact instruction: this does NOT
-- duplicate apply_expiry_check's lot-decrement/disposition_events/WM-line
-- logic -- it COMPOSES the existing P3 tap writer directly, using the
-- dispatch row's `pod_lot_id` (new column from T1) to identify exactly
-- which pod lot to act on. done/partial map to apply_expiry_check's
-- 'removed' outcome (qty = full planned quantity or the driver's confirmed
-- partial qty); not_done maps to 'not_there' (archives with no disposition
-- row, matching the tap's own not_there semantics -- no goods moved).
--
-- `driver_outcome`'s existing CHECK constraint (used across every dispatch
-- action, not just Remove) only allows done/partial/not_done/
-- machine_offline/no_stock_on_truck -- T2's own "not_there" wording is
-- mapped to the existing `not_done` value rather than widening a
-- system-wide constraint for one action type.
--
-- Verified end-to-end in a rolled-back transaction against the real,
-- just-repaired VOXMCC-1005 A15 leg (pod_lot_id now populated by T1's
-- repair): lot current_stock 3->2, one disposition_events row
-- (state=removed_at_machine), dispatch row correctly marked
-- driver_outcome='done'. Not exercised on the live row for real in this
-- migration -- that would be a genuine inventory decrement beyond this
-- capability-build task's authorized scope.
--
-- Cody: approve, Articles 1 (one writer, composes the existing canonical
-- P3-tap writer rather than duplicating its logic), 4.
CREATE OR REPLACE FUNCTION public.record_remove_leg_outcome(
  p_dispatch_id uuid,
  p_driver_outcome text,
  p_driver_outcome_qty integer DEFAULT NULL,
  p_caller uuid DEFAULT NULL,
  p_dry_run boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := COALESCE(p_caller, auth.uid());
  v_role text;
  v_row refill_dispatching%ROWTYPE;
  v_outcome text;
  v_qty numeric;
  v_check_result jsonb;
BEGIN
  PERFORM set_config('app.via_rpc','true', true);
  PERFORM set_config('app.rpc_name','record_remove_leg_outcome', true);

  IF v_caller IS NOT NULL THEN
    SELECT role INTO v_role FROM user_profiles WHERE id = v_caller;
    IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'record_remove_leg_outcome: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;
  IF p_dispatch_id IS NULL THEN RAISE EXCEPTION 'record_remove_leg_outcome: p_dispatch_id required'; END IF;
  IF p_driver_outcome NOT IN ('done','partial','not_done') THEN
    RAISE EXCEPTION 'record_remove_leg_outcome: p_driver_outcome must be done | partial | not_done (got %)', p_driver_outcome;
  END IF;

  SELECT * INTO v_row FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'record_remove_leg_outcome: dispatch % not found', p_dispatch_id; END IF;
  IF v_row.action <> 'Remove' THEN RAISE EXCEPTION 'record_remove_leg_outcome: dispatch % is not a Remove leg (action=%)', p_dispatch_id, v_row.action; END IF;
  IF v_row.driver_outcome IS NOT NULL THEN RAISE EXCEPTION 'record_remove_leg_outcome: dispatch % already has driver_outcome=%', p_dispatch_id, v_row.driver_outcome; END IF;
  IF v_row.pod_lot_id IS NULL THEN
    RAISE EXCEPTION 'record_remove_leg_outcome: dispatch % has no pod_lot_id - repair via repair_remove_leg_shelf_lot first', p_dispatch_id;
  END IF;

  IF p_driver_outcome = 'not_done' THEN
    v_outcome := 'not_there';
    v_qty := NULL;
  ELSE
    v_outcome := 'removed';
    v_qty := CASE WHEN p_driver_outcome = 'partial' THEN COALESCE(p_driver_outcome_qty, v_row.quantity) ELSE v_row.quantity END;
    IF v_qty IS NULL OR v_qty <= 0 THEN RAISE EXCEPTION 'record_remove_leg_outcome: resolved qty must be > 0 (got %)', v_qty; END IF;
  END IF;

  IF p_dry_run THEN
    RETURN jsonb_build_object('status','dry_run_ok','dispatch_id',p_dispatch_id,
      'pod_lot_id', v_row.pod_lot_id, 'mapped_outcome', v_outcome, 'qty', v_qty);
  END IF;

  v_check_result := public.apply_expiry_check(v_row.pod_lot_id, v_outcome, v_qty, NULL, v_caller, false);

  UPDATE refill_dispatching
     SET driver_outcome = p_driver_outcome,
         driver_outcome_qty = p_driver_outcome_qty,
         driver_outcome_at = now(),
         driver_outcome_by = v_caller
   WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object('status','ok','dispatch_id',p_dispatch_id,
    'driver_outcome', p_driver_outcome, 'apply_expiry_check_result', v_check_result);
END;
$function$;
