-- PRD-122 (lane-grain-priority) T2 / R2 / D2 / D3.
-- Rebuilds s_empty and s_lowfill on v_lane_grain (T1) at lane grain, and adds s_gap,
-- pct_empty_lanes, pct_quasi_lanes, pct_ab_empty_or_quasi, and lane-grain
-- empty_ab_count. shelf_runout/worst_runout/breadth_runout stay on
-- v_shelf_sales_identity at product grain exactly as today (D2 -- two grains coexist
-- deliberately, not collapsed). p_score/urgency/p_tier thresholds are UNTOUCHED in
-- this migration: p_score is still the old GREATEST(...), just now fed by lane-grain
-- s_empty/s_lowfill instead of the diluted product-grain versions (F1a's actual fix).
-- s_gap/pct_* are new exposed diagnostic columns only, not yet score inputs -- that's
-- T3 (R3/D6).
--
-- New columns appended strictly after the existing last column (rank_in_tier) per
-- Postgres's CREATE OR REPLACE VIEW column-order rule; every existing column name,
-- type, and position survives unchanged (R2's explicit requirement).
--
-- Cody: Approve (see the T1-T5 combined review). Article 12 (forward-only
-- CREATE OR REPLACE, no signature change), Article 16 (v_machine_priority remains the
-- one canonical priority object -- edited in place, not duplicated).
--
-- Verified live (view applied, then queried -- a view is non-destructive to iterate
-- on, unlike a data write, so this was verified against the real object rather than
-- a throwaway rolled-back copy): ACTIVATEMCC-1037-0000-L0 now shows s_empty=13.42,
-- empty_ab_count=1 (matches A1's worked example -- was s_empty=0.00, empty_ab_count=0
-- before T1/T2). No machine has a NULL p_score. p_score's formula is confirmed
-- unchanged (still GREATEST of the same 6 arguments) -- VML-1003-0400-O1's new
-- s_gap=31.26 has zero effect on its p_score (still 0.00/P3_OK), confirming s_gap is
-- not yet wired into the score at this step.

CREATE OR REPLACE VIEW public.v_machine_priority AS
WITH v_machine_priority_base AS (
        WITH shelf_u25 AS (
                SELECT vls.machine_id,
                   count(*) FILTER (WHERE vls.is_enabled AND vls.current_stock > 0 AND vls.fill_pct < 25) AS under25
                  FROM v_live_shelf_stock vls
                 GROUP BY vls.machine_id
               ), shelf_graded AS (
                SELECT i.machine_id,
                       CASE
                           WHEN i.dvel >= pp.a_floor THEN 'A'::text
                           WHEN i.dvel >= pp.b_floor THEN 'B'::text
                           WHEN i.dvel > 0::numeric THEN 'C'::text
                           ELSE 'D'::text
                       END AS grade,
                   i.dos,
                   i.stock,
                   i.cap,
                       CASE
                           WHEN i.dvel >= pp.a_floor THEN pp.grade_wt_a
                           WHEN i.dvel >= pp.b_floor THEN pp.grade_wt_b
                           WHEN i.dvel > 0::numeric THEN pp.grade_wt_c
                           ELSE 0::numeric
                       END * GREATEST(0::numeric, LEAST(1::numeric, (pp.horizon_days - COALESCE(i.dos, pp.horizon_days)) / pp.horizon_days)) * 100::numeric AS shelf_runout,
                   i.dvel >= pp.a_floor AND i.dos < pp.horizon_days AS a_below,
                   i.dvel >= pp.b_floor AND i.dos < pp.horizon_days AS ab_below
                  FROM v_shelf_sales_identity i
                    CROSS JOIN pick_urgency_params pp
               ), lane_agg AS (
                SELECT lg.machine_id,
                   100.0::numeric * COALESCE(sum(lg.w) FILTER (WHERE lg.is_empty), 0::numeric) / NULLIF(sum(lg.w), 0::numeric) AS s_empty,
                   100.0::numeric * COALESCE(sum(lg.w) FILTER (WHERE lg.is_quasi), 0::numeric) / NULLIF(sum(lg.w), 0::numeric) AS s_lowfill,
                   100.0::numeric * COALESCE(sum(lg.w * (1::numeric - COALESCE(lg.fill_ratio, 0::numeric))), 0::numeric) / NULLIF(sum(lg.w), 0::numeric) AS s_gap,
                   count(*) FILTER (WHERE lg.is_empty AND lg.grade = ANY (ARRAY['A'::text, 'B'::text])) AS empty_ab_count,
                   100.0::numeric * count(*) FILTER (WHERE lg.is_empty) / NULLIF(count(*), 0)::numeric AS pct_empty_lanes,
                   100.0::numeric * count(*) FILTER (WHERE lg.is_quasi) / NULLIF(count(*), 0)::numeric AS pct_quasi_lanes,
                   100.0::numeric * count(*) FILTER (WHERE lg.grade = ANY (ARRAY['A'::text, 'B'::text]) AND (lg.is_empty OR lg.is_quasi)) / NULLIF(count(*) FILTER (WHERE lg.grade = ANY (ARRAY['A'::text, 'B'::text])), 0)::numeric AS pct_ab_empty_or_quasi
                  FROM v_lane_grain lg
                 GROUP BY lg.machine_id
               ), magg AS (
                SELECT shelf_graded.machine_id,
                   count(*) FILTER (WHERE shelf_graded.grade = 'A'::text) AS a_count,
                   count(*) FILTER (WHERE shelf_graded.grade = 'B'::text) AS b_count,
                   count(*) FILTER (WHERE shelf_graded.grade = 'C'::text) AS c_count,
                   count(*) FILTER (WHERE shelf_graded.grade = 'D'::text) AS d_count,
                   min(shelf_graded.dos) FILTER (WHERE shelf_graded.grade = 'A'::text) AS soonest_a_dos,
                   max(shelf_graded.shelf_runout) FILTER (WHERE shelf_graded.grade = ANY (ARRAY['A'::text, 'B'::text, 'C'::text])) AS worst_runout,
                   avg(shelf_graded.shelf_runout) FILTER (WHERE shelf_graded.grade = ANY (ARRAY['A'::text, 'B'::text, 'C'::text])) AS breadth_runout,
                   sum(shelf_graded.stock) FILTER (WHERE shelf_graded.grade = ANY (ARRAY['A'::text, 'B'::text, 'C'::text])) AS abc_stock,
                   sum(shelf_graded.cap) FILTER (WHERE shelf_graded.grade = ANY (ARRAY['A'::text, 'B'::text, 'C'::text])) AS abc_cap,
                   bool_or(shelf_graded.a_below) AS hero_below,
                   bool_or(shelf_graded.ab_below) AS any_ab_below
                  FROM shelf_graded
                 GROUP BY shelf_graded.machine_id
               ), hole_agg AS (
                SELECT h.machine_id,
                   count(*) FILTER (WHERE h.is_hole) AS holes_total,
                   count(*) FILTER (WHERE h.is_hole AND h.grade = 'A'::text) AS holes_a,
                   count(*) FILTER (WHERE h.is_hole AND h.grade = 'B'::text) AS holes_b,
                   count(*) FILTER (WHERE h.is_hole AND h.grade = 'C'::text) AS holes_c,
                   count(*) FILTER (WHERE h.is_hole AND h.grade = 'D'::text) AS holes_d,
                   sum(h.hole_wt) FILTER (WHERE h.is_hole) AS hole_wt_sum
                  FROM v_shelf_holes h
                 GROUP BY h.machine_id
               ), mscore AS (
                SELECT s_1.machine_id,
                   COALESCE(g.worst_runout, 0::numeric) * p_1.runout_worst_wt + COALESCE(g.breadth_runout, 0::numeric) * p_1.runout_breadth_wt AS s_runout,
                   GREATEST(0::numeric, LEAST(100::numeric, (1::numeric - COALESCE(g.abc_stock, 0::numeric) / NULLIF(g.abc_cap, 0::numeric)) * 100::numeric)) AS s_capacity,
                   LEAST(100::numeric, (p_1.expiry_weight_expired * s_1.expired_skus_now::numeric + p_1.expiry_weight_exp3d * s_1.expired_skus_3d::numeric) / p_1.expiry_norm * 100::numeric) AS s_expiry,
                   GREATEST(0::numeric, LEAST(100::numeric, (s_1.days_since_visit::numeric - p_1.stale_grace_days) / NULLIF(p_1.stale_full_days - p_1.stale_grace_days, 0::numeric) * 100::numeric)) AS s_stale,
                   COALESCE(la.s_empty, 0::numeric) AS s_empty,
                   COALESCE(la.s_lowfill, 0::numeric) AS s_lowfill,
                   COALESCE(la.s_gap, 0::numeric) AS s_gap,
                   COALESCE(la.pct_empty_lanes, 0::numeric) AS pct_empty_lanes,
                   COALESCE(la.pct_quasi_lanes, 0::numeric) AS pct_quasi_lanes,
                   COALESCE(la.pct_ab_empty_or_quasi, 0::numeric) AS pct_ab_empty_or_quasi,
                   100::numeric * LEAST(1::numeric, COALESCE(ha.hole_wt_sum, 0::numeric) / NULLIF(p_1.holes_norm, 0::numeric)) AS s_holes,
                   100::numeric * (1::numeric - LEAST(1::numeric, COALESCE(GREATEST(0::numeric, COALESCE(s_1.active_intent_count, 0)::numeric) / NULLIF(p_1.intents_norm, 0::numeric), 1::numeric))) AS s_intents,
                   COALESCE(ha.holes_total, 0::bigint) AS holes_total,
                   COALESCE(ha.holes_a, 0::bigint) AS holes_a,
                   COALESCE(ha.holes_b, 0::bigint) AS holes_b,
                   COALESCE(ha.holes_c, 0::bigint) AS holes_c,
                   COALESCE(ha.holes_d, 0::bigint) AS holes_d,
                   COALESCE(la.empty_ab_count, 0::bigint) AS empty_ab_count,
                   COALESCE(g.hero_below, false) AS hero_below,
                   COALESCE(g.any_ab_below, false) AS any_ab_below,
                   COALESCE(g.a_count, 0::bigint) AS a_count,
                   COALESCE(g.b_count, 0::bigint) AS b_count,
                   COALESCE(g.c_count, 0::bigint) AS c_count,
                   COALESCE(g.d_count, 0::bigint) AS d_count,
                   g.soonest_a_dos
                  FROM v_machine_health_signals s_1
                    LEFT JOIN magg g ON g.machine_id = s_1.machine_id
                    LEFT JOIN hole_agg ha ON ha.machine_id = s_1.machine_id
                    LEFT JOIN lane_agg la ON la.machine_id = s_1.machine_id
                    CROSS JOIN pick_urgency_params p_1
               )
        SELECT s.machine_id,
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
           COALESCE(u.under25, 0::bigint) AS under25,
               CASE
                   WHEN s.venue_group = 'VOX'::text THEN 'vox'::text
                   ELSE 'main'::text
               END AS svc_track,
               CASE
                   WHEN ms.hero_below AND s.days_since_visit::numeric > p.cooldown_days OR s.days_since_visit::numeric > p.stale_override_days OR s.expired_skus_now >= p.p1_expired_min OR ms.empty_ab_count >= p.p1_empty_ab_min OR p.w_holes > 0::numeric AND (ms.holes_a >= 1 OR ms.holes_total >= p.p1_holes_min) OR GREATEST(ms.s_runout, ms.s_empty, ms.s_lowfill, ms.s_expiry, ms.s_stale, ms.s_holes) >= p.p1_threshold THEN 'P1_RESTOCK'::text
                   WHEN s.expired_skus_3d >= p.p2_exp3d_min OR ms.any_ab_below OR p.w_holes > 0::numeric AND ms.holes_total >= p.p2_holes_min OR GREATEST(ms.s_runout, ms.s_empty, ms.s_lowfill, ms.s_expiry, ms.s_stale, ms.s_holes) >= p.p2_threshold THEN 'P2_MAINTAIN'::text
                   ELSE 'P3_OK'::text
               END AS p_tier,
           GREATEST(ms.s_runout, ms.s_empty, ms.s_lowfill, ms.s_expiry, ms.s_stale, ms.s_holes)::numeric(6,2) AS p_score,
           array_remove(ARRAY[
               CASE
                   WHEN ms.hero_below AND s.days_since_visit::numeric > p.cooldown_days THEN 'hero_runout'::text
                   ELSE NULL::text
               END,
               CASE
                   WHEN s.days_since_visit::numeric > p.stale_override_days THEN 'stale_overdue'::text
                   ELSE NULL::text
               END,
               CASE
                   WHEN s.expired_skus_now >= p.p1_expired_min THEN 'expired_now'::text
                   ELSE NULL::text
               END,
               CASE
                   WHEN ms.empty_ab_count >= p.p1_empty_ab_min THEN 'hero_shelf_empty'::text
                   ELSE NULL::text
               END,
               CASE
                   WHEN s.expired_skus_3d >= p.p2_exp3d_min THEN 'expiring_soon'::text
                   ELSE NULL::text
               END,
               CASE
                   WHEN ms.any_ab_below THEN 'seller_below_horizon'::text
                   ELSE NULL::text
               END,
               CASE
                   WHEN ms.s_empty > 0::numeric THEN 'empty_shelves'::text
                   ELSE NULL::text
               END,
               CASE
                   WHEN ms.s_lowfill >= 20::numeric THEN 'low_fill_sellers'::text
                   ELSE NULL::text
               END,
               CASE
                   WHEN p.w_holes > 0::numeric AND ms.holes_a >= 1 THEN 'empty_hero_row'::text
                   ELSE NULL::text
               END,
               CASE
                   WHEN p.w_holes > 0::numeric AND ms.holes_total >= p.p1_holes_min THEN 'empty_rows_2plus'::text
                   ELSE NULL::text
               END,
               CASE
                   WHEN p.w_holes > 0::numeric AND ms.holes_total >= p.p2_holes_min THEN 'hole_row'::text
                   ELSE NULL::text
               END,
               CASE
                   WHEN GREATEST(ms.s_runout, ms.s_empty, ms.s_lowfill, ms.s_expiry, ms.s_stale, ms.s_holes) >= p.p1_threshold THEN 'high_urgency'::text
                   ELSE NULL::text
               END,
               CASE
                   WHEN ms.s_capacity >= 50::numeric THEN 'low_capacity'::text
                   ELSE NULL::text
               END], NULL::text) AS reasons_arr,
           COALESCE(s.venue_group, s.building_id, s.official_name) AS r_cluster,
           GREATEST(ms.s_runout, ms.s_empty, ms.s_lowfill, ms.s_expiry, ms.s_stale, ms.s_holes)::numeric(6,2) AS urgency,
           round(ms.soonest_a_dos, 2) AS soonest_a_dos,
           ms.a_count AS grade_a_count,
           ms.b_count AS grade_b_count,
           ms.c_count AS grade_c_count,
           ms.d_count AS grade_d_count,
           ms.s_empty::numeric(6,2) AS s_empty,
           ms.s_lowfill::numeric(6,2) AS s_lowfill,
           ms.empty_ab_count,
           ms.s_runout::numeric(6,2) AS s_runout,
           ms.s_capacity::numeric(6,2) AS s_capacity,
           ms.s_expiry::numeric(6,2) AS s_expiry,
           ms.s_stale::numeric(6,2) AS s_stale,
           ms.s_holes::numeric(6,2) AS s_holes,
           ms.holes_total,
           ms.holes_a,
           ms.holes_b,
           ms.holes_c,
           ms.holes_d,
           ms.s_intents::numeric(6,2) AS s_intents,
           ms.s_gap::numeric(6,2) AS s_gap,
           ms.pct_empty_lanes::numeric(6,2) AS pct_empty_lanes,
           ms.pct_quasi_lanes::numeric(6,2) AS pct_quasi_lanes,
           ms.pct_ab_empty_or_quasi::numeric(6,2) AS pct_ab_empty_or_quasi
          FROM v_machine_health_signals s
            JOIN machines m ON m.machine_id = s.machine_id
            LEFT JOIN shelf_u25 u ON u.machine_id = s.machine_id
            LEFT JOIN mscore ms ON ms.machine_id = s.machine_id
            CROSS JOIN pick_urgency_params p
       )
 SELECT machine_id,
    official_name,
    venue_group,
    location_type,
    building_id,
    dead_slot_pct,
    empty_shelf_pct,
    fill_pct,
    hero_slot_count,
    expired_skus_now,
    expired_skus_30d,
    days_since_visit,
    units_last_7d,
    is_ramping,
    active_intent_count,
    tier,
    empty_shelves_count,
    cur_stock,
    expired_skus_3d,
    expired_skus_7d,
    runway_days,
    include_in_refill,
    machine_status,
    under25,
    svc_track,
    p_tier,
    p_score,
    reasons_arr,
    r_cluster,
    urgency,
    soonest_a_dos,
    grade_a_count,
    grade_b_count,
    grade_c_count,
    grade_d_count,
    s_empty,
    s_lowfill,
    empty_ab_count,
    s_runout,
    s_capacity,
    s_expiry,
    s_stale,
    s_holes,
    holes_total,
    holes_a,
    holes_b,
    holes_c,
    holes_d,
    s_intents,
    row_number() OVER (PARTITION BY p_tier ORDER BY units_last_7d DESC) AS rank_in_tier,
    s_gap,
    pct_empty_lanes,
    pct_quasi_lanes,
    pct_ab_empty_or_quasi
   FROM v_machine_priority_base;
