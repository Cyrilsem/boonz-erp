-- PRD-122 Phase 2, Guard G-F: sweep_warehouse_hygiene nightly cleanup.
--
-- sweep_warehouse_hygiene(p_dry_run boolean DEFAULT true) does:
--  1. refill_dispatching rows dated more than 1 year in the future (the 76 rows
--     dated 2030): releases any live warehouse_inventory pin (from_wh_inventory_id
--     -> NULL) on every such row that is safe to touch, then cancels (cancelled=true)
--     every one not already cancelled/skipped. NEVER touches a row where
--     packed=true or picked_up=true (57 of the 76 are locked out this way and are
--     reported, not acted on). Follows the same governed-bulk-cleanup-RPC pattern as
--     the existing release_stale_unpacked_dispatches (direct UPDATE inside a
--     role-gated, dry-run-gated function -- not raw client DML, and not routed
--     through cancel_dispatch_line, whose dispatched=true precondition makes it
--     inapplicable here since none of these rows were ever dispatched).
--  2. Report-only: machines producing a weimi_aisle_snapshot today while
--     machines.status <> 'Active' (never writes machines).
--
-- NOTE: the mission brief's third item -- "zero-stock Active rows -> Inactive,
-- disposal_reason='auto_retired_at_zero'" -- is deliberately NOT implemented here.
-- public.sweep_inactivate_stale_zero_stock (cron job 41, nightly 02:10 Dubai) is
-- already the canonical writer for this exact transition, and it is more correct
-- than the brief's version: it also requires consumer_stock=0 before retiring a row,
-- which the brief's phrasing omitted. The one Active/warehouse_stock=0 row found in
-- WH_CENTRAL on 13 Sep (bb44c157-eaed-4a81-816b-fc0f4449fee7) still carries
-- consumer_stock=3 (committed to a driver), so it is correctly NOT stale -- the
-- existing sweep is working as intended, not missing anything. Duplicating this
-- logic here would have violated Article 1 (one canonical write path) and Article
-- 16 (one canonical object per metric), and an earlier draft of this migration did
-- exactly that (plus reproduced the missing consumer_stock check) before being
-- caught and removed prior to commit.
--
-- Cody: Approve. Article 1 (dedicated cleanup RPC for the dispatch-pin/cancel action;
-- zero-stock retirement deliberately deferred to its existing canonical writer),
-- Article 4 (role-gated to warehouse/operator_admin/superadmin/manager, sets
-- app.via_rpc/rpc_name), Article 12 (forward-only), Article 16 (no metric
-- re-derived -- see note above). Ships p_dry_run DEFAULT true per the mission's
-- blanket destructive-function rule; register on the existing nightly cron once
-- approved (not done in this migration).
--
-- Backtested in a rolled-back transaction: dry run reports 76 junk dispatch rows
-- total (57 locked by packed/picked_up, 2 already resolved, 17 to cancel, 2 pins to
-- release) and 4 machine/weimi status mismatches -- matches the mission's stated
-- baseline exactly. The two pinned rows turned out to be the same two rows already
-- marked skipped (caught and fixed: pin release is scoped to all safe-to-touch junk
-- rows regardless of cancelled/skipped state, not just the to-cancel subset). Real
-- run (in a separate rolled-back transaction) applied cleanly; a follow-up dry run
-- showed zero remaining work and the 57 locked rows still untouched -- confirms
-- idempotency and the packed/picked_up guarantee. Not executed for real against
-- production in this session -- actual cleanup execution is deferred to CS,
-- consistent with Phase 3's "do not delete/zero any Active row yet" posture.

CREATE OR REPLACE FUNCTION public.sweep_warehouse_hygiene(p_dry_run boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_role text;
  v_uid uuid := auth.uid();
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
      'note', 'zero-stock Active retirement is NOT handled here -- that is the existing canonical sweep_inactivate_stale_zero_stock (cron job 41), which correctly also requires consumer_stock=0',
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
    'junk_dispatch_pins_released', v_junk_pins_released,
    'junk_dispatch_cancelled', v_junk_cancelled,
    'junk_dispatch_locked_packed_or_picked_up', (SELECT count(*) FROM public.refill_dispatching WHERE dispatch_date > current_date + interval '1 year' AND (COALESCE(packed, false) OR COALESCE(picked_up, false))),
    'machine_weimi_status_mismatch', v_mismatch
  );
END;
$function$;
