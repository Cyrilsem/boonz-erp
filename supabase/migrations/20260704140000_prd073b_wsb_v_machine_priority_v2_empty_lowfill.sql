-- PRD-073 WS-B: grade-weighted empty + low-fill urgency in v_machine_priority (v2).
-- CS requirement: an empty shelf must add real urgency ranked A>B>C>D (empty is empty -
-- D still counts), sub-25%-fill shelves likewise; an empty A/B shelf is never P3.
--
-- Grain note (Dara): shelf_graded rows are v_shelf_sales_identity identities (enabled,
-- non-broken slots already filtered upstream). is_empty = identity stock 0; is_low =
-- 0 < stock/cap*100 < low_fill_pct_floor; denominator = graded identities per machine.
--
-- All knobs live in pick_urgency_params (PRD-058 dial pattern; single row, defaults fill
-- the existing row on ADD COLUMN - tunable without redeploy):
--   empty_wt_a/b/c/d (1.0/0.7/0.45/0.25), w_empty (0.9), w_lowfill (0.5),
--   low_fill_pct_floor (25), p1_empty_ab_min (1).
-- New output columns appended at the END (CREATE OR REPLACE safe): s_empty, s_lowfill,
-- empty_ab_count. New reasons: hero_shelf_empty / empty_shelves / low_fill_sellers.
-- P1 escalation: empty A/B-graded shelf count >= p1_empty_ab_min forces P1_RESTOCK.
-- Preserved v1 quirks (T3 regression guard): zero-identity machines still get
-- s_capacity=100 via NULL-ignoring LEAST/GREATEST; all prior columns byte-order identical.
-- pick_machines_for_refill body untouched (consumes this view); engines untouched.

ALTER TABLE public.pick_urgency_params
  ADD COLUMN IF NOT EXISTS empty_wt_a numeric NOT NULL DEFAULT 1.0,
  ADD COLUMN IF NOT EXISTS empty_wt_b numeric NOT NULL DEFAULT 0.7,
  ADD COLUMN IF NOT EXISTS empty_wt_c numeric NOT NULL DEFAULT 0.45,
  ADD COLUMN IF NOT EXISTS empty_wt_d numeric NOT NULL DEFAULT 0.25,
  ADD COLUMN IF NOT EXISTS w_empty numeric NOT NULL DEFAULT 0.9,
  ADD COLUMN IF NOT EXISTS w_lowfill numeric NOT NULL DEFAULT 0.5,
  ADD COLUMN IF NOT EXISTS low_fill_pct_floor numeric NOT NULL DEFAULT 25,
  ADD COLUMN IF NOT EXISTS p1_empty_ab_min integer NOT NULL DEFAULT 1;

