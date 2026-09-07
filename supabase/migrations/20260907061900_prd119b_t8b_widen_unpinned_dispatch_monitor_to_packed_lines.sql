-- PRD-119b T8(b): driver_substitute_dispatch_line's NULL-pin (PRD-120 L2's
-- named defect, held for this goal's own fixture + verdict).
--
-- Fixture (rolled back, real dispatch row 6c633c3c-db61-41a1-a4e4-0e9d646cca14):
-- substituting to a product with zero Active warehouse_inventory stock sets
-- the LIVE row's from_wh_inventory_id to NULL (confirmed: before=
-- 70d83b96-3adb-448a-8489-dfe422438e53, after=NULL). This is real and still
-- reachable in production -- `driver_substitute_dispatch_line` is still
-- called live from src/app/(field)/field/trips/[machineId]/page.tsx
-- (PRD-120 only swapped the packing-screen ChangeProductDialog.tsx call
-- site to the newer supersede-based substitute_dispatch_line; the trips
-- page was not migrated).
--
-- BUT: the before/after pin IS captured in refill_dispatching_edit_log
-- (verified in the same fixture) and in day_close_events
-- (prior_from_wh_inventory_id/new_from_wh_inventory_id) -- PRD-120's L2
-- framing ("no record of what they used to be") is true of the LIVE row
-- only, not of the audit trail, which already exists. The real, previously
-- unverified gap: PRD-120's own nightly monitor,
-- check_unpinned_warehouse_dispatch_lines, filters `packed = false` --
-- but a driver substitution on a live trip typically happens on an
-- ALREADY-packed line, so every NULL pin this function produces is
-- structurally invisible to that monitor. Verified live: 34 unpinned
-- warehouse-sourced Refill/Add New lines exist right now (all synthetic
-- 2030-04-23 golden-fixture data, 0 real production impact), split exactly
-- 17 packed=false (caught, matches PRD-120's own "17 violations" report)
-- / 17 packed=true (silently missed until this fix).
--
-- Fix: drop the packed=false restriction so the assertion catches an
-- unpinned warehouse-sourced Refill/Add New line regardless of pack state
-- -- once packed, a warehouse-sourced line with no batch pin is unambiguously
-- a gap needing review, not a "give it time to get pinned" case. Output
-- shape unchanged (same jsonb structure, same alert source), purely a
-- WHERE-clause widening. Live count after widening: 34 (up from 17).
--
-- Not done here (out of scope for a fixture+verdict ask): migrating
-- trips/[machineId]/page.tsx's call site to substitute_dispatch_line to
-- retire driver_substitute_dispatch_line's mutate-in-place pattern entirely
-- -- that FE file was just edited minutes earlier in this same PRD-119b
-- loop (T6) and re-touching it here risked a collision; flagged for CS as
-- the real long-term fix, same Article 13 deprecation path PRD-120 already
-- named for this function.
--
-- Cody: approve, Article 16 (widens the one canonical detector rather than
-- adding a second), no schema change, read-only.
CREATE OR REPLACE FUNCTION public.check_unpinned_warehouse_dispatch_lines()
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_violations jsonb;
  v_n int;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'dispatch_id', rd.dispatch_id, 'machine_name', m.official_name,
           'shelf_code', sc.shelf_code, 'boonz_product_name', bp.boonz_product_name,
           'action', rd.action, 'dispatch_date', rd.dispatch_date, 'quantity', rd.quantity,
           'packed', rd.packed)), '[]'::jsonb),
         COUNT(*)
    INTO v_violations, v_n
  FROM refill_dispatching rd
  JOIN machines m ON m.machine_id = rd.machine_id
  LEFT JOIN shelf_configurations sc ON sc.shelf_id = rd.shelf_id
  LEFT JOIN boonz_products bp ON bp.product_id = rd.boonz_product_id
  WHERE rd.dispatch_date >= CURRENT_DATE
    AND rd.action IN ('Refill','Add New')
    AND rd.from_wh_inventory_id IS NULL
    AND rd.source_origin = 'warehouse'::source_origin_enum
    AND COALESCE(rd.cancelled,false) = false
    AND COALESCE(rd.skipped,false) = false;

  IF v_n > 0 THEN
    PERFORM public.safe_monitoring_alert('unpinned_warehouse_dispatch_line', 'critical',
      jsonb_build_object('checked_at', now(), 'violations', v_violations, 'count', v_n));
  END IF;

  RETURN jsonb_build_object('checked_at', now(), 'status', CASE WHEN v_n=0 THEN 'ok' ELSE 'violation' END,
                             'unpinned_count', v_n, 'violations', v_violations);
END;
$function$;
