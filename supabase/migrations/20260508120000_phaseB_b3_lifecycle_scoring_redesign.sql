-- ═══════════════════════════════════════════════════════════════════════
-- phaseB_b3_lifecycle_scoring_redesign
--
-- Splits the lifecycle score into two distinct formulas:
--   • product_lifecycle_global.score = rank-percentile of per_machine_avg_v30
--     (absolute portfolio rank — Aquafina at 13.18 u/day-per-machine outranks
--      Evian Sparkling at 0.135 u/day-per-machine cleanly)
--   • slot_lifecycle.score = ratio-spectrum centered on the product's own
--     per-machine global avg (5.0 = at avg, 10.0 = 2× avg, 0.0 = zero)
--
-- Both scores are EMA-blended with prior value (α=0.67 → recent ≈ 2× historical).
-- Signal logic shifts to hard-gate getSignalV2 (both score AND trend required
-- for DOUBLE DOWN / KEEP GROWING).
--
-- Constitution articles in scope: 9, 12, 13, 14, 15
-- Cody verdict: ⚠️ Approve with revisions (CHANGELOG additions — done in same release)
-- ═══════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────
-- Part 1: product_lifecycle_global gets observability + bubble columns
-- ─────────────────────────────────────────────────────────────────────

ALTER TABLE public.product_lifecycle_global
  ADD COLUMN IF NOT EXISTS per_machine_avg_v30   numeric(10,3),
  ADD COLUMN IF NOT EXISTS global_rank           integer,
  ADD COLUMN IF NOT EXISTS score_raw             numeric(5,2),
  ADD COLUMN IF NOT EXISTS ramping_machine_count integer NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.product_lifecycle_global.per_machine_avg_v30 IS
  'total_velocity_30d / machine_count. Raw metric used to compute global_score (rank-percentile across all products with machine_count > 0).';
COMMENT ON COLUMN public.product_lifecycle_global.global_rank IS
  '1-indexed rank of this product across all currently-stocked products by per_machine_avg_v30 DESC. Score derived as (1 - (rank-1)/(N-1)) * 10.';
COMMENT ON COLUMN public.product_lifecycle_global.score_raw IS
  'Pre-EMA score computed this cron tick. Persisted so the EMA blend with prior score is auditable.';
COMMENT ON COLUMN public.product_lifecycle_global.ramping_machine_count IS
  'Number of currently-stocked machines for this product that are within their MACHINE_RAMP_DAYS window. Surfaced in Global view as a "RAMPING markets" badge.';

-- ─────────────────────────────────────────────────────────────────────
-- Part 2: slot_lifecycle gets observability columns
-- ─────────────────────────────────────────────────────────────────────

ALTER TABLE public.slot_lifecycle
  ADD COLUMN IF NOT EXISTS local_score_raw                numeric(5,2),
  ADD COLUMN IF NOT EXISTS spectrum_ratio                 numeric(8,3),
  ADD COLUMN IF NOT EXISTS product_avg_v30_at_score_time  numeric(10,3);

COMMENT ON COLUMN public.slot_lifecycle.local_score_raw IS
  'Pre-EMA score computed this cron tick (Local spectrum: 5.0 = at product per-machine-avg, 10.0 = 2× avg, 0.0 = zero). Persisted for audit.';
COMMENT ON COLUMN public.slot_lifecycle.spectrum_ratio IS
  'velocity_30d / product_per_machine_avg_v30 — raw ratio that maps to local_score (clipped 0-2, multiplied by 5).';
COMMENT ON COLUMN public.slot_lifecycle.product_avg_v30_at_score_time IS
  'The product''s per-machine avg v30 at the moment this slot was scored. Frozen for audit so the score is reproducible from this row alone.';

-- ─────────────────────────────────────────────────────────────────────
-- Part 3: lifecycle_score_history gets score_kind enum
-- ─────────────────────────────────────────────────────────────────────

ALTER TABLE public.lifecycle_score_history
  ADD COLUMN IF NOT EXISTS score_kind text NOT NULL DEFAULT 'v1_cohort_baseline'
    CHECK (score_kind IN ('v1_cohort_baseline', 'v2_split_global_local'));

COMMENT ON COLUMN public.lifecycle_score_history.score_kind IS
  'Which scoring formula produced this row. v1=pre-2026-05-08 cohort-baseline; v2=split global rank-percentile + local spectrum + EMA. Edge fn writes v2 for all new rows post-B.3.';

-- ─────────────────────────────────────────────────────────────────────
-- Part 4: Indexes for the new query patterns
-- ─────────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_product_lifecycle_global_rank
  ON public.product_lifecycle_global (global_rank ASC)
  WHERE machine_count > 0;

CREATE INDEX IF NOT EXISTS idx_slot_lifecycle_product_score
  ON public.slot_lifecycle (pod_product_id, score DESC)
  WHERE is_current = true AND archived = false;

-- ─────────────────────────────────────────────────────────────────────
-- Part 5: Convenience view for the Global matrix FE
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW public.v_product_lifecycle_global_enriched AS
SELECT
  pg.pod_product_id,
  pp.pod_product_name,
  pp.product_family_id,
  pf.family_name,
  pg.score,
  pg.score_raw,
  pg.global_rank,
  pg.per_machine_avg_v30,
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
  'Convenience read view for the Global lifecycle matrix. Joins product name + family + ramping markers. SECURITY INVOKER.';