CREATE OR REPLACE VIEW public.v_machine_priority AS
WITH shelf_u25 AS (
  SELECT vls.machine_id,
         count(*) FILTER (WHERE vls.is_enabled AND vls.current_stock > 0 AND vls.fill_pct < 25) AS under25
  FROM public.v_live_shelf_stock vls
  GROUP BY vls.machine_id
),
shelf_graded AS (
  SELECT i.machine_id,
         CASE WHEN i.dvel >= pp.a_floor THEN 'A'
              WHEN i.dvel >= pp.b_floor THEN 'B'
              WHEN i.dvel > 0           THEN 'C'
              ELSE 'D' END AS grade,
         i.dos, i.stock, i.cap,
         ( CASE WHEN i.dvel >= pp.a_floor THEN pp.grade_wt_a
                WHEN i.dvel >= pp.b_floor THEN pp.grade_wt_b
                WHEN i.dvel > 0           THEN pp.grade_wt_c
                ELSE 0 END
           * GREATEST(0, LEAST(1, (pp.horizon_days - COALESCE(i.dos, pp.horizon_days)) / pp.horizon_days))
           * 100 )::numeric AS shelf_runout,
         (i.dvel >= pp.a_floor AND i.dos < pp.horizon_days)                    AS a_below,
         (i.dvel >= pp.b_floor AND i.dos < pp.horizon_days)                    AS ab_below,
         -- PRD-073 WS-B: empty / low-fill signals
         (i.stock = 0)                                                          AS is_empty,
         COALESCE(i.stock > 0
                  AND (i.stock::numeric / NULLIF(i.cap, 0) * 100) < pp.low_fill_pct_floor,
                  false)                                                        AS is_low,
         CASE WHEN i.dvel >= pp.a_floor THEN pp.empty_wt_a
              WHEN i.dvel >= pp.b_floor THEN pp.empty_wt_b
              WHEN i.dvel > 0           THEN pp.empty_wt_c
              ELSE pp.empty_wt_d END                                            AS empty_grade_mult
  FROM public.v_shelf_sales_identity i
  CROSS JOIN public.pick_urgency_params pp
),
magg AS (
  SELECT machine_id,
         count(*) FILTER (WHERE grade = 'A')                         AS a_count,
         count(*) FILTER (WHERE grade = 'B')                         AS b_count,
         count(*) FILTER (WHERE grade = 'C')                         AS c_count,
         count(*) FILTER (WHERE grade = 'D')                         AS d_count,
         min(dos) FILTER (WHERE grade = 'A')                         AS soonest_a_dos,
         max(shelf_runout) FILTER (WHERE grade IN ('A','B','C'))     AS worst_runout,
         avg(shelf_runout) FILTER (WHERE grade IN ('A','B','C'))     AS breadth_runout,
         sum(stock) FILTER (WHERE grade IN ('A','B','C'))            AS abc_stock,
         sum(cap)   FILTER (WHERE grade IN ('A','B','C'))            AS abc_cap,
         bool_or(a_below)                                            AS hero_below,
         bool_or(ab_below)                                           AS any_ab_below,
         -- PRD-073 WS-B aggregates
         count(*)                                                    AS graded_shelves,
         sum(empty_grade_mult) FILTER (WHERE is_empty)               AS empty_mult_sum,
         sum(empty_grade_mult) FILTER (WHERE is_low)                 AS low_mult_sum,
         count(*) FILTER (WHERE is_empty AND grade IN ('A','B'))     AS empty_ab_count
  FROM shelf_graded
  GROUP BY machine_id
),
mscore AS (
  SELECT s.machine_id,
         ( COALESCE(g.worst_runout, 0) * p.runout_worst_wt
           + COALESCE(g.breadth_runout, 0) * p.runout_breadth_wt )                         AS s_runout,
         GREATEST(0, LEAST(100, (1 - COALESCE(g.abc_stock, 0) / NULLIF(g.abc_cap, 0)) * 100)) AS s_capacity,
         LEAST(100, (p.expiry_weight_expired * s.expired_skus_now
                     + p.expiry_weight_exp3d * s.expired_skus_3d) / p.expiry_norm * 100)    AS s_expiry,
         GREATEST(0, LEAST(100, (s.days_since_visit - p.stale_grace_days)
                                / NULLIF(p.stale_full_days - p.stale_grace_days, 0) * 100)) AS s_stale,
         (100 * COALESCE(g.empty_mult_sum, 0) / GREATEST(g.graded_shelves, 1))::numeric     AS s_empty,
         (100 * COALESCE(g.low_mult_sum, 0)   / GREATEST(g.graded_shelves, 1))::numeric     AS s_lowfill,
         COALESCE(g.empty_ab_count, 0)   AS empty_ab_count,
         COALESCE(g.hero_below, false)   AS hero_below,
         COALESCE(g.any_ab_below, false) AS any_ab_below,
         COALESCE(g.a_count, 0) AS a_count, COALESCE(g.b_count, 0) AS b_count,
         COALESCE(g.c_count, 0) AS c_count, COALESCE(g.d_count, 0) AS d_count,
         g.soonest_a_dos
  FROM public.v_machine_health_signals s
  LEFT JOIN magg g ON g.machine_id = s.machine_id
  CROSS JOIN public.pick_urgency_params p
)
SELECT
  s.machine_id,
  s.official_name,
  s.venue_group,
  s.location_type,
  s.building_id,
  s.dead_slot_pct,
  s.empty_shelf_pct,
  s.fill_pct,
  s.hero_slot_count,
  s.expired_skus_now,
  s.expired_skus_30d,
  s.days_since_visit,
  s.units_last_7d,
  s.is_ramping,
  s.active_intent_count,
  s.tier,
  s.empty_shelves_count,
  s.cur_stock,
  s.expired_skus_3d,
  s.expired_skus_7d,
  s.runway_days,
  m.include_in_refill,
  COALESCE(m.status, 'Active'::text) AS machine_status,
  COALESCE(u.under25, 0::bigint)     AS under25,
  CASE WHEN s.venue_group = 'VOX'::text THEN 'vox'::text ELSE 'main'::text END AS svc_track,
  -- p_tier: shelf-aware urgency tiering (overrides first; PRD-073 adds hero_shelf_empty)
  CASE
    WHEN (ms.hero_below AND s.days_since_visit > p.cooldown_days)
      OR s.days_since_visit > p.stale_override_days
      OR s.expired_skus_now >= p.p1_expired_min
      OR ms.empty_ab_count >= p.p1_empty_ab_min
      OR (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity
          + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale
          + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill) >= p.p1_threshold
      THEN 'P1_RESTOCK'::text
    WHEN s.expired_skus_3d >= p.p2_exp3d_min
      OR ms.any_ab_below
      OR (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity
          + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale
          + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill) >= p.p2_threshold
      THEN 'P2_MAINTAIN'::text
    ELSE 'P3_OK'::text
  END AS p_tier,
  -- p_score = urgency
  (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity
   + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale
   + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill)::numeric(6,2) AS p_score,
  -- reasons_arr (PRD-073 adds hero_shelf_empty / empty_shelves / low_fill_sellers)
  array_remove(ARRAY[
    CASE WHEN ms.hero_below AND s.days_since_visit > p.cooldown_days THEN 'hero_runout'::text END,
    CASE WHEN s.days_since_visit > p.stale_override_days            THEN 'stale_overdue'::text END,
    CASE WHEN s.expired_skus_now >= p.p1_expired_min                THEN 'expired_now'::text END,
    CASE WHEN ms.empty_ab_count >= p.p1_empty_ab_min                THEN 'hero_shelf_empty'::text END,
    CASE WHEN s.expired_skus_3d  >= p.p2_exp3d_min                  THEN 'expiring_soon'::text END,
    CASE WHEN ms.any_ab_below                                       THEN 'seller_below_horizon'::text END,
    CASE WHEN ms.s_empty > 0                                        THEN 'empty_shelves'::text END,
    CASE WHEN ms.s_lowfill >= 20                                    THEN 'low_fill_sellers'::text END,
    CASE WHEN (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity
               + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale
               + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill) >= p.p1_threshold THEN 'high_urgency'::text END,
    CASE WHEN ms.s_capacity >= 50                                   THEN 'low_capacity'::text END
  ], NULL::text) AS reasons_arr,
  COALESCE(s.venue_group, s.building_id, s.official_name) AS r_cluster,
  (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity
   + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale
   + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill)::numeric(6,2) AS urgency,
  round(ms.soonest_a_dos::numeric, 2) AS soonest_a_dos,
  ms.a_count AS grade_a_count,
  ms.b_count AS grade_b_count,
  ms.c_count AS grade_c_count,
  ms.d_count AS grade_d_count,
  -- PRD-073 WS-B: appended columns
  ms.s_empty::numeric(6,2)    AS s_empty,
  ms.s_lowfill::numeric(6,2)  AS s_lowfill,
  ms.empty_ab_count           AS empty_ab_count
FROM public.v_machine_health_signals s
  JOIN public.machines m ON m.machine_id = s.machine_id
  LEFT JOIN shelf_u25 u ON u.machine_id = s.machine_id
  LEFT JOIN mscore ms ON ms.machine_id = s.machine_id
  CROSS JOIN public.pick_urgency_params p;
