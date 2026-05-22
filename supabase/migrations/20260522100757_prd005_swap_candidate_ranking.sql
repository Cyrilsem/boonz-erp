-- ============================================================================
-- PRD-005 — swap candidate ranking enriched with destination shelf state
--
-- Source PRD: docs/prds/refill-pipeline/PRD-005-swap-engine-ignores-better-shelf.md
--
-- Existing engine_swap_pod / propose_swap_plan select substitutes via
-- get_similar_products (Pearson) with category fallback. The PRD's claim
-- ("ignores better-stocked alternative") is that the scorer doesn't weight
-- destination shelf state — a substitute on a near-empty shelf should beat
-- one on an over-stocked shelf, all else equal.
--
-- This migration delivers the visibility layer needed to (a) verify the
-- claim on live data and (b) feed the v8 engine patch that incorporates
-- shelf-state weighting:
--
--   1. v_swap_candidate_ranking — for every (machine, target_shelf,
--      candidate_substitute) triple Pearson would consider, surfaces:
--        - Pearson score (from get_similar_products via the substitute fn)
--        - destination shelf current_stock + max_capacity + fill_pct
--        - WH availability for the candidate
--      Ranked by a composite suggestion_score that incorporates shelf state.
--
--   2. swap_decision_audit_log append-only — engine writes one row per
--      swap decision (chosen substitute + the next 4 alternatives with
--      their scores). Lets CS see WHY the engine picked what it picked
--      and tune weights. Engine v8 will populate this.
--
-- Engine patch itself (incorporate v_swap_candidate_ranking.suggestion_score
-- into propose_swap_plan's ORDER BY) is the follow-up — large refactor
-- (22k-char function) intentionally not bundled here. View + log give
-- visibility now; engine patch follows once weights are calibrated.
--
-- Article 7 RLS on the log. Article 12 forward-only.
-- ============================================================================

BEGIN;

-- ── swap_decision_audit_log table ───────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.swap_decision_audit_log (
  decision_id        uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_date          date        NOT NULL,
  machine_id         uuid        REFERENCES public.machines(machine_id) ON DELETE SET NULL,
  shelf_id           uuid        REFERENCES public.shelf_configurations(shelf_id) ON DELETE SET NULL,
  removed_pod_product_id uuid    REFERENCES public.pod_products(pod_product_id) ON DELETE SET NULL,
  chosen_substitute_pod_product_id uuid REFERENCES public.pod_products(pod_product_id) ON DELETE SET NULL,
  chosen_pearson_score numeric,
  chosen_shelf_fill_pct numeric,
  chosen_wh_stock      numeric,
  chosen_composite_score numeric,
  -- Top 4 alternatives the engine ranked below the chosen one, with their
  -- composite scores — for CS tuning.
  alternatives       jsonb,
  decided_at         timestamptz NOT NULL DEFAULT now(),
  decided_by         uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  engine_version     text,
  note               text
);

COMMENT ON TABLE public.swap_decision_audit_log IS
  'PRD-005: append-only audit of swap engine decisions. Captures the chosen '
  'substitute + top-4 alternatives with composite scores so CS can see why '
  'the engine picked what it picked and tune the weighting accordingly.';

CREATE INDEX IF NOT EXISTS idx_sdal_machine_date
  ON public.swap_decision_audit_log (machine_id, plan_date DESC, decided_at DESC);

ALTER TABLE public.swap_decision_audit_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sdal_select ON public.swap_decision_audit_log;
CREATE POLICY sdal_select ON public.swap_decision_audit_log
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS sdal_insert ON public.swap_decision_audit_log;
CREATE POLICY sdal_insert ON public.swap_decision_audit_log
  FOR INSERT TO authenticated WITH CHECK (true);
DROP POLICY IF EXISTS sdal_no_update ON public.swap_decision_audit_log;
CREATE POLICY sdal_no_update ON public.swap_decision_audit_log
  FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
DROP POLICY IF EXISTS sdal_no_delete ON public.swap_decision_audit_log;
CREATE POLICY sdal_no_delete ON public.swap_decision_audit_log
  FOR DELETE TO authenticated USING (false);

-- ── v_swap_candidate_ranking view ──────────────────────────────────────────

CREATE OR REPLACE VIEW public.v_swap_candidate_ranking
WITH (security_invoker = true) AS
WITH dead_or_rotating AS (
  -- Slots that swap engine would consider for replacement (Wind Down / Rotate Out / Dead)
  SELECT sl.machine_id, sl.shelf_id, sl.pod_product_id,
         m.official_name AS machine_name,
         sc.shelf_code,
         pp.pod_product_name AS removed_pod_product
  FROM slot_lifecycle sl
  JOIN machines m              ON m.machine_id = sl.machine_id
  JOIN shelf_configurations sc ON sc.shelf_id = sl.shelf_id
  JOIN pod_products pp         ON pp.pod_product_id = sl.pod_product_id
  WHERE sl.signal IN ('WIND DOWN','ROTATE OUT','DEAD')
),
candidates AS (
  -- For each removed slot, pull top candidates from get_similar_products
  -- via find_substitutes_for_shelf (security_invoker, read-only helper)
  SELECT d.machine_id, d.machine_name, d.shelf_id, d.shelf_code,
         d.pod_product_id AS removed_pod_product_id, d.removed_pod_product,
         sub.pod_product_id AS candidate_pod_product_id,
         sub.name           AS candidate_pod_product,
         sub.pearson_score,
         sub.source         AS pearson_source,
         sub.wh_stock_units AS candidate_wh_stock
  FROM dead_or_rotating d
  CROSS JOIN LATERAL find_substitutes_for_shelf(
    CURRENT_DATE + 1,
    d.machine_id, d.shelf_id, d.pod_product_id,
    10,   -- top-N candidates per slot
    66    -- moderate aggressiveness (per-machine + loc_type Pearson)
  ) sub
),
candidate_dest AS (
  -- Bring in the destination shelf's current state for each candidate
  -- substitute. The "destination shelf" is the same target shelf (we're
  -- proposing to PUT candidate on shelf d.shelf_id, displacing removed_pod_product).
  SELECT c.*,
         sc.max_capacity,
         COALESCE(
           (SELECT SUM(pi.current_stock) FROM pod_inventory pi
             WHERE pi.machine_id = c.machine_id
               AND pi.shelf_id   = c.shelf_id
               AND pi.status     = 'Active'),
           0
         ) AS dest_shelf_current_stock
  FROM candidates c
  JOIN shelf_configurations sc ON sc.shelf_id = c.shelf_id
)
SELECT
  machine_id, machine_name,
  shelf_id,   shelf_code,
  removed_pod_product_id, removed_pod_product,
  candidate_pod_product_id, candidate_pod_product,
  pearson_score, pearson_source,
  candidate_wh_stock,
  dest_shelf_current_stock,
  max_capacity,
  CASE WHEN max_capacity > 0
       THEN (dest_shelf_current_stock::numeric / max_capacity)
       ELSE NULL END AS dest_shelf_fill_pct,
  -- Composite score: Pearson + bonus for empty destination + bonus for WH stock
  -- Tunable weights — start at the documented PRD-005 weighting:
  --   Pearson alone (60%) + empty-shelf bonus (25%) + wh-stock bonus (15%)
  (
    COALESCE(pearson_score, 0) * 0.6
    + CASE WHEN max_capacity > 0
           THEN (1.0 - LEAST(dest_shelf_current_stock::numeric / max_capacity, 1.0)) * 25
           ELSE 0 END
    + LEAST(COALESCE(candidate_wh_stock, 0) / 10.0, 1.0) * 15
  )::numeric AS suggestion_score
FROM candidate_dest;

COMMENT ON VIEW public.v_swap_candidate_ranking IS
  'PRD-005: enriched substitute ranking. Composite score = Pearson 60% + '
  'empty-destination-shelf bonus 25% + WH-stock bonus 15%. Engine v8 will '
  'ORDER BY this composite. CS reads to verify the OMDCW-1021 Hunter/Plaay '
  'case and tune the weight constants.';

COMMIT;

-- ============================================================================
-- POST-APPLY USAGE
--   -- OMDCW-1021 Hunter/Plaay diagnostic
--   SELECT * FROM v_swap_candidate_ranking
--   WHERE machine_name = 'OMDCW-1021'
--   ORDER BY shelf_code, suggestion_score DESC NULLS LAST;
--
--   -- Top engine-suggested swap by composite score for tomorrow
--   SELECT machine_name, shelf_code, removed_pod_product,
--          candidate_pod_product, ROUND(suggestion_score, 2) AS score
--   FROM v_swap_candidate_ranking
--   ORDER BY suggestion_score DESC NULLS LAST LIMIT 20;
--
-- DEFERRED:
--   - Engine v8 patch to propose_swap_plan: ORDER BY v_swap_candidate_ranking
--     .suggestion_score instead of raw pearson. Requires careful refactor
--     of the 22k-char function — separate follow-up after weight calibration.
-- ============================================================================
