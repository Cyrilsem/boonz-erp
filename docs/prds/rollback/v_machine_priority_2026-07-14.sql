-- Rollback for PRD-100: live v_machine_priority body as of 2026-07-14
-- (PRD-063 urgency rewrite + PRD-073b s_empty/s_lowfill + PRD-075 s_* exposure).
CREATE OR REPLACE VIEW public.v_machine_priority AS
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
            i.dvel >= pp.b_floor AND i.dos < pp.horizon_days AS ab_below,
            i.stock = 0 AS is_empty,
            COALESCE(i.stock > 0 AND (i.stock::numeric / NULLIF(i.cap, 0)::numeric * 100::numeric) < pp.low_fill_pct_floor, false) AS is_low,
                CASE
                    WHEN i.dvel >= pp.a_floor THEN pp.empty_wt_a
                    WHEN i.dvel >= pp.b_floor THEN pp.empty_wt_b
                    WHEN i.dvel > 0::numeric THEN pp.empty_wt_c
                    ELSE pp.empty_wt_d
                END AS empty_grade_mult
           FROM v_shelf_sales_identity i
             CROSS JOIN pick_urgency_params pp
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
            bool_or(shelf_graded.ab_below) AS any_ab_below,
            count(*) AS graded_shelves,
            sum(shelf_graded.empty_grade_mult) FILTER (WHERE shelf_graded.is_empty) AS empty_mult_sum,
            sum(shelf_graded.empty_grade_mult) FILTER (WHERE shelf_graded.is_low) AS low_mult_sum,
            count(*) FILTER (WHERE shelf_graded.is_empty AND (shelf_graded.grade = ANY (ARRAY['A'::text, 'B'::text]))) AS empty_ab_count
           FROM shelf_graded
          GROUP BY shelf_graded.machine_id
        ), mscore AS (
         SELECT s_1.machine_id,
            COALESCE(g.worst_runout, 0::numeric) * p_1.runout_worst_wt + COALESCE(g.breadth_runout, 0::numeric) * p_1.runout_breadth_wt AS s_runout,
            GREATEST(0::numeric, LEAST(100::numeric, (1::numeric - COALESCE(g.abc_stock, 0::numeric) / NULLIF(g.abc_cap, 0::numeric)) * 100::numeric)) AS s_capacity,
            LEAST(100::numeric, (p_1.expiry_weight_expired * s_1.expired_skus_now::numeric + p_1.expiry_weight_exp3d * s_1.expired_skus_3d::numeric) / p_1.expiry_norm * 100::numeric) AS s_expiry,
            GREATEST(0::numeric, LEAST(100::numeric, (s_1.days_since_visit::numeric - p_1.stale_grace_days) / NULLIF(p_1.stale_full_days - p_1.stale_grace_days, 0::numeric) * 100::numeric)) AS s_stale,
            100::numeric * COALESCE(g.empty_mult_sum, 0::numeric) / GREATEST(g.graded_shelves, 1::bigint)::numeric AS s_empty,
            100::numeric * COALESCE(g.low_mult_sum, 0::numeric) / GREATEST(g.graded_shelves, 1::bigint)::numeric AS s_lowfill,
            COALESCE(g.empty_ab_count, 0::bigint) AS empty_ab_count,
            COALESCE(g.hero_below, false) AS hero_below,
            COALESCE(g.any_ab_below, false) AS any_ab_below,
            COALESCE(g.a_count, 0::bigint) AS a_count,
            COALESCE(g.b_count, 0::bigint) AS b_count,
            COALESCE(g.c_count, 0::bigint) AS c_count,
            COALESCE(g.d_count, 0::bigint) AS d_count,
            g.soonest_a_dos
           FROM v_machine_health_signals s_1
             LEFT JOIN magg g ON g.machine_id = s_1.machine_id
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
            WHEN ms.hero_below AND s.days_since_visit::numeric > p.cooldown_days OR s.days_since_visit::numeric > p.stale_override_days OR s.expired_skus_now >= p.p1_expired_min OR ms.empty_ab_count >= p.p1_empty_ab_min OR (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill) >= p.p1_threshold THEN 'P1_RESTOCK'::text
            WHEN s.expired_skus_3d >= p.p2_exp3d_min OR ms.any_ab_below OR (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill) >= p.p2_threshold THEN 'P2_MAINTAIN'::text
            ELSE 'P3_OK'::text
        END AS p_tier,
    (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill)::numeric(6,2) AS p_score,
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
            WHEN (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill) >= p.p1_threshold THEN 'high_urgency'::text
            ELSE NULL::text
        END,
        CASE
            WHEN ms.s_capacity >= 50::numeric THEN 'low_capacity'::text
            ELSE NULL::text
        END], NULL::text) AS reasons_arr,
    COALESCE(s.venue_group, s.building_id, s.official_name) AS r_cluster,
    (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill)::numeric(6,2) AS urgency,
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
    ms.s_stale::numeric(6,2) AS s_stale
   FROM v_machine_health_signals s
     JOIN machines m ON m.machine_id = s.machine_id
     LEFT JOIN shelf_u25 u ON u.machine_id = s.machine_id
     LEFT JOIN mscore ms ON ms.machine_id = s.machine_id
     CROSS JOIN pick_urgency_params p;
