-- PRD-141 item 23 (F3): pod_inventory vs WEIMI drift, reported nightly (report only).
-- v_pod_weimi_lane_drift: lanes of include_in_refill machines (WEIMI snapshot under 48 h) where WEIMI
--   current_stock and the Active pod_inventory sum on that shelf differ by more than 2 units.
-- check_pod_weimi_drift(): one monitoring_alerts row with the per-machine summary, nightly 23:50 UTC
--   (03:50 Dubai). Read-only apart from the alert.
-- The weekly auto-commit half of item 23 is NOT included: the session's permission classifier refused to
-- create an unattended job that rewrites live pod quantities. The design is in docs/prds/PRD-141-log.md.
-- Rollback: supabase/rollbacks/prd141_23_rollback.sql.

CREATE OR REPLACE VIEW public.v_pod_weimi_lane_drift AS
WITH lanes AS (
  SELECT ssi.machine_id, ssi.machine_name, ssi.shelf_id, ssi.shelf_code, ssi.pod_product_name,
         COALESCE(ssi.current_stock, 0) AS weimi_stock, ssi.snapshot_at
    FROM public.v_shelf_slot_identity ssi
    JOIN public.machines m ON m.machine_id = ssi.machine_id
   WHERE m.include_in_refill AND m.status = 'Active' AND ssi.shelf_id IS NOT NULL
     AND ssi.snapshot_at > now() - interval '48 hours'
), pod AS (
  SELECT pi.shelf_id, SUM(pi.current_stock) AS pod_stock
    FROM public.pod_inventory pi
   WHERE pi.status = 'Active'
   GROUP BY pi.shelf_id
)
SELECT l.machine_id, l.machine_name, l.shelf_id, l.shelf_code, l.pod_product_name,
       l.weimi_stock, COALESCE(p.pod_stock, 0) AS pod_stock,
       COALESCE(p.pod_stock, 0) - l.weimi_stock AS diff, l.snapshot_at
  FROM lanes l
  LEFT JOIN pod p ON p.shelf_id = l.shelf_id
 WHERE abs(COALESCE(p.pod_stock, 0) - l.weimi_stock) > 2;
REVOKE ALL ON public.v_pod_weimi_lane_drift FROM anon, public;
GRANT SELECT ON public.v_pod_weimi_lane_drift TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.check_pod_weimi_drift()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rows jsonb; v_lanes int; v_machines int;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object('machine', machine_name, 'lanes', n, 'abs_units', u) ORDER BY u DESC), '[]'::jsonb),
         COALESCE(SUM(n), 0), count(*)
    INTO v_rows, v_lanes, v_machines
    FROM (SELECT machine_name, count(*) AS n, SUM(abs(diff)) AS u FROM public.v_pod_weimi_lane_drift GROUP BY machine_name) x;
  IF v_lanes > 0 THEN
    PERFORM public.safe_monitoring_alert('pod_weimi_lane_drift', 'warning',
      jsonb_build_object('checked_at', now(), 'lanes', v_lanes, 'machines', v_machines, 'rows', v_rows,
        'title', format('%s lanes on %s machines: pod_inventory and WEIMI differ by more than 2 units', v_lanes, v_machines)));
  END IF;
  RETURN jsonb_build_object('status', CASE WHEN v_lanes = 0 THEN 'ok' ELSE 'drift' END, 'lanes', v_lanes, 'machines', v_machines, 'rows', v_rows);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.check_pod_weimi_drift() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.check_pod_weimi_drift() TO authenticated, service_role;

SELECT cron.schedule('prd141_pod_weimi_drift_0350_dubai', '50 23 * * *', 'SELECT public.check_pod_weimi_drift();');
