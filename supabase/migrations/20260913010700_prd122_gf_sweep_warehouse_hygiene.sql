-- PRD-122 Phase 2, Guard G-F: sweep_warehouse_hygiene nightly cleanup.
--
-- Extends warehouse_inventory.disposal_reason's controlled vocabulary with
-- 'auto_retired_at_zero' (previously only Waste/Returning to supplier/Returned to
-- supplier) so the auto-retire path has its own distinct, traceable value.
--
-- sweep_warehouse_hygiene(p_dry_run boolean DEFAULT true) does three things:
--  1. Zero-stock Active warehouse_inventory rows -> Inactive, disposal_reason =
--     'auto_retired_at_zero'.
--  2. refill_dispatching rows dated more than 1 year in the future (the 76 rows
--     dated 2030): releases any live warehouse_inventory pin (from_wh_inventory_id
--     -> NULL) on every such row that is safe to touch, then cancels (cancelled=true)
--     every one not already cancelled/skipped. NEVER touches a row where
--     packed=true or picked_up=true (57 of the 76 are locked out this way and are
--     reported, not acted on). Follows the same governed-bulk-cleanup-RPC pattern as
--     the existing release_stale_unpacked_dispatches (direct UPDATE inside a
--     role-gated, dry-run-gated function -- not raw client DML, and not routed
--     through cancel_dispatch_line, whose dispatched=true precondition makes it
--     inapplicable here since none of these rows were ever dispatched).
--  3. Report-only: machines producing a weimi_aisle_snapshot today while
--     machines.status <> 'Active' (never writes machines).
--
-- Cody: Approve. Article 1 (dedicated cleanup RPC, no other writer performs this
-- specific bulk retirement), Article 4 (role-gated to warehouse/operator_admin/
-- superadmin/manager, sets app.via_rpc/rpc_name), Article 6 (writes
-- warehouse_inventory.status -- same role-gated-RPC precedent as G-E/
-- auto_expire_old_warehouse_stock), Article 12 (forward-only). Ships p_dry_run
-- DEFAULT true per the mission's blanket destructive-function rule; register on the
-- existing nightly cron once approved (not done in this migration).
--
-- Backtested in a rolled-back transaction: dry run reports 1 zero-stock row, 76 junk
-- dispatch rows total (57 locked by packed/picked_up, 2 already resolved, 17 to
-- cancel, 2 pins to release), and 4 machine/weimi status mismatches -- matches the
-- mission's stated baseline exactly. The two pinned rows turned out to be the same
-- two rows already marked skipped (caught and fixed: pin release is scoped to all
-- safe-to-touch junk rows regardless of cancelled/skipped state, not just the
-- to-cancel subset). Real run applied cleanly; a follow-up dry run shows zero
-- remaining work and the 57 locked rows still untouched -- confirms idempotency and
-- the packed/picked_up guarantee.

ALTER TABLE public.warehouse_inventory DROP CONSTRAINT warehouse_inventory_disposal_reason_check;

ALTER TABLE public.warehouse_inventory ADD CONSTRAINT warehouse_inventory_disposal_reason_check
  CHECK (disposal_reason IS NULL OR disposal_reason = ANY (ARRAY[
    'Waste'::text, 'Returning to supplier'::text, 'Returned to supplier'::text, 'auto_retired_at_zero'::text
  ]));

