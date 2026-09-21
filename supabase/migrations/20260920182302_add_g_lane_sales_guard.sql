-- G-LANE-SALES: zero lanes where v_shelf_sales_identity has a real, resolved product with
-- actual sales in the exact 7-day window (units_7d > 0) while the lane's rendered
-- units_sold_7d is 0 -- the same class of bug fixed in
-- 20260920180000_fix_lane_sales_pod_product_id_key.sql (get_machine_slots_with_expiry
-- keying its sales lookup on a product-name match instead of pod_product_id).
--
-- Deliberately narrower than the literal "resolved is true and has_sales is true" wording:
-- has_sales=true only means "sold at some point in the last 30 days," and a product that
-- sold two weeks ago but nothing this week legitimately renders 0 in a 7-day column --
-- that is correct behaviour, not a bug. Checked live: the literal has_sales formulation
-- flags 120 rows fleetwide, essentially all of them this normal case. Requiring
-- vsi.units_7d > 0 specifically (there really were sales in the exact same window the page
-- renders) isolates the real defect -- 0 violations after the fix, confirmed live before
-- writing this guard.
--
-- pod_alias mirrors the same one-row alias map get_machine_slots_with_expiry's own fix
-- uses (v_live_shelf_stock.pod_product_id is unaliased, v_shelf_sales_identity's is not).

CREATE OR REPLACE FUNCTION public.check_machine_health_integrity()
 RETURNS TABLE(check_name text, severity text, machine_name text, detail text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH health AS MATERIALIZED (
    SELECT * FROM get_machine_health()
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
    AND g.units_sold_7d = 0;
$function$;

REVOKE ALL ON FUNCTION public.check_machine_health_integrity() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.check_machine_health_integrity() TO authenticated;
