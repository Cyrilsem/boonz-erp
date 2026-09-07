-- PRD-119b T5 (E6): "nightly + on-visit: any Active lot whose boonz product
-- is not the lane's current WEIMI product ... becomes a CHECK row." The
-- on-visit surfacing is get_machine_orphan_expiry's new lane_mismatch class
-- (prd119b_t4_t5_lot_identity_and_lane_mismatch_orphans) read by the /refill
-- drawer. This migration adds the "nightly" half: assert_no_orphan_shelf_lots,
-- following the exact assert_sales_names_resolved pattern (PRD-120 L3a) --
-- alerts via safe_monitoring_alert(source='orphan_shelf_lots') when any
-- machine has a lane_mismatch lot, one row per machine+shelf+product.
--
-- Live count at ship time (fleet-wide, all machines' latest WEIMI snapshot):
-- 729 genuine stranded lots, 3168 units, none of which is a
-- lane-unresolved false positive (see the immediately prior migration's
-- fix). This is a materially larger backlog than the ~5 named E6 examples
-- in the goal brief -- flagged in the PRD-119b report as a fleet-wide
-- finding for CS, not something this migration remediates (T5's own scope
-- is detection/surfacing; T7's scope is reconciling THIS week's known
-- physical removals, not a fleet-wide historical sweep).
--
-- Cody: approve, Article 16 (one canonical detector, same shape as the
-- existing sales-name assertion), read-only, no writes.
CREATE OR REPLACE FUNCTION public.assert_no_orphan_shelf_lots()
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_violations jsonb;
  v_n int;
BEGIN
  WITH machines_checked AS (
    SELECT DISTINCT m.device_name
    FROM public.weimi_device_status m
    WHERE m.snapshot_date = (SELECT MAX(snapshot_date) FROM public.weimi_device_status)
  ),
  orphans AS (
    SELECT mc.device_name, o.*
    FROM machines_checked mc
    CROSS JOIN LATERAL public.get_machine_orphan_expiry(mc.device_name) o
    WHERE o.reason = 'lane_mismatch'
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'machine', device_name, 'shelf_code', shelf_code, 'boonz_product', boonz_product,
           'units', units, 'expired_units', expired_units, 'lane_current_product', lane_current_product)),
         '[]'::jsonb),
         COUNT(*)
    INTO v_violations, v_n
  FROM orphans;

  IF v_n > 0 THEN
    PERFORM public.safe_monitoring_alert('orphan_shelf_lots', 'warning',
      jsonb_build_object('checked_at', now(), 'violations', v_violations, 'count', v_n));
  END IF;

  RETURN jsonb_build_object('checked_at', now(), 'status', CASE WHEN v_n=0 THEN 'ok' ELSE 'violation' END,
                             'orphan_count', v_n, 'violations', v_violations);
END;
$function$;

SELECT cron.schedule(
  'assert_no_orphan_shelf_lots_nightly',
  '10 21 * * *',
  $$ SELECT public.assert_no_orphan_shelf_lots(); $$
);