CREATE OR REPLACE FUNCTION public.sweep_warehouse_hygiene(p_dry_run boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_role text;
  v_uid uuid := auth.uid();
  v_zero_applied int := 0;
  v_junk_pins_released int := 0;
  v_junk_cancelled int := 0;
  v_mismatch jsonb;
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
  IF v_role IS NULL OR v_role NOT IN ('warehouse', 'operator_admin', 'superadmin', 'manager') THEN
    RAISE EXCEPTION 'sweep_warehouse_hygiene: role % not authorized', COALESCE(v_role, 'none');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('machine_name', m.official_name, 'status', m.status)), '[]'::jsonb)
  INTO v_mismatch
  FROM (SELECT DISTINCT s.machine_id FROM public.weimi_aisle_snapshots s WHERE s.snapshot_date = current_date) sm
  JOIN public.machines m ON m.machine_id = sm.machine_id
  WHERE m.status <> 'Active';

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'dry_run', true,
      'zero_stock_active_would_retire', (SELECT count(*) FROM public.warehouse_inventory WHERE status = 'Active' AND COALESCE(warehouse_stock, 0) = 0),
      'junk_dispatch_2030_total', (SELECT count(*) FROM public.refill_dispatching WHERE dispatch_date > current_date + interval '1 year'),
      'junk_dispatch_2030_locked_packed_or_picked_up', (SELECT count(*) FROM public.refill_dispatching WHERE dispatch_date > current_date + interval '1 year' AND (COALESCE(packed, false) OR COALESCE(picked_up, false))),
      'junk_dispatch_2030_already_resolved', (SELECT count(*) FROM public.refill_dispatching WHERE dispatch_date > current_date + interval '1 year' AND COALESCE(packed, false) = false AND COALESCE(picked_up, false) = false AND (COALESCE(cancelled, false) OR COALESCE(skipped, false))),
      'junk_dispatch_2030_would_cancel', (SELECT count(*) FROM public.refill_dispatching WHERE dispatch_date > current_date + interval '1 year' AND COALESCE(packed, false) = false AND COALESCE(picked_up, false) = false AND COALESCE(cancelled, false) = false AND COALESCE(skipped, false) = false),
      'junk_dispatch_2030_pins_would_release', (SELECT count(*) FROM public.refill_dispatching WHERE dispatch_date > current_date + interval '1 year' AND COALESCE(packed, false) = false AND COALESCE(picked_up, false) = false AND from_wh_inventory_id IS NOT NULL),
      'machine_weimi_status_mismatch', v_mismatch
    );
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'sweep_warehouse_hygiene', true);

  UPDATE public.warehouse_inventory
  SET status = 'Inactive', disposal_reason = 'auto_retired_at_zero'
  WHERE status = 'Active' AND COALESCE(warehouse_stock, 0) = 0;
  GET DIAGNOSTICS v_zero_applied = ROW_COUNT;

  UPDATE public.refill_dispatching
  SET from_wh_inventory_id = NULL
  WHERE dispatch_date > current_date + interval '1 year'
    AND COALESCE(packed, false) = false
    AND COALESCE(picked_up, false) = false
    AND from_wh_inventory_id IS NOT NULL;
  GET DIAGNOSTICS v_junk_pins_released = ROW_COUNT;

  UPDATE public.refill_dispatching
  SET cancelled = true,
      cancelled_at = now(),
      cancelled_by = v_uid,
      cancellation_reason = 'sweep_warehouse_hygiene: junk row dated >1yr in the future, never dispatched, retiring'
  WHERE dispatch_date > current_date + interval '1 year'
    AND COALESCE(packed, false) = false
    AND COALESCE(picked_up, false) = false
    AND COALESCE(cancelled, false) = false
    AND COALESCE(skipped, false) = false;
  GET DIAGNOSTICS v_junk_cancelled = ROW_COUNT;

  RETURN jsonb_build_object(
    'dry_run', false,
    'zero_stock_retired', v_zero_applied,
    'junk_dispatch_pins_released', v_junk_pins_released,
    'junk_dispatch_cancelled', v_junk_cancelled,
    'junk_dispatch_locked_packed_or_picked_up', (SELECT count(*) FROM public.refill_dispatching WHERE dispatch_date > current_date + interval '1 year' AND (COALESCE(packed, false) OR COALESCE(picked_up, false))),
    'machine_weimi_status_mismatch', v_mismatch
  );
END;
$function$;
