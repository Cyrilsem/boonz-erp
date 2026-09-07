-- Close-out follow-up 1a/1b: classify the 54 overcommit / 55 sentinel-bound
-- nightly-assertion violations into HISTORICAL vs LIVE before touching
-- anything. Both turned out to be 100% historical -- 0 live violations in
-- either case, confirmed by direct classification query before writing this
-- fix, not assumed.
--
-- 1a) check_dispatch_batch_overcommit: already scoped to packed=false, but
-- NOT to dispatched=false or dispatch_date. Verified live: all 101
-- contributing rows across the 54 overcommitted batches are dispatch_date <
-- today AND dispatched=false -- old, abandoned plan rows that were never
-- packed, dispatched, cancelled, skipped, or returned, still claiming a
-- warehouse-stock reservation for a day that has long passed. Added
-- dispatched=false (belt) and dispatch_date >= today (the actual fix --
-- dispatched=false alone does NOT exclude these rows, since they ARE
-- dispatched=false; overcommit only means something for stock that hasn't
-- moved yet AND is still relevant to a future/current delivery day).
-- Verified after fix: 54 -> 0.
--
-- 1b) check_consignment_sentinel_integrity: same historical/live split for
-- its `live_dispatch_rows_bound_to_phantom_batch` sub-check (55, all
-- historical, dispatch_date < today, dispatched=false). Two fixes, both
-- predicate-level, per the goal's own instruction ("fix the predicate, not
-- the rows, when the rows are correct"):
--   - Added dispatched=false + dispatch_date >= today, same reasoning as 1a.
--   - Added a permanent, date-independent exemption for
--     source_origin='vox_at_venue': confirmed via pack_dispatch_line's own
--     "v2 VOX GUARD" (venue-supplied lines may ONLY draw from the 2099
--     placeholder row, by design -- real batches are protected from them).
--     A vox_at_venue line bound to the sentinel batch is never a data
--     defect, historical or live -- the same structural-not-defect reasoning
--     PRD-118 K1's 65681b5 already applied to the NULL-expiry guard for the
--     identical source_origin. 43 of the 55 (16+17+10, split
--     WH_CENTRAL/WH_MCC/WH_MM) were exactly this exempt class; the remaining
--     12 (source_origin='warehouse' at WH_CENTRAL) are the genuine defect
--     class this assertion exists to catch, but happen to be historical
--     right now -- left as historical record, not force-repinned, per
--     instruction. `sentinel_at_non_consignment_warehouse` sub-check
--     untouched (already 0, not date-scoped by nature -- it's a point-in-time
--     Active-row check, not a dispatch-flow check).
-- Verified after fix: 55 -> 0.
--
-- No rows repinned in this migration -- both counts reached 0 by predicate
-- correction alone; nothing live remained to fix with
-- set_dispatch_line_breakdown or repin_dispatch_batch.
--
-- Cody: approve, Article 16 (both remain the one canonical detector for
-- their respective conditions, scope corrected not duplicated), no schema
-- change, read-only functions.
CREATE OR REPLACE FUNCTION public.check_dispatch_batch_overcommit()
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_violations jsonb;
  v_n          int;
  v_today      date := (now() AT TIME ZONE 'Asia/Dubai')::date;
BEGIN
  WITH committed AS (
    SELECT rd.from_wh_inventory_id AS wh_inventory_id, rd.quantity AS qty
    FROM refill_dispatching rd
    WHERE rd.from_wh_inventory_id IS NOT NULL
      AND (rd.driver_confirmed_breakdown IS NULL OR jsonb_array_length(rd.driver_confirmed_breakdown) = 0)
      AND COALESCE(rd.packed,false)=false AND COALESCE(rd.dispatched,false)=false
      AND COALESCE(rd.cancelled,false)=false
      AND COALESCE(rd.skipped,false)=false AND COALESCE(rd.returned,false)=false
      AND rd.dispatch_date >= v_today
    UNION ALL
    SELECT (e->>'wh_inventory_id')::uuid AS wh_inventory_id, (e->>'qty')::numeric AS qty
    FROM refill_dispatching rd, jsonb_array_elements(rd.driver_confirmed_breakdown) e
    WHERE rd.driver_confirmed_breakdown IS NOT NULL
      AND COALESCE(rd.packed,false)=false AND COALESCE(rd.dispatched,false)=false
      AND COALESCE(rd.cancelled,false)=false
      AND COALESCE(rd.skipped,false)=false AND COALESCE(rd.returned,false)=false
      AND rd.dispatch_date >= v_today
  ),
  totals AS (
    SELECT c.wh_inventory_id, SUM(c.qty) AS total_committed
    FROM committed c
    GROUP BY c.wh_inventory_id
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'wh_inventory_id', t.wh_inventory_id,
           'batch_stock', wi.warehouse_stock,
           'total_committed', t.total_committed,
           'over_by', t.total_committed - wi.warehouse_stock
         )), '[]'::jsonb),
         COUNT(*)
    INTO v_violations, v_n
  FROM totals t
  JOIN warehouse_inventory wi ON wi.wh_inventory_id = t.wh_inventory_id
  WHERE t.total_committed > wi.warehouse_stock;

  IF v_n > 0 THEN
    PERFORM public.safe_monitoring_alert('dispatch_batch_overcommit', 'critical',
      jsonb_build_object('checked_at', now(), 'violations', v_violations, 'count', v_n));
  END IF;

  RETURN jsonb_build_object('checked_at', now(), 'status', CASE WHEN v_n=0 THEN 'ok' ELSE 'violation' END,
                             'overcommitted_batches', v_n, 'violations', v_violations);
END;
$function$;

CREATE OR REPLACE FUNCTION public.check_consignment_sentinel_integrity()
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_2099_at_central   int;
  v_bound_sentinels   int;
  v_today             date := (now() AT TIME ZONE 'Asia/Dubai')::date;
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
    AND COALESCE(rd.source_origin::text,'') <> 'vox_at_venue'
    AND COALESCE(rd.packed, false) = false
    AND COALESCE(rd.dispatched, false) = false
    AND COALESCE(rd.cancelled, false) = false
    AND COALESCE(rd.skipped, false) = false
    AND rd.dispatch_date >= v_today;

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
