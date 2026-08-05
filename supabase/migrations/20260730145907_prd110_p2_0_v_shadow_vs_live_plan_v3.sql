-- PRD-110 P2.0 · canonical diff object: v3 shadow plan vs v19 live plan.
-- ADR §2: "The nightly diff (v3 shadow vs v19 live) is a VIEW over this table joined to
-- pod_refill_plan, not a second materialization." This is that view.
-- Article 16: this is the ONE canonical object for the shadow-vs-live comparison. No consumer
-- re-derives it. Registered in METRICS_REGISTRY.md.
--
-- Scope rule that matters: the live side is restricted to plan_dates on which a shadow run
-- actually exists. Without it, a FULL OUTER JOIN reports every historical v19 plan row as
-- "v3_only missing" and the diff reads as catastrophic divergence when v3 simply never ran.

CREATE OR REPLACE VIEW public.v_shadow_vs_live_plan_v3
WITH (security_invoker = true) AS
WITH latest AS (
  -- the most recent shadow run per plan_date; ADR §5(3) forbids an unqualified read
  SELECT DISTINCT ON (plan_date) plan_date, run_id, engine_tag, produced_at
  FROM public.pod_refill_plan_shadow
  ORDER BY plan_date, produced_at DESC
),
s AS (
  SELECT sh.plan_date, sh.machine_id, sh.shelf_id, sh.pod_product_id, sh.action,
         sh.qty, sh.run_id, sh.engine_tag, sh.produced_at, sh.reasoning
  FROM public.pod_refill_plan_shadow sh
  JOIN latest l ON l.plan_date = sh.plan_date AND l.run_id = sh.run_id
),
v AS (
  -- superseded rows are historical noise, not the standing plan (the fixture-10 lesson)
  SELECT p.plan_date, p.machine_id, p.shelf_id, p.pod_product_id, p.action, p.qty, p.status
  FROM public.pod_refill_plan p
  WHERE p.status <> 'superseded'
    AND p.plan_date IN (SELECT plan_date FROM latest)
)
SELECT
  COALESCE(s.plan_date,      v.plan_date)      AS plan_date,
  COALESCE(s.machine_id,     v.machine_id)     AS machine_id,
  COALESCE(s.shelf_id,       v.shelf_id)       AS shelf_id,
  COALESCE(s.pod_product_id, v.pod_product_id) AS pod_product_id,
  COALESCE(s.action,         v.action)         AS action,
  s.run_id,
  s.engine_tag,
  s.produced_at,
  s.qty            AS qty_v3,
  v.qty            AS qty_v19,
  v.status         AS live_status,
  COALESCE(s.qty, 0) - COALESCE(v.qty, 0)      AS qty_delta,
  abs(COALESCE(s.qty, 0) - COALESCE(v.qty, 0)) AS abs_qty_delta,
  CASE
    WHEN s.plan_date IS NULL THEN 'v19_only'
    WHEN v.plan_date IS NULL THEN 'v3_only'
    WHEN s.qty = v.qty       THEN 'match'
    ELSE 'qty_diff'
  END AS diff_kind,
  s.reasoning      AS reasoning_v3
FROM s
FULL OUTER JOIN v
  ON  s.plan_date      = v.plan_date
  AND s.machine_id     = v.machine_id
  AND s.shelf_id       = v.shelf_id
  AND s.pod_product_id = v.pod_product_id
  AND s.action         = v.action;

COMMENT ON VIEW public.v_shadow_vs_live_plan_v3 IS
  'PRD-110 Phase 2 canonical diff: latest engine_add_pod_v3 shadow run vs the live v19 plan, at the '
  'plan grain (plan_date, machine_id, shelf_id, pod_product_id, action). diff_kind is one of '
  'match | qty_diff | v3_only | v19_only. Restricted to plan_dates where a shadow run exists, so an '
  'absent shadow reads as "no data" rather than as total divergence. Article 16 canonical object; '
  'do not re-derive this comparison anywhere else. See docs/architecture/ADR-shadow-plan-tables.md';

REVOKE ALL ON public.v_shadow_vs_live_plan_v3 FROM anon;
GRANT SELECT ON public.v_shadow_vs_live_plan_v3 TO authenticated;
