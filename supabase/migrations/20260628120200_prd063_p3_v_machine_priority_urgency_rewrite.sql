-- PRD-063 step 3: rewrite v_machine_priority IN PLACE to the shelf-aware urgency model.
-- Supersedes the PRD-058 machine-level tiering body. NO shadow: picker / cards / VOX labels all
-- read this same view. Every pre-existing output column is preserved (sourced unchanged from
-- v_machine_health_signals / machines / shelf_u25); only p_tier / p_score / reasons_arr are
-- recomputed, and urgency / soonest_a_dos / grade counts are appended.
--
-- Model (knobs in pick_urgency_params, CROSS JOINed):
--   per (machine, identity) shelf from v_shelf_sales_identity: dvel=units30d/30, dos=stock/dvel,
--   grade A>=a_floor / B>=b_floor / C>0 / D=0. shelf_runout = gradeWeight * clamp((H-dos)/H) * 100.
--   machine s_runout = worst_wt*worst_shelf + breadth_wt*mean(A/B/C shelves).
--   s_capacity = clamp(1 - Sstock/Scap over A/B/C) * 100.  s_expiry from machine expiry signals.
--   s_stale ramps 0 at stale_grace -> 100 at stale_full.  urgency = S(weight_i * component_i).
--   TIER (overrides first): P1 if hero (A dos<H AND days_since_visit>cooldown) OR stale
--   (days_since_visit>stale_override) OR expired_now>=p1_expired_min OR urgency>=p1_threshold;
--   else P2 if expiring<=3d>=p2_exp3d_min OR any A/B dos<H OR urgency>=p2_threshold; else P3.
-- Verified on 2026-06-28 default params: new main-track P1 reproduces the locked list (drops
-- MC-2004 / ALJLT-1015-0200 / NOVO-1023, adds ADDMIND-1007 + GRIT-1022, keeps the 5 expiry machines).

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
         (i.dvel >= pp.b_floor AND i.dos < pp.horizon_days)                    AS ab_below
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
         bool_or(ab_below)                                           AS any_ab_below
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
  -- p_tier: shelf-aware urgency tiering (overrides first)
  CASE
    WHEN (ms.hero_below AND s.days_since_visit > p.cooldown_days)
      OR s.days_since_visit > p.stale_override_days
      OR s.expired_skus_now >= p.p1_expired_min
      OR (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity
          + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale) >= p.p1_threshold
      THEN 'P1_RESTOCK'::text
    WHEN s.expired_skus_3d >= p.p2_exp3d_min
      OR ms.any_ab_below
      OR (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity
          + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale) >= p.p2_threshold
      THEN 'P2_MAINTAIN'::text
    ELSE 'P3_OK'::text
  END AS p_tier,
  -- p_score = urgency
  (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity
   + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale)::numeric(6,2) AS p_score,
  -- reasons_arr rebuilt from the new triggers
  array_remove(ARRAY[
    CASE WHEN ms.hero_below AND s.days_since_visit > p.cooldown_days THEN 'hero_runout'::text END,
    CASE WHEN s.days_since_visit > p.stale_override_days            THEN 'stale_overdue'::text END,
    CASE WHEN s.expired_skus_now >= p.p1_expired_min                THEN 'expired_now'::text END,
    CASE WHEN s.expired_skus_3d  >= p.p2_exp3d_min                  THEN 'expiring_soon'::text END,
    CASE WHEN ms.any_ab_below                                       THEN 'seller_below_horizon'::text END,
    CASE WHEN (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity
               + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale) >= p.p1_threshold THEN 'high_urgency'::text END,
    CASE WHEN ms.s_capacity >= 50                                   THEN 'low_capacity'::text END
  ], NULL::text) AS reasons_arr,
  COALESCE(s.venue_group, s.building_id, s.official_name) AS r_cluster,
  -- NEW columns
  (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity
   + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale)::numeric(6,2) AS urgency,
  round(ms.soonest_a_dos::numeric, 2) AS soonest_a_dos,
  ms.a_count AS grade_a_count,
  ms.b_count AS grade_b_count,
  ms.c_count AS grade_c_count,
  ms.d_count AS grade_d_count
FROM public.v_machine_health_signals s
  JOIN public.machines m ON m.machine_id = s.machine_id
  LEFT JOIN shelf_u25 u ON u.machine_id = s.machine_id
  LEFT JOIN mscore ms ON ms.machine_id = s.machine_id
  CROSS JOIN public.pick_urgency_params p;
