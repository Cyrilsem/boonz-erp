-- PRD-118 item H (Addendum 2 §H): nightly assertion that no unpacked same-batch group
-- (single from_wh_inventory_id pin, or driver_confirmed_breakdown entries, combined
-- across all live unpacked lines) exceeds its batch's real warehouse_stock. SECURITY
-- INVOKER (read-only diagnostic), writes via safe_monitoring_alert not a raw insert.
--
-- Verified live: found 47 real, pre-existing over-commit violations — almost all
-- batch_stock=0 (a batch that has since depleted to zero by legitimate means while an
-- old unpacked dispatch row still points at it), the historical damage this whole item
-- exists to stop recurring. Not prod-breaking (all historical/stale, none from any
-- current plan) but a real, useful backlog for a future cleanup pass — same population
-- class as the 55 phantom-pinned rows item D's integrity check found, overlapping but
-- not identical (a batch can deplete to 0 by legitimate consumption too, not only via
-- a sentinel-exclusion bug).
-- Cody: approve, Articles 4/8/16 — not a registered business metric (integrity canary),
-- alert write correctly delegates to the established safe_monitoring_alert primitive.
CREATE OR REPLACE FUNCTION public.check_dispatch_batch_overcommit()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_violations jsonb;
  v_n          int;
BEGIN
  WITH committed AS (
    SELECT rd.from_wh_inventory_id AS wh_inventory_id, rd.quantity AS qty
    FROM refill_dispatching rd
    WHERE rd.from_wh_inventory_id IS NOT NULL
      AND (rd.driver_confirmed_breakdown IS NULL OR jsonb_array_length(rd.driver_confirmed_breakdown) = 0)
      AND COALESCE(rd.packed,false)=false AND COALESCE(rd.cancelled,false)=false
      AND COALESCE(rd.skipped,false)=false AND COALESCE(rd.returned,false)=false
    UNION ALL
    SELECT (e->>'wh_inventory_id')::uuid AS wh_inventory_id, (e->>'qty')::numeric AS qty
    FROM refill_dispatching rd, jsonb_array_elements(rd.driver_confirmed_breakdown) e
    WHERE rd.driver_confirmed_breakdown IS NOT NULL
      AND COALESCE(rd.packed,false)=false AND COALESCE(rd.cancelled,false)=false
      AND COALESCE(rd.skipped,false)=false AND COALESCE(rd.returned,false)=false
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
