-- PRD-110 P0.5 - keep the golden 2030 fixture namespace out of the live procurement worklist.
-- Applied via Supabase MCP as `prd110_p05_view_excludes_fixture_namespace` 2026-07-30.
--
-- CAUGHT WHILE AUTHORING FIXTURE 105, BEFORE IT RAN. Fixture 105 writes real blocked_demand rows
-- on its synthetic plan_date 2030-04-16. v_blocked_demand_open as first written had no date bound,
-- so those rows would have surfaced in the procurement worklist as live demand - i.e. the proof
-- harness would have caused the exact class of bug it exists to prevent (phantom demand),
-- and CS would have been asked to buy stock for a machine visit five years out.
--
-- The bound is the harness's own documented convention (GOLDEN-FIXTURES.md: "Fixtures run on
-- synthetic plan_dates (year 2030) to never collide with live"), stated once here in the reader
-- rather than repeated in every consumer. blocked_demand itself keeps the rows - the fixture must
-- be able to assert on them, so the exclusion belongs in the reader, not the ledger.
--
-- Article 12: forward-only CREATE OR REPLACE; identical column list and order.

CREATE OR REPLACE VIEW public.v_blocked_demand_open
WITH (security_invoker = true) AS
SELECT bd.blocked_demand_id,
       bd.plan_date,
       bd.machine_id,
       m.official_name        AS machine_name,
       bd.shelf_id,
       sc.shelf_code,
       bd.pod_product_id,
       pp.pod_product_name,
       bd.boonz_product_id,
       bd.qty_blocked,
       bd.reason,
       bd.source,
       bd.created_at,
       (CURRENT_DATE - bd.plan_date)                     AS age_days,
       CASE WHEN (CURRENT_DATE - bd.plan_date) >= 14 THEN 'critical'
            WHEN (CURRENT_DATE - bd.plan_date) >=  7 THEN 'aging'
            WHEN (CURRENT_DATE - bd.plan_date) >=  3 THEN 'watch'
            ELSE 'fresh' END                             AS age_bucket,
       bd.reasoning
  FROM public.blocked_demand bd
  JOIN public.machines             m  ON m.machine_id      = bd.machine_id
  JOIN public.shelf_configurations sc ON sc.shelf_id        = bd.shelf_id
  JOIN public.pod_products         pp ON pp.pod_product_id  = bd.pod_product_id
 WHERE bd.resolved_at IS NULL
   AND bd.plan_date < DATE '2030-01-01';

COMMENT ON VIEW public.v_blocked_demand_open IS
  'PRD-110 P0.5 canonical reader for open blocked demand, with aging buckets (fresh <3d, watch '
  '3-6d, aging 7-13d, critical >=14d measured from plan_date). Excludes the year-2030 golden '
  'fixture namespace so harness runs can never appear as live procurement demand. The '
  'weekly-procurement consumer reads THIS, never blocked_demand directly.';
