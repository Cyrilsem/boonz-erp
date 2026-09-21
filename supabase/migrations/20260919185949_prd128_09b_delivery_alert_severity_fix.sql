-- PRD-128 step 09: one monitoring_alerts row per machine with not_landed lanes for the Dubai
-- day the job just closed out. Scheduled after the 23:59 Dubai WEIMI snapshot -- see the
-- cron.schedule call at the bottom (20:15 UTC = 00:15 Dubai the next day, so the just-finished
-- Dubai calendar day is `(now() at time zone 'Asia/Dubai')::date - 1` at run time).
--
-- Article 11 (cron via RPC): the job calls this DEFINER function, never raw INSERT from
-- cron.schedule.
--
-- at_risk_aed comes from refill_dispatching's own pod_product_id on the not_landed shelf's
-- picked-up add-type lines for that date, priced via the same DISTINCT ON dedup as step 05's
-- price_by_pod (never join through v_live_shelf_stock for this -- it carries no shelf_id).
--
-- monitoring_alerts.severity has a CHECK constraint allowing only info/warning/critical (not
-- high/medium as the PRD's own wording suggests) -- verified via pg_constraint before writing
-- this. Mapped to preserve the PRD's intent: 'critical' when a machine's not-landed lanes carry
-- more than 50 AED/day at risk, else 'warning'.

CREATE OR REPLACE FUNCTION public.run_delivery_verification_alerts()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_date date := ((now() AT TIME ZONE 'Asia/Dubai')::date - 1);
  v_count integer := 0;
BEGIN
  WITH not_landed AS (
    SELECT dv.machine_id, dv.shelf_id, dv.shelf_code, dv.units_sent, dv.weimi_move
    FROM public.v_delivery_verification dv
    WHERE dv.dispatch_date = v_date AND dv.verdict = 'not_landed'
  ),
  lane_price AS (
    SELECT DISTINCT ON (vcf.machine_id, vcf.pod_product_id)
      vcf.machine_id, vcf.pod_product_id, vcf.effective_price_aed
    FROM public.v_current_price_filled vcf
    ORDER BY vcf.machine_id, vcf.pod_product_id, vcf.effective_price_aed DESC NULLS LAST
  ),
  not_landed_value AS (
    SELECT nl.machine_id, nl.shelf_id,
      COALESCE(sum(COALESCE(lp.effective_price_aed, 0) * rd.quantity), 0) AS at_risk_aed
    FROM not_landed nl
    JOIN public.refill_dispatching rd
      ON rd.machine_id = nl.machine_id AND rd.shelf_id = nl.shelf_id
     AND rd.dispatch_date = v_date AND rd.picked_up = true AND NOT COALESCE(rd.cancelled, false)
     AND upper(rd.action) = ANY (ARRAY['ADD','REFILL','ADD NEW'])
    LEFT JOIN lane_price lp ON lp.machine_id = rd.machine_id AND lp.pod_product_id = rd.pod_product_id
    GROUP BY nl.machine_id, nl.shelf_id
  ),
  per_machine AS (
    SELECT nl.machine_id, m.official_name,
      sum(COALESCE(nlv.at_risk_aed, 0)) AS total_at_risk_aed,
      jsonb_agg(jsonb_build_object(
        'shelf_id', nl.shelf_id, 'shelf_code', nl.shelf_code,
        'units_sent', nl.units_sent, 'weimi_move', nl.weimi_move,
        'at_risk_aed', round(COALESCE(nlv.at_risk_aed, 0), 2)
      )) AS lanes
    FROM not_landed nl
    JOIN public.machines m ON m.machine_id = nl.machine_id
    LEFT JOIN not_landed_value nlv ON nlv.machine_id = nl.machine_id AND nlv.shelf_id = nl.shelf_id
    GROUP BY nl.machine_id, m.official_name
  )
  INSERT INTO public.monitoring_alerts (source, severity, payload)
  SELECT
    'delivery_verification',
    CASE WHEN pm.total_at_risk_aed > 50 THEN 'critical' ELSE 'warning' END,
    jsonb_build_object(
      'machine_id', pm.machine_id,
      'official_name', pm.official_name,
      'dispatch_date', v_date,
      'not_landed_lanes', pm.lanes,
      'total_at_risk_aed', round(pm.total_at_risk_aed, 2)
    )
  FROM per_machine pm;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.run_delivery_verification_alerts() FROM PUBLIC, anon, authenticated;

SELECT cron.schedule(
  'prd128_delivery_alert_0015_dubai',
  '15 20 * * *',
  $$SELECT public.run_delivery_verification_alerts();$$
);
