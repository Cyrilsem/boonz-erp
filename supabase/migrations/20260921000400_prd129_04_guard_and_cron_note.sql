-- PRD-129 step 04: add G-NAME to check_machine_health_integrity(), checking machine_name against
-- the joined machines.official_name in BOTH scopes (default and p_include_inactive=true) -- a
-- regression guard for the D-011/01_name_identity fix (get_machine_health's machine_name is now
-- unconditionally machines.official_name; this makes sure a future change can't quietly
-- reintroduce the WEIMI-device-name masking bug D-011 fixed).
--
-- check_machine_health_integrity() already takes ~3 minutes, almost entirely because
-- G-LANE-SALES calls get_machine_slots_with_expiry() once per Active machine. Per the PRD-129
-- instruction, that is NOT being optimized further here -- it belongs on a nightly cron, and
-- this function is documented (see the comment above check_machine_health_integrity's
-- CREATE OR REPLACE) as not intended for interactive/synchronous use. G-NAME adds one more full
-- get_machine_health(true) call (~2.8s) on top of that; negligible next to the existing 3-minute
-- cost, not worth a separate optimization pass.

CREATE OR REPLACE FUNCTION public.check_machine_health_integrity()
 RETURNS TABLE(check_name text, severity text, machine_name text, detail text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- NOTE: this function takes roughly 3 minutes end to end (G-LANE-SALES calls
  -- get_machine_slots_with_expiry() once per Active machine). It is a batch/monitoring check,
  -- not something to call from an interactive request path. Run it from a scheduled job, not a
  -- page load.
  WITH health AS MATERIALIZED (
    SELECT * FROM get_machine_health()
  ),
  health_all AS MATERIALIZED (
    SELECT * FROM get_machine_health(true)
  ),
  mp_full AS MATERIALIZED (
    SELECT * FROM v_machine_priority
  ),
  surface AS (
    SELECT g.machine_name, d.field, d.hv, d.cv
    FROM health g
    JOIN machines m ON m.machine_id = g.machine_id AND m.status = 'Active'
    LEFT JOIN mp_full mp ON mp.machine_id = g.machine_id
    CROSS JOIN LATERAL (VALUES
      ('priority_tier', g.priority_tier,
         CASE WHEN NOT COALESCE(m.include_in_refill, true)
                   OR COALESCE(m.status, 'Active') IN ('Warehouse','Inactive') THEN 'excluded'
              WHEN mp.p_tier_aed = 'P1' THEN 'P1_RESTOCK'
              WHEN mp.p_tier_aed = 'P2' THEN 'P2_MAINTAIN'
              ELSE 'skip' END),
      ('urgency_breakdown_sum',
         round(COALESCE((SELECT sum((e->>'aed')::numeric) FROM jsonb_array_elements(g.urgency_breakdown) e), 0), 2)::text,
         round(COALESCE(mp.p_score_aed, 0), 2)::text)
    ) d(field, hv, cv)
  )
  SELECT 'G-REV'::text, 'block'::text, mp.official_name,
    format('daily_revenue_aed=%s vs sales_history_30d_avg=%s (%s pct off)',
      round(mp.daily_revenue_aed,2), round(sh.avg_30d,2),
      round(100 * abs(mp.daily_revenue_aed - sh.avg_30d) / NULLIF(sh.avg_30d,0), 1))
  FROM mp_full mp
  JOIN machines m ON m.machine_id = mp.machine_id AND m.status = 'Active'
  CROSS JOIN LATERAL (
    SELECT COALESCE(SUM(s.paid_amount), 0) / 30.0 AS avg_30d
    FROM sales_history s
    WHERE s.machine_id = mp.machine_id AND s.delivery_status IN ('Success','Successful')
      AND s.transaction_date >= now() - interval '30 days'
  ) sh
  WHERE machine_cohort(m.operating_model, m.service_model) IN ('boonz','vox')
    AND sh.avg_30d > 20
    AND abs(mp.daily_revenue_aed - sh.avg_30d) / NULLIF(sh.avg_30d, 0) > 0.20

  UNION ALL

  SELECT 'G-FANOUT'::text, 'block'::text, NULL::text,
    format('v_lane_grain has %s rows, the price-deduped join has %s', lg.n, lp.n)
  FROM (SELECT count(*) AS n FROM v_lane_grain) lg
  CROSS JOIN (
    SELECT count(*) AS n
    FROM v_lane_grain lg2
    LEFT JOIN (
      SELECT DISTINCT ON (vcf.machine_id, vcf.pod_product_id) vcf.machine_id, vcf.pod_product_id, vcf.effective_price_aed
      FROM v_current_price_filled vcf
      ORDER BY vcf.machine_id, vcf.pod_product_id, vcf.effective_price_aed DESC NULLS LAST
    ) pbp ON pbp.machine_id = lg2.machine_id AND pbp.pod_product_id = lg2.pod_product_id
  ) lp
  WHERE lg.n <> lp.n

  UNION ALL

  SELECT 'G-TIER'::text, 'block'::text, s.machine_name,
    format('health=%s canonical=%s', s.hv, s.cv)
  FROM surface s
  WHERE s.field = 'priority_tier' AND s.hv IS DISTINCT FROM s.cv

  UNION ALL

  SELECT 'G-CHIPS'::text, 'block'::text, s.machine_name,
    format('urgency_breakdown_sum=%s priority_score=%s', s.hv, s.cv)
  FROM surface s
  WHERE s.field = 'urgency_breakdown_sum'
    AND abs(NULLIF(s.hv,'')::numeric - NULLIF(s.cv,'')::numeric) > 0.01

  UNION ALL

  SELECT 'G-LANES'::text, 'warn'::text, g.machine_name,
    format('%s unresolved lane(s)', g.unresolved_lane_count)
  FROM health g
  WHERE g.unresolved_lane_count > 0

  UNION ALL

  SELECT 'G-COHORT'::text, 'block'::text, m.official_name,
    'operating_model/service_model do not resolve to a cohort'::text
  FROM machines m
  WHERE m.status = 'Active' AND machine_cohort(m.operating_model, m.service_model) = 'unclassified'

  UNION ALL

  SELECT 'G-LANE-SALES'::text, 'block'::text, m.official_name,
    format('slot %s (%s): rendered units_sold_7d=0 but v_shelf_sales_identity.units_7d=%s',
      g.slot, g.product, vsi.units_7d)
  FROM machines m
  CROSS JOIN LATERAL public.get_machine_slots_with_expiry(m.official_name) g
  JOIN public.v_shelf_sales_identity vsi
    ON vsi.machine_id = m.machine_id
   AND vsi.pod_product_id = COALESCE(
         (SELECT pa.column2
          FROM (VALUES ('168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid, '51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid)) pa(column1, column2)
          WHERE pa.column1 = g.pod_product_id),
         g.pod_product_id)
  WHERE m.status = 'Active'
    AND vsi.resolved = true
    AND vsi.units_7d > 0
    AND g.units_sold_7d = 0

  UNION ALL

  SELECT 'G-NAME'::text, 'block'::text, m.official_name,
    format('get_machine_health() [default] machine_name=%s vs machines.official_name=%s', g.machine_name, m.official_name)
  FROM health g
  JOIN machines m ON m.machine_id = g.machine_id
  WHERE g.machine_name IS DISTINCT FROM m.official_name

  UNION ALL

  SELECT 'G-NAME'::text, 'block'::text, m.official_name,
    format('get_machine_health(true) [include_inactive] machine_name=%s vs machines.official_name=%s', g.machine_name, m.official_name)
  FROM health_all g
  JOIN machines m ON m.machine_id = g.machine_id
  WHERE g.machine_name IS DISTINCT FROM m.official_name;
$function$;

REVOKE ALL ON FUNCTION public.check_machine_health_integrity() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.check_machine_health_integrity() TO authenticated;
