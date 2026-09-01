-- PRD-118 item D fix #5: nightly integrity assertion, per Addendum D-3.
-- Invariant 1: no expiration_date=2099-12-31 row may exist at a non-consignment
-- warehouse (WH_CENTRAL today; non-staging warehouse_type). Verified clean live: 0.
-- Invariant 2: no LIVE/actionable refill_dispatching row (unpacked, not cancelled,
-- not skipped) may be pinned to a phantom/sentinel batch. Scoped to the actionable
-- population deliberately -- an unscoped count returns 560 historical rows, of which
-- 417 are already packed+picked_up (resolved, not actionable) and 73 were skipped
-- (an operator decision, not a silent failure). The actionable population is 55 rows
-- (dispatch dates 2026-08-08 through 2026-08-18, none from any live/current plan) --
-- pre-existing damage from before this session's fixes, left untouched here (no
-- re-pin door exists yet; that is PRD-118 item H's repin_dispatch_batch, not this
-- migration's job -- canonical-RPC-only discipline applies even to remediation).
-- SECURITY INVOKER (read-only diagnostic); writes via safe_monitoring_alert, not a
-- raw insert. Cody: approve, Articles 4/8/16 -- not a registered business metric
-- (an integrity canary, not a number an engine acts on), so Article 16 doesn't apply;
-- alert write correctly delegates to the established primitive.
CREATE OR REPLACE FUNCTION public.check_consignment_sentinel_integrity()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_2099_at_central   int;
  v_bound_sentinels   int;
  v_result            jsonb;
BEGIN
  SELECT COUNT(*) INTO v_2099_at_central
  FROM warehouse_inventory wi
  JOIN warehouses w ON w.warehouse_id = wi.warehouse_id
  WHERE wi.status = 'Active' AND wi.expiration_date = DATE '2099-12-31'
    AND w.warehouse_type <> 'staging';

  SELECT COUNT(*) INTO v_bound_sentinels
  FROM refill_dispatching rd
  JOIN warehouse_inventory wi ON wi.wh_inventory_id = rd.from_wh_inventory_id
  WHERE public._is_phantom_wh_row_v3(wi.batch_id, wi.expiration_date)
    AND COALESCE(rd.packed, false) = false
    AND COALESCE(rd.cancelled, false) = false
    AND COALESCE(rd.skipped, false) = false;

  v_result := jsonb_build_object(
    'checked_at', now(),
    'sentinel_at_non_consignment_warehouse', v_2099_at_central,
    'live_dispatch_rows_bound_to_phantom_batch', v_bound_sentinels,
    'status', CASE WHEN v_2099_at_central = 0 AND v_bound_sentinels = 0 THEN 'ok' ELSE 'violation' END
  );

  IF v_2099_at_central > 0 OR v_bound_sentinels > 0 THEN
    PERFORM public.safe_monitoring_alert('consignment_sentinel_integrity', 'critical', v_result);
  END IF;

  RETURN v_result;
END;
$function$;
