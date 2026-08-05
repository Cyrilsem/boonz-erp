-- PRD-110 P4.3b — v_pick_decision_cohorts_v3: the registered metric that classifies WHY CS's
-- final selection differs from the cron pick on a given plan_date.
--
-- ⛔ THE REASON THIS VIEW EXISTS RATHER THAN LIVING INSIDE THE MINER (Article 16): the cohort
-- question has at least three consumers — mine_pick_history_v3, the G12 acceptance-rate telemetry,
-- and the P4.5 scoreboard — and the charter's Gate 0 "CS would likely add/drop" hint will be a
-- fourth. Computed inline it forks the moment the second consumer appears. The miner is a
-- CONSUMER of this view and must NOT re-derive the predicate against machines_to_visit.
--
-- ⛔ WHY THE COHORT MATTERS AT ALL — measured, not assumed. 241 live CS drops, and their reasons
-- are overwhelmingly ROUTE OR DAY SCOPE, not per-machine judgment: "cancel entire 5-Jun plan" x25,
-- "CS route scope: focus on 6-machine route" x22, "CS shortlist" x21, "AMZ-only route today",
-- "VOX track dropped for 29 Jul". A miner that treats every drop as "the picker over-ranked this
-- machine" would learn to down-weight VOX machines because VOX days are episodic. Only the
-- mixed_capacity cohort — CS kept a top-K spread across MORE THAN ONE route cluster — carries
-- information about machine RANK. Live: mixed_capacity 24 days / 188 drops / 241 kept ·
-- cluster_scope 7 days / 53 drops · no_drops 39 days · day_cancelled 0 days.
--
-- ⭐ score_concordance_pct IS THE HEADLINE DIAGNOSTIC, and it is a finding, not a proposal:
-- fleet-wide across the 24 learnable days it is 50.0% over 1653 pairs. The picker's own composite
-- priority_score is a COIN FLIP against CS's keep/drop decision. That statement is true and
-- important and is NOT an instruction to move any particular dial.

CREATE OR REPLACE VIEW public.v_pick_decision_cohorts_v3 AS
WITH base AS (
  SELECT plan_date, machine_id, route_cluster, priority_score,
         (dropped_at IS NOT NULL) AS was_dropped
  FROM public.machines_to_visit
  WHERE add_source = 'picker'
), agg AS (
  SELECT plan_date,
         count(*)::integer                                          AS picks,
         count(*) FILTER (WHERE NOT was_dropped)::integer           AS kept,
         count(*) FILTER (WHERE was_dropped)::integer               AS drops,
         count(DISTINCT route_cluster)
           FILTER (WHERE NOT was_dropped)::integer                  AS kept_clusters,
         count(DISTINCT route_cluster)
           FILTER (WHERE was_dropped)::integer                      AS drop_clusters
  FROM base GROUP BY plan_date
), pairs AS (
  -- Same-day (kept, dropped) comparisons on the picker's own composite.
  SELECT k.plan_date,
         count(*)::integer                                                     AS pair_count,
         count(*) FILTER (WHERE k.priority_score > d.priority_score)::integer  AS score_kept_higher,
         count(*) FILTER (WHERE k.priority_score < d.priority_score)::integer  AS score_drop_higher
  FROM base k
  JOIN base d ON d.plan_date = k.plan_date
  WHERE NOT k.was_dropped AND d.was_dropped
  GROUP BY k.plan_date
)
SELECT
  a.plan_date,
  a.picks,
  a.kept,
  a.drops,
  a.kept_clusters,
  a.drop_clusters,
  CASE
    WHEN a.drops = 0                                   THEN 'no_drops'
    WHEN a.kept  = 0                                   THEN 'day_cancelled'
    WHEN a.kept_clusters = 1 AND a.drop_clusters >= 1  THEN 'cluster_scope'
    ELSE 'mixed_capacity'
  END AS cohort,
  -- ⛔ THE GATE every learner must pass through. Only mixed_capacity days compare machines that
  -- CS was genuinely choosing BETWEEN.
  (a.drops > 0 AND a.kept > 0 AND a.kept_clusters > 1) AS is_learnable,
  COALESCE(p.pair_count, 0)        AS pair_count,
  COALESCE(p.score_kept_higher, 0) AS score_kept_higher,
  COALESCE(p.score_drop_higher, 0) AS score_drop_higher,
  -- ⛔ NULL when every pair ties (or there are no pairs) — UNMEASURABLE, never 50 by default.
  -- Ties are excluded from the denominator: concordance is about the pairs the score RANKED.
  CASE WHEN COALESCE(p.score_kept_higher, 0) + COALESCE(p.score_drop_higher, 0) = 0 THEN NULL
       ELSE round(100.0 * p.score_kept_higher
                  / (p.score_kept_higher + p.score_drop_higher), 2)
  END AS score_concordance_pct
FROM agg a
LEFT JOIN pairs p USING (plan_date);

COMMENT ON VIEW public.v_pick_decision_cohorts_v3 IS
  'PRD-110 P4.3b registered metric (Article 16). One row per plan_date classifying WHY CS''s final selection differs from the cron pick. ⛔ is_learnable = mixed_capacity ONLY: cluster_scope and day_cancelled drops are route/day decisions and carry NO signal about machine rank. Consumers (mine_pick_history_v3, G12 telemetry, P4.5 scoreboard) MUST read this view and must not re-derive the predicate against machines_to_visit.';

-- ⛔ ADR §11.2 / S-104: REVOKE first, then GRANT — a GRANT is additive and cannot narrow.
REVOKE ALL ON public.v_pick_decision_cohorts_v3 FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_pick_decision_cohorts_v3 TO authenticated;
