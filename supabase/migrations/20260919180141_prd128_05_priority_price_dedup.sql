-- PRD-128 step 05: the core fix. v_current_price_filled is not unique per (machine_id,
-- pod_product_id) -- its own fallback tiers can surface several rows for the same pair, and
-- lane_price joined straight onto it fanned every lane out once per duplicate row (v_lane_grain
-- 648/661 rows became ~2174-2302 in lane_price, inflating daily_revenue_aed and every AED
-- score built on it by roughly the same multiple -- see DECISIONS-2026-09-19.md D-002).
--
-- (a) price_by_pod: DISTINCT ON (machine_id, pod_product_id), same shape as the existing
--     price_by_boonz CTE. lane_price now joins this instead of v_current_price_filled
--     directly. This is the whole fix -- everything downstream of lane_price (daily_revenue_aed,
--     s_runout_aed, s_gap_aed, p_score_aed, p_tier_aed) is corrected by construction.
-- (b) lane_agg_aed: floors from pick_urgency_params exclude a lane's contribution to
--     s_gap_aed when its own gap-AED value is below lane_floor_gap_aed, and to s_runout_aed
--     when its own runout-AED value is below lane_floor_runout_aed. daily_revenue_aed keeps
--     every lane, floored or not -- the floor only trims noise out of the two urgency
--     components, never the revenue figure itself. With the defaults (5, 0) this floors gap
--     at 5 AED/day and leaves runout completely unfloored.
--
-- The in_cooldown demotion (CASE WHEN in_cooldown AND p_tier_aed_raw = 'P1' ...) is untouched
-- here -- it is correct as-is; step 08 fixes what feeds days_since_visit into it.
--
-- Every other line is byte-for-byte identical to the pre-PRD-128 body (see
-- 20260919211500_prd128_00_rollback_snapshot.sql).

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
                ), shelf_runout_ranked AS (
                 SELECT sg.machine_id,
                    sg.shelf_runout,
                    row_number() OVER (PARTITION BY sg.machine_id ORDER BY sg.shelf_runout DESC) AS rn
                   FROM shelf_graded sg
                  WHERE sg.grade = ANY (ARRAY['A'::text, 'B'::text, 'C'::text])
                ), lane_agg AS (
                 SELECT lg.machine_id,
                    100.0 * COALESCE(sum(lg.w) FILTER (WHERE lg.is_empty), 0::numeric) / NULLIF(sum(lg.w), 0::numeric) AS s_empty,
                    100.0 * COALESCE(sum(lg.w) FILTER (WHERE lg.is_quasi), 0::numeric) / NULLIF(sum(lg.w), 0::numeric) AS s_lowfill,
                    100.0 * COALESCE(sum(lg.w * (1::numeric - COALESCE(lg.fill_ratio, 0::numeric))), 0::numeric) / NULLIF(sum(lg.w), 0::numeric) AS s_gap,
                    count(*) FILTER (WHERE lg.is_empty AND (lg.grade = ANY (ARRAY['A'::text, 'B'::text]))) AS empty_ab_count,
                    100.0 * count(*) FILTER (WHERE lg.is_empty)::numeric / NULLIF(count(*), 0)::numeric AS pct_empty_lanes,
                    100.0 * count(*) FILTER (WHERE lg.is_quasi)::numeric / NULLIF(count(*), 0)::numeric AS pct_quasi_lanes,
                    100.0 * count(*) FILTER (WHERE (lg.grade = ANY (ARRAY['A'::text, 'B'::text])) AND (lg.is_empty OR lg.is_quasi))::numeric / NULLIF(count(*) FILTER (WHERE lg.grade = ANY (ARRAY['A'::text, 'B'::text])), 0)::numeric AS pct_ab_empty_or_quasi,
                    COALESCE(min(lg.dos) FILTER (WHERE lg.grade = 'A'::text), min(lg.dos) FILTER (WHERE lg.grade = 'B'::text), min(lg.dos) FILTER (WHERE lg.grade = 'C'::text)) AS hero_runway_days
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
                    sum(shelf_graded.stock) FILTER (WHERE shelf_graded.grade = ANY (ARRAY['A'::text, 'B'::text, 'C'::text])) AS abc_stock,
                    sum(shelf_graded.cap) FILTER (WHERE shelf_graded.grade = ANY (ARRAY['A'::text, 'B'::text, 'C'::text])) AS abc_cap,
                    bool_or(shelf_graded.a_below) AS hero_below,
                    bool_or(shelf_graded.ab_below) AS any_ab_below
                   FROM shelf_graded
                  GROUP BY shelf_graded.machine_id
                ), magg_breadth AS (
                 SELECT shelf_runout_ranked.machine_id,
                    avg(shelf_runout_ranked.shelf_runout) FILTER (WHERE shelf_runout_ranked.rn <= 3) AS breadth_runout
                   FROM shelf_runout_ranked
                  GROUP BY shelf_runout_ranked.machine_id
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
                ), price_by_pod AS (
                 SELECT DISTINCT ON (v_current_price_filled.machine_id, v_current_price_filled.pod_product_id) v_current_price_filled.machine_id,
                    v_current_price_filled.pod_product_id,
                    v_current_price_filled.effective_price_aed
                   FROM v_current_price_filled
                  ORDER BY v_current_price_filled.machine_id, v_current_price_filled.pod_product_id, v_current_price_filled.effective_price_aed DESC NULLS LAST
                ), lane_price AS (
                 SELECT lg.machine_id,
                    lg.lane_id,
                    lg.current_stock,
                    lg.max_stock,
                    lg.lane_dvel,
                    pbp.effective_price_aed AS price_aed
                   FROM v_lane_grain lg
                     LEFT JOIN price_by_pod pbp ON pbp.machine_id = lg.machine_id AND pbp.pod_product_id = lg.pod_product_id
                ), lane_agg_aed AS (
                 SELECT lp.machine_id,
                    sum(COALESCE(lp.lane_dvel, 0::numeric) * COALESCE(lp.price_aed, 0::numeric)) AS daily_revenue_aed,
                    sum(COALESCE(lp.lane_dvel, 0::numeric) * COALESCE(lp.price_aed, 0::numeric) * GREATEST(0::numeric, pp.horizon_days - lp.current_stock::numeric / NULLIF(lp.lane_dvel, 0::numeric)))
                      FILTER (WHERE lp.lane_dvel > 0::numeric
                        AND (COALESCE(lp.lane_dvel, 0::numeric) * COALESCE(lp.price_aed, 0::numeric) * GREATEST(0::numeric, pp.horizon_days - lp.current_stock::numeric / NULLIF(lp.lane_dvel, 0::numeric))) >= pp.lane_floor_runout_aed) AS s_runout_aed,
                    sum(GREATEST(lp.max_stock - lp.current_stock, 0)::numeric * COALESCE(lp.price_aed, 0::numeric) * LEAST(1::numeric, lp.lane_dvel / 3.0))
                      FILTER (WHERE lp.lane_dvel >= 1::numeric
                        AND (GREATEST(lp.max_stock - lp.current_stock, 0)::numeric * COALESCE(lp.price_aed, 0::numeric) * LEAST(1::numeric, lp.lane_dvel / 3.0)) >= pp.lane_floor_gap_aed) AS s_gap_aed,
                    bool_or(lp.lane_dvel >= pup.hero_velocity_floor AND (lp.current_stock::numeric / NULLIF(lp.lane_dvel, 0::numeric)) < pp.horizon_days) AS hero_lane_runs_out
                   FROM lane_price lp
                     CROSS JOIN pick_urgency_params pp
                     CROSS JOIN refill_policy_params pup
                  GROUP BY lp.machine_id
                ), price_by_boonz AS (
                 SELECT DISTINCT ON (v_current_price_filled.machine_id, v_current_price_filled.boonz_product_id) v_current_price_filled.machine_id,
                    v_current_price_filled.boonz_product_id,
                    v_current_price_filled.effective_price_aed
                   FROM v_current_price_filled
                  ORDER BY v_current_price_filled.machine_id, v_current_price_filled.boonz_product_id, v_current_price_filled.effective_price_aed DESC NULLS LAST
                ), expiry_agg_aed AS (
                 SELECT pi.machine_id,
                    sum(pi.current_stock * COALESCE(vcf.effective_price_aed, 0::numeric)) FILTER (WHERE pi.expiration_date < CURRENT_DATE) AS expired_value_aed,
                    sum(pi.current_stock * COALESCE(vcf.effective_price_aed, 0::numeric)) FILTER (WHERE pi.expiration_date >= CURRENT_DATE AND pi.expiration_date <= (CURRENT_DATE + 3)) AS expiring3d_value_aed
                   FROM pod_inventory pi
                     LEFT JOIN price_by_boonz vcf ON vcf.machine_id = pi.machine_id AND vcf.boonz_product_id = pi.boonz_product_id
                  WHERE pi.status = 'Active'::text AND pi.expiration_date IS NOT NULL
                  GROUP BY pi.machine_id
                ), mscore AS (
                 SELECT s_1.machine_id,
                    COALESCE(g.worst_runout, 0::numeric) * p_1.runout_worst_wt + COALESCE(gb.breadth_runout, 0::numeric) * p_1.runout_breadth_wt AS s_runout,
                    GREATEST(0::numeric, LEAST(100::numeric, (1::numeric - COALESCE(g.abc_stock, 0::numeric) / NULLIF(g.abc_cap, 0::numeric)) * 100::numeric)) AS s_capacity,
                    LEAST(100::numeric, (p_1.expiry_weight_expired * s_1.expired_skus_now::numeric + p_1.expiry_weight_exp3d * s_1.expired_skus_3d::numeric) / p_1.expiry_norm * 100::numeric) AS s_expiry,
                    GREATEST(0::numeric, LEAST(100::numeric, (s_1.days_since_visit::numeric - p_1.stale_grace_days) / NULLIF(p_1.stale_full_days - p_1.stale_grace_days, 0::numeric) * 100::numeric)) AS s_stale,
                    COALESCE(la.s_empty, 0::numeric) AS s_empty,
                    COALESCE(la.s_lowfill, 0::numeric) AS s_lowfill,
                    COALESCE(la.s_gap, 0::numeric) AS s_gap,
                    COALESCE(la.pct_empty_lanes, 0::numeric) AS pct_empty_lanes,
                    COALESCE(la.pct_quasi_lanes, 0::numeric) AS pct_quasi_lanes,
                    COALESCE(la.pct_ab_empty_or_quasi, 0::numeric) AS pct_ab_empty_or_quasi,
                    la.hero_runway_days,
                    100::numeric * GREATEST(0::numeric, LEAST(1::numeric, (p_1.horizon_days - COALESCE(la.hero_runway_days, p_1.horizon_days)) / p_1.horizon_days)) AS s_runout_hero,
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
                    g.soonest_a_dos,
                    COALESCE(laa.daily_revenue_aed, 0::numeric) AS daily_revenue_aed,
                    COALESCE(laa.s_runout_aed, 0::numeric) AS s_runout_aed,
                    COALESCE(laa.s_gap_aed, 0::numeric) AS s_gap_aed,
                    COALESCE(laa.hero_lane_runs_out, false) AS hero_lane_runs_out,
                    COALESCE(ea.expired_value_aed, 0::numeric) AS expired_value_aed,
                    COALESCE(ea.expiring3d_value_aed, 0::numeric) AS expiring3d_value_aed
                   FROM v_machine_health_signals s_1
                     LEFT JOIN magg g ON g.machine_id = s_1.machine_id
                     LEFT JOIN magg_breadth gb ON gb.machine_id = s_1.machine_id
                     LEFT JOIN hole_agg ha ON ha.machine_id = s_1.machine_id
                     LEFT JOIN lane_agg la ON la.machine_id = s_1.machine_id
                     LEFT JOIN lane_agg_aed laa ON laa.machine_id = s_1.machine_id
                     LEFT JOIN expiry_agg_aed ea ON ea.machine_id = s_1.machine_id
                     CROSS JOIN pick_urgency_params p_1
                ), pscore AS (
                 SELECT mscore.machine_id,
                    round(p_2.w_runout * round(mscore.s_runout_hero, 2), 2) + round(p_2.w_gap * round(mscore.s_gap, 2), 2) + round(p_2.w_holes * round(mscore.s_holes, 2), 2) + round(p_2.w_expiry * round(mscore.s_expiry, 2), 2) + round(p_2.w_stale * round(mscore.s_stale, 2), 2) AS p_score,
                    round(mscore.s_runout_aed, 2) + round(0.5 * mscore.s_gap_aed, 2) + round(2::numeric * mscore.expired_value_aed + 1::numeric * mscore.expiring3d_value_aed, 2) + round(LEAST(mscore.daily_revenue_aed * GREATEST(0, mscore.machine_days_since_visit - 10)::numeric, mscore.daily_revenue_aed), 2) AS p_score_aed
                   FROM ( SELECT mscore_1.machine_id,
                            mscore_1.s_runout,
                            mscore_1.s_capacity,
                            mscore_1.s_expiry,
                            mscore_1.s_stale,
                            mscore_1.s_empty,
                            mscore_1.s_lowfill,
                            mscore_1.s_gap,
                            mscore_1.pct_empty_lanes,
                            mscore_1.pct_quasi_lanes,
                            mscore_1.pct_ab_empty_or_quasi,
                            mscore_1.hero_runway_days,
                            mscore_1.s_runout_hero,
                            mscore_1.s_holes,
                            mscore_1.s_intents,
                            mscore_1.holes_total,
                            mscore_1.holes_a,
                            mscore_1.holes_b,
                            mscore_1.holes_c,
                            mscore_1.holes_d,
                            mscore_1.empty_ab_count,
                            mscore_1.hero_below,
                            mscore_1.any_ab_below,
                            mscore_1.a_count,
                            mscore_1.b_count,
                            mscore_1.c_count,
                            mscore_1.d_count,
                            mscore_1.soonest_a_dos,
                            mscore_1.daily_revenue_aed,
                            mscore_1.s_runout_aed,
                            mscore_1.s_gap_aed,
                            mscore_1.hero_lane_runs_out,
                            mscore_1.expired_value_aed,
                            mscore_1.expiring3d_value_aed,
                            s2.days_since_visit AS machine_days_since_visit
                           FROM mscore mscore_1
                             JOIN v_machine_health_signals s2 ON s2.machine_id = mscore_1.machine_id) mscore
                     CROSS JOIN pick_urgency_params p_2
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
                    WHEN m.service_model = 'partner_filled'::text THEN 'vox'::text
                    ELSE 'main'::text
                END AS svc_track,
                CASE
                    WHEN ms.hero_below AND s.days_since_visit::numeric > p.cooldown_days OR s.days_since_visit::numeric > p.stale_override_days OR s.expired_skus_now >= p.p1_expired_min OR ms.empty_ab_count >= p.p1_empty_ab_min OR p.w_holes > 0::numeric AND (ms.holes_a >= 1 OR ms.holes_total >= p.p1_holes_min) OR COALESCE(ps.p_score, 0::numeric) >= p.p1_threshold OR ms.s_gap >= p.p1_gap_min THEN 'P1_RESTOCK'::text
                    WHEN s.expired_skus_3d >= p.p2_exp3d_min OR ms.any_ab_below OR p.w_holes > 0::numeric AND ms.holes_total >= p.p2_holes_min OR COALESCE(ps.p_score, 0::numeric) >= p.p2_threshold THEN 'P2_MAINTAIN'::text
                    ELSE 'P3_OK'::text
                END AS p_tier,
            COALESCE(ps.p_score, 0::numeric)::numeric(6,2) AS p_score,
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
                    WHEN COALESCE(ps.p_score, 0::numeric) >= p.p1_threshold THEN 'high_urgency'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN ms.s_capacity >= 50::numeric THEN 'low_capacity'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN ms.s_gap >= p.p1_gap_min THEN 'capacity_gap'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN ms.pct_ab_empty_or_quasi >= 25::numeric THEN 'quasi_empty_heavy'::text
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
            ms.pct_ab_empty_or_quasi::numeric(6,2) AS pct_ab_empty_or_quasi,
            round(ms.hero_runway_days, 2) AS hero_runway_days,
            ms.s_runout_hero::numeric(6,2) AS s_runout_hero,
            round(ms.daily_revenue_aed, 2) AS daily_revenue_aed,
            round(ms.s_runout_aed, 2) AS s_runout_aed,
            round(ms.s_gap_aed, 2) AS s_gap_aed,
            round(ms.expired_value_aed * 2::numeric + ms.expiring3d_value_aed, 2) AS expiry_penalty_aed,
            round(LEAST(ms.daily_revenue_aed * GREATEST(0, s.days_since_visit - 10)::numeric, ms.daily_revenue_aed), 2) AS stale_penalty_aed,
            COALESCE(ps.p_score_aed, 0::numeric)::numeric(10,2) AS p_score_aed,
                CASE
                    WHEN s.expired_skus_now > 0 THEN 'P1'::text
                    WHEN s.tier <> 'zombie'::text AND ms.hero_lane_runs_out THEN 'P1'::text
                    WHEN s.tier <> 'zombie'::text AND COALESCE(ps.p_score_aed, 0::numeric) >= p.p1_threshold_aed AND ms.daily_revenue_aed >= (3::numeric * (( SELECT avg(lp2.price_aed) AS avg
                       FROM lane_price lp2
                      WHERE lp2.machine_id = s.machine_id AND lp2.price_aed IS NOT NULL))) THEN 'P1'::text
                    WHEN COALESCE(ps.p_score_aed, 0::numeric) >= p.p2_threshold_aed THEN 'P2'::text
                    WHEN ms.pct_empty_lanes > 0::numeric THEN 'P2'::text
                    WHEN s.days_since_visit >= 14 THEN 'P2'::text
                    ELSE 'P3'::text
                END AS p_tier_aed_raw,
                CASE
                    WHEN s.days_since_visit::numeric <= p.cooldown_days AND s.expired_skus_now = 0 THEN true
                    ELSE false
                END AS in_cooldown
           FROM v_machine_health_signals s
             JOIN machines m ON m.machine_id = s.machine_id
             LEFT JOIN shelf_u25 u ON u.machine_id = s.machine_id
             LEFT JOIN mscore ms ON ms.machine_id = s.machine_id
             LEFT JOIN pscore ps ON ps.machine_id = s.machine_id
             CROSS JOIN pick_urgency_params p
        )
 SELECT machine_id, official_name, venue_group, location_type, building_id, dead_slot_pct,
    empty_shelf_pct, fill_pct, hero_slot_count, expired_skus_now, expired_skus_30d,
    days_since_visit, units_last_7d, is_ramping, active_intent_count, tier,
    empty_shelves_count, cur_stock, expired_skus_3d, expired_skus_7d, runway_days,
    include_in_refill, machine_status, under25, svc_track, p_tier, p_score, reasons_arr,
    r_cluster, urgency, soonest_a_dos, grade_a_count, grade_b_count, grade_c_count,
    grade_d_count, s_empty, s_lowfill, empty_ab_count, s_runout, s_capacity, s_expiry,
    s_stale, s_holes, holes_total, holes_a, holes_b, holes_c, holes_d, s_intents,
    row_number() OVER (PARTITION BY p_tier ORDER BY units_last_7d DESC) AS rank_in_tier,
    s_gap, pct_empty_lanes, pct_quasi_lanes, pct_ab_empty_or_quasi, hero_runway_days,
    s_runout_hero, daily_revenue_aed, s_runout_aed, s_gap_aed, expiry_penalty_aed,
    stale_penalty_aed, p_score_aed,
        CASE
            WHEN in_cooldown AND p_tier_aed_raw = 'P1'::text AND expired_skus_now = 0 THEN 'P2'::text
            ELSE p_tier_aed_raw
        END AS p_tier_aed
   FROM v_machine_priority_base;
