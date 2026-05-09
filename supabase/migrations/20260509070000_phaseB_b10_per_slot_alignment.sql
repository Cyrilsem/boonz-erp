-- ═══════════════════════════════════════════════════════════════════════
-- phaseB_b10_per_slot_alignment
--
-- B.10: Align Global rank-percentile and Local spectrum on the SAME base —
-- per-slot avg v30, not per-machine avg v30. Consolidation (multiple facings
-- of one product at one machine) no longer inflates the Global rank, and
-- slot scores are now compared to per-slot productivity (1:1 unit match).
--
-- Adds: product_lifecycle_global.per_slot_avg_v30, .slot_count.
-- Keeps: per_machine_avg_v30 column for backward compat (still populated)
-- but Global rank + Local spectrum now both anchor on per_slot.
--
-- Constitution articles in scope: 9, 12, 14, 15
-- ═══════════════════════════════════════════════════════════════════════

ALTER TABLE public.product_lifecycle_global
  ADD COLUMN IF NOT EXISTS per_slot_avg_v30 numeric(10,3),
  ADD COLUMN IF NOT EXISTS slot_count       integer NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.product_lifecycle_global.per_slot_avg_v30 IS
  'total_velocity_30d / current_slot_count. The B.10 anchor for Global rank-percentile and Local spectrum. Decouples consolidation from per-facing productivity.';
COMMENT ON COLUMN public.product_lifecycle_global.slot_count IS
  'Count of currently-stocked, scoreable slots holding this product (across the fleet). Denominator for per_slot_avg_v30.';

CREATE INDEX IF NOT EXISTS idx_product_lifecycle_global_per_slot_avg
  ON public.product_lifecycle_global (per_slot_avg_v30 DESC NULLS LAST)
  WHERE slot_count > 0;

DROP VIEW IF EXISTS public.v_product_lifecycle_global_enriched;
CREATE VIEW public.v_product_lifecycle_global_enriched AS
SELECT
  pg.pod_product_id,
  pp.pod_product_name,
  pp.product_family_id,
  pf.family_name,
  pg.score,
  pg.score_raw,
  pg.global_rank,
  pg.per_machine_avg_v30,
  pg.per_slot_avg_v30,
  pg.slot_count,
  pg.total_velocity_30d,
  pg.machine_count,
  pg.ramping_machine_count,
  pg.trend_component,
  pg.signal,
  pg.best_location_type,
  pg.worst_location_type,
  pg.last_evaluated_at
FROM public.product_lifecycle_global pg
JOIN public.pod_products pp ON pp.pod_product_id = pg.pod_product_id
LEFT JOIN public.product_families pf ON pf.product_family_id = pp.product_family_id;

ALTER VIEW public.v_product_lifecycle_global_enriched SET (security_invoker = true);

COMMENT ON VIEW public.v_product_lifecycle_global_enriched IS
  'Convenience read view for the Global lifecycle matrix. B.10 — exposes per_slot_avg_v30 alongside per_machine for transition. SECURITY INVOKER.';
