-- PRD-129R step 03: two new guards on check_machine_health_integrity, plus scheduling that
-- function as a nightly cron job instead of leaving it purely interactive.
--
-- G-REMAINDER: zero dispatch rows where credits logged against a dispatch_id (via
-- inventory_audit_log.source_event_id, set by both receive_dispatch_line and
-- credit_dispatch_remainder before their warehouse_inventory UPDATEs) sum to more than
-- quantity - filled_quantity. This is the regression guard for the double-credit bug
-- prd129r_01/02 fixed: if a future change reopens the double-credit path, or a new credit path
-- is added without checking remainder_credited, this catches it.
--
-- Two scope corrections found while dry-running this guard (799 raw hits, not the expected
-- ~208): (1) source_event_id is reused broadly as a general dispatch-traceability tag, not
-- exclusively for remainder credits -- pack-time debits and one-off manual CS corrections
-- ("reversing the RPC-recorded pack") were also turning up tagged with the same dispatch_id,
-- so the credited-sum is now filtered to the two reason prefixes the remainder-credit mechanism
-- actually writes ('B3 receive:' and 'A3 remainder credit'), not every audit row ever tagged
-- with that id. (2) 'Remove' actions and whole-line 'returned' dispatches credit warehouse_stock
-- with the full filled_quantity, not a remainder -- quantity minus filled_quantity is not a
-- meaningful comparison for them (this mirrors credit_dispatch_remainder's own exclusions), so
-- they are scoped out the same way. With both fixes this reproduces exactly 208 on the known
-- 2026-07-06-onward population before applying.
--
-- G-AUDIT-STALE: warehouse_audit_baseline rows with counted_units still NULL more than 48 hours
-- after audit_date. A recount that never gets entered leaves the baseline (and any downstream
-- phantom-stock reconciliation built on it) permanently incomplete with no visible signal.
--
-- check_machine_health_integrity() already takes about 3 minutes (G-LANE-SALES calls
-- get_machine_slots_with_expiry() once per Active machine, and G-NAME now also calls
-- get_machine_health(true) in full). It is NOT for interactive/synchronous use. This migration
-- schedules it as a nightly pg_cron job at 03:30 Dubai (23:30 UTC, matching this codebase's
-- existing UTC+4 offset convention for Dubai-scheduled jobs), writing its output to a new table
-- instead of returning it to a caller, so nothing in the app ever waits on this call directly.

CREATE TABLE IF NOT EXISTS public.machine_health_integrity_results (
  result_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_at       timestamptz NOT NULL DEFAULT now(),
  check_name   text NOT NULL,
  severity     text NOT NULL,
  machine_name text,
  detail       text
);

CREATE INDEX IF NOT EXISTS idx_machine_health_integrity_results_run_at
  ON public.machine_health_integrity_results (run_at DESC);
-- Serves "show me the latest run" and "show me runs from the last N days" -- the only two
-- access patterns this table needs.

ALTER TABLE public.machine_health_integrity_results ENABLE ROW LEVEL SECURITY;

CREATE POLICY machine_health_integrity_results_select ON public.machine_health_integrity_results
  FOR SELECT TO authenticated USING (true);

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.machine_health_integrity_results FROM authenticated;
REVOKE ALL ON public.machine_health_integrity_results FROM anon, PUBLIC;
GRANT SELECT ON public.machine_health_integrity_results TO authenticated;
-- Explicit revoke per S-308: authenticated is born with INSERT/UPDATE/DELETE on every new
-- table in public by default privilege. Only run_machine_health_integrity_check() (DEFINER)
-- writes this table.

CREATE OR REPLACE FUNCTION public.check_machine_health_integrity()
 RETURNS TABLE(check_name text, severity text, machine_name text, detail text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- NOTE: this function takes roughly 3 minutes end to end (G-LANE-SALES calls
  -- get_machine_slots_with_expiry() once per Active machine, G-NAME calls get_machine_health(true)
  -- in full). It is a batch/monitoring check, not something to call from an interactive request
  -- path. It runs nightly via run_machine_health_integrity_check(), scheduled at 03:30 Dubai.
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
  WHERE g.machine_name IS DISTINCT FROM m.official_name

  UNION ALL

  SELECT 'G-REMAINDER'::text, 'block'::text, m.official_name,
    format('dispatch %s: credited %s but remainder is %s (quantity=%s filled=%s)',
      rd.dispatch_id, cr.total_credited, GREATEST(COALESCE(rd.quantity,0) - COALESCE(rd.filled_quantity,0), 0),
      rd.quantity, rd.filled_quantity)
  FROM refill_dispatching rd
  JOIN machines m ON m.machine_id = rd.machine_id
  CROSS JOIN LATERAL (
    SELECT COALESCE(SUM(GREATEST(ial.new_qty - ial.old_qty, 0)), 0) AS total_credited
    FROM inventory_audit_log ial
    WHERE ial.source_event_id = rd.dispatch_id
      AND (ial.reason ILIKE 'B3 receive:%' OR ial.reason ILIKE 'A3 remainder credit%')
  ) cr
  WHERE rd.item_added = true
    AND rd.action IN ('Refill','Add New','Add')
    AND NOT COALESCE(rd.is_m2m, false)
    AND NOT COALESCE(rd.returned, false)
    AND cr.total_credited > GREATEST(COALESCE(rd.quantity,0) - COALESCE(rd.filled_quantity,0), 0)

  UNION ALL

  SELECT 'G-AUDIT-STALE'::text, 'warn'::text, NULL::text,
    format('warehouse_audit_baseline %s: boonz_product_id=%s audit_date=%s still has no counted_units after 48+ hours',
      wab.baseline_id, wab.boonz_product_id, wab.audit_date)
  FROM warehouse_audit_baseline wab
  WHERE wab.counted_units IS NULL
    AND wab.audit_date::timestamptz < now() - interval '48 hours';
$function$;

REVOKE ALL ON FUNCTION public.check_machine_health_integrity() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.check_machine_health_integrity() TO authenticated;

CREATE OR REPLACE FUNCTION public.run_machine_health_integrity_check()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_count integer := 0;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'run_machine_health_integrity_check', true);
  INSERT INTO public.machine_health_integrity_results (check_name, severity, machine_name, detail)
  SELECT check_name, severity, machine_name, detail FROM public.check_machine_health_integrity();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.run_machine_health_integrity_check() FROM PUBLIC, anon, authenticated;

SELECT cron.schedule(
  'prd129r_machine_health_integrity_0330_dubai',
  '30 23 * * *',
  $$SELECT public.run_machine_health_integrity_check();$$
);
