-- ONE-LOOP-3 Job 2 / PRD-126 R5: machines_to_visit.priority_score was
-- numeric(5,2) (max 999.99), sized for the old 0-100-ish points score.
-- pick_machines_for_refill v12 now writes p_score_aed (seen up to ~2310 on
-- real fleet data), which overflows that precision. Widen to match
-- v_machine_priority.p_score_aed's own numeric(10,2).

-- v_pick_decision_cohorts_v3 depends on this column; drop + recreate verbatim
-- around the ALTER (same body, checked via pg_get_viewdef before dropping).
DROP VIEW public.v_pick_decision_cohorts_v3;

ALTER TABLE public.machines_to_visit
  ALTER COLUMN priority_score TYPE numeric(10,2);

CREATE VIEW public.v_pick_decision_cohorts_v3 AS
 WITH base AS (
         SELECT machines_to_visit.plan_date,
            machines_to_visit.machine_id,
            machines_to_visit.route_cluster,
            machines_to_visit.priority_score,
            machines_to_visit.dropped_at IS NOT NULL AS was_dropped
           FROM machines_to_visit
          WHERE machines_to_visit.add_source = 'picker'::text
        ), agg AS (
         SELECT base.plan_date,
            count(*)::integer AS picks,
            count(*) FILTER (WHERE NOT base.was_dropped)::integer AS kept,
            count(*) FILTER (WHERE base.was_dropped)::integer AS drops,
            count(DISTINCT base.route_cluster) FILTER (WHERE NOT base.was_dropped)::integer AS kept_clusters,
            count(DISTINCT base.route_cluster) FILTER (WHERE base.was_dropped)::integer AS drop_clusters
           FROM base
          GROUP BY base.plan_date
        ), pairs AS (
         SELECT k.plan_date,
            count(*)::integer AS pair_count,
            count(*) FILTER (WHERE k.priority_score > d.priority_score)::integer AS score_kept_higher,
            count(*) FILTER (WHERE k.priority_score < d.priority_score)::integer AS score_drop_higher
           FROM base k
             JOIN base d ON d.plan_date = k.plan_date
          WHERE NOT k.was_dropped AND d.was_dropped
          GROUP BY k.plan_date
        )
 SELECT a.plan_date,
    a.picks,
    a.kept,
    a.drops,
    a.kept_clusters,
    a.drop_clusters,
        CASE
            WHEN a.drops = 0 THEN 'no_drops'::text
            WHEN a.kept = 0 THEN 'day_cancelled'::text
            WHEN a.kept_clusters = 1 AND a.drop_clusters >= 1 THEN 'cluster_scope'::text
            ELSE 'mixed_capacity'::text
        END AS cohort,
    a.drops > 0 AND a.kept > 0 AND a.kept_clusters > 1 AS is_learnable,
    COALESCE(p.pair_count, 0) AS pair_count,
    COALESCE(p.score_kept_higher, 0) AS score_kept_higher,
    COALESCE(p.score_drop_higher, 0) AS score_drop_higher,
        CASE
            WHEN (COALESCE(p.score_kept_higher, 0) + COALESCE(p.score_drop_higher, 0)) = 0 THEN NULL::numeric
            ELSE round(100.0 * p.score_kept_higher::numeric / (p.score_kept_higher + p.score_drop_higher)::numeric, 2)
        END AS score_concordance_pct
   FROM agg a
     LEFT JOIN pairs p USING (plan_date);
