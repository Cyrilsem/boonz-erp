-- PRD-110 P2.0b — blocked demand in the shadow world.
--
-- A VIEW, not a table, and the distinction is constitutional. blocked_demand is
-- derived: _blocked_demand_gaps_v3 is a pure SELECT over pod_refills with no
-- state of its own, and the shadow rows it reads are already durable and
-- immutable (ADR §5.1, write-once per run_id). So Article 14's first clause
-- genuinely binds here — there is nothing a table would preserve that this view
-- cannot recompute identically forever. That is the exact opposite of
-- pod_refills_shadow's own case, where the inputs vanish by morning.
--
-- Shape mirrors public._blocked_demand_gaps_v3 so the two sides are comparable,
-- with three deliberate differences, each stated rather than silent:
--   1. run_id is carried, so a blocked unit is attributable to the run that
--      produced it (the live ledger has no equivalent because live has one run).
--   2. velocity_instock is emitted under ITS OWN key. The live derivation writes
--      max(pr.velocity_30d) under 'velocity_30d'; reusing that key with a
--      different quantity behind it would repeat S-13's defect one layer up.
--   3. derived_by names this view, so a reader never mistakes a shadow row for
--      a live ledger row.
-- The exclusion list is reproduced VERBATIM from the live function; if the two
-- diverge the sides stop being comparable and the Phase-2 gate is measuring noise.

CREATE OR REPLACE VIEW public.v_blocked_demand_shadow_v3
WITH (security_invoker = true) AS
  SELECT prs.run_id,
         prs.engine_tag,
         min(prs.produced_at)                                    AS produced_at,
         prs.plan_date,
         prs.machine_id,
         prs.shelf_id,
         prs.pod_product_id,
         CEIL(SUM((prs.reasoning->>'need_raw')::numeric - prs.qty))::int AS qty_blocked,
         CASE
           WHEN bool_or(prs.clamp_reason = 'blocked_no_wh')      THEN 'blocked_no_wh'
           WHEN bool_or(prs.clamp_reason = 'partial_wh_limited') THEN 'partial_wh_limited'
           ELSE 'routing_gap'
         END                                                     AS reason,
         jsonb_build_object(
           'shelf_code',         min(prs.reasoning->>'shelf_code'),
           'machine_name',       min(prs.reasoning->>'official_name'),
           'signal',             min(prs.signal),
           'velocity_instock',   max(prs.velocity_instock),
           'availability_basis', min(prs.availability_basis),
           'current_stock',      max(prs.current_stock),
           'max_stock',          max(prs.max_stock),
           'need_raw',           max((prs.reasoning->>'need_raw')::numeric),
           'qty_planned',        max(prs.qty),
           'wh_available',       max(prs.wh_available_pod),
           'clamp_reason',       min(prs.clamp_reason),
           'engine_tag',         min(prs.engine_tag),
           'derived_by',         'v_blocked_demand_shadow_v3 from pod_refills_shadow'
         )                                                       AS reasoning
    FROM public.pod_refills_shadow prs
   WHERE prs.reasoning->>'need_raw' IS NOT NULL
     AND (prs.reasoning->>'need_raw')::numeric > prs.qty
     AND COALESCE(prs.clamp_reason,'') NOT IN
         ('skipped_strategic_intent','dead_tagged_for_swap','drain_no_refill')
   GROUP BY prs.run_id, prs.engine_tag, prs.plan_date,
            prs.machine_id, prs.shelf_id, prs.pod_product_id;

COMMENT ON VIEW public.v_blocked_demand_shadow_v3 IS
  'PRD-110 P2.0b. Blocked demand as it WOULD be recorded from a v3 shadow run. '
  'Mirrors _blocked_demand_gaps_v3 over pod_refills_shadow, keyed by run_id. '
  'Reads nothing live and writes nothing; blocked_demand remains the canonical '
  'ledger for the LIVE engine (Article 16, disjoint by source).';

REVOKE ALL ON public.v_blocked_demand_shadow_v3 FROM anon;
GRANT SELECT ON public.v_blocked_demand_shadow_v3 TO authenticated;
