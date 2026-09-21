-- PRD-128 step 07: MUST deploy together with 06, or every guard row fails -- 06 changed what
-- priority_tier/priority_score read (p_tier_aed/p_score_aed instead of p_tier/p_score) and
-- changed urgency_breakdown's shape (aed-keyed, four AED contributors, not pts-keyed
-- unit-weighted chips), so the old guard's chip_expiry/chip_stale/chip_runout/chip_gap/
-- chip_holes checks would compare against a shape that no longer exists. Removed; replaced
-- with the three assertions the PRD asks for plus the mirrored *_structural ones (needed for
-- the same reason -- 06 added those two columns and they need a canonical check too).
--
-- assert_priority_runout_triggers_p1() was read in full (see DECISIONS-2026-09-19.md D-003)
-- and needs no change -- it tests the STRUCTURAL (units) tier model and p1_threshold, neither
-- of which PRD-128 touches.
--
-- Every numeric comparison in check_priority_surface_consistency() goes through round(x, 2)
-- on both sides before casting to text. g.priority_score returns through
-- get_machine_health()'s declared `numeric` (unconstrained) return type, which strips any
-- source typmod, so a zero comes back as '0'; mp.p_score_aed is read directly as
-- numeric(10,2), so the same zero casts as '0.00'. Comparing the raw ::text casts produces
-- false mismatches on every zero-score row. round(numeric, int) fixes the display scale on
-- the value itself, independent of typmod, so both sides format the same way.

CREATE OR REPLACE FUNCTION public.check_priority_surface_consistency()
 RETURNS TABLE(machine_name text, field text, health_value text, canonical_value text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT g.machine_name, d.field, d.hv, d.cv
  FROM get_machine_health() g
  JOIN machines m ON m.machine_id = g.machine_id AND m.status = 'Active'
  LEFT JOIN v_machine_priority mp ON mp.machine_id = g.machine_id
  LEFT JOIN v_machine_health_signals hs ON hs.machine_id = g.machine_id
  CROSS JOIN LATERAL (VALUES
    ('days_since_visit', g.days_since_visit::text, COALESCE(hs.days_since_visit, -1)::text),
    ('priority_score',   round(g.priority_score, 2)::text,   round(COALESCE(mp.p_score_aed, 0), 2)::text),
    ('priority_score_structural', round(g.priority_score_structural, 2)::text, round(COALESCE(mp.p_score, 0), 2)::text),
    ('priority_tier',    g.priority_tier,
       CASE WHEN NOT COALESCE(m.include_in_refill, true)
                 OR COALESCE(m.status, 'Active') IN ('Warehouse','Inactive') THEN 'excluded'
            WHEN mp.p_tier_aed = 'P1' THEN 'P1_RESTOCK'
            WHEN mp.p_tier_aed = 'P2' THEN 'P2_MAINTAIN'
            ELSE 'skip' END),
    ('priority_tier_structural', g.priority_tier_structural,
       CASE WHEN NOT COALESCE(m.include_in_refill, true)
                 OR COALESCE(m.status, 'Active') IN ('Warehouse','Inactive') THEN 'excluded'
            WHEN mp.p_tier = 'P3_OK' OR mp.p_tier IS NULL THEN 'skip'
            ELSE mp.p_tier END),
    ('service_track',    g.service_track,
       COALESCE(mp.svc_track, 'main')),
    ('urgency_breakdown_sum',
       round(COALESCE((SELECT sum((e->>'aed')::numeric) FROM jsonb_array_elements(g.urgency_breakdown) e), 0), 2)::text,
       round(COALESCE(mp.p_score_aed, 0), 2)::text)
  ) d(field, hv, cv)
  WHERE d.hv IS DISTINCT FROM d.cv;
$function$;

-- G-REV, G-FANOUT, G-TIER, G-CHIPS, G-LANES, G-COHORT -- empty result means pass. G-LANES is
-- the only non-blocking row: severity='warn', never 'block'.
--
-- get_machine_health() is a heavy per-row scan (a dozen-plus correlated subqueries per
-- machine). Computing it once via the `health` CTE and deriving the G-TIER/G-CHIPS comparison
-- from that same CTE (inlined, matching check_priority_surface_consistency()'s own logic for
-- those two fields) rather than calling that function -- calling it would mean
-- get_machine_health() runs three times per invocation (once here for G-LANES, twice more
-- nested inside two calls to the other checker), which timed out the connection on first
-- write.
CREATE OR REPLACE FUNCTION public.check_machine_health_integrity()
 RETURNS TABLE(check_name text, severity text, machine_name text, detail text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH health AS (
    SELECT * FROM get_machine_health()
  ),
  surface AS (
    SELECT g.machine_name, d.field, d.hv, d.cv
    FROM health g
    JOIN machines m ON m.machine_id = g.machine_id AND m.status = 'Active'
    LEFT JOIN v_machine_priority mp ON mp.machine_id = g.machine_id
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
  FROM v_machine_priority mp
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
  WHERE m.status = 'Active' AND machine_cohort(m.operating_model, m.service_model) = 'unclassified';
$function$;

REVOKE ALL ON FUNCTION public.check_priority_surface_consistency() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.check_priority_surface_consistency() TO authenticated;
REVOKE ALL ON FUNCTION public.check_machine_health_integrity() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.check_machine_health_integrity() TO authenticated;
