-- PRD-063 ROLLBACK (held; NOT auto-applied — underscore prefix is ignored by the migration runner).
-- Restores v_machine_priority to its pre-PRD-063 body (the PRD-058 machine-level tiering) VERBATIM,
-- captured live from pg_get_viewdef('public.v_machine_priority') on 2026-06-28 before the rewrite.
-- To roll back: apply this body via apply_migration (or copy into a timestamped forward migration).
-- pick_urgency_params and v_shelf_sales_identity are left in place (inert once the view no longer
-- reads them); drop them separately only if a full teardown is wanted.

CREATE OR REPLACE VIEW public.v_machine_priority AS
 WITH shelf_u25 AS (
         SELECT vls.machine_id,
            count(*) FILTER (WHERE vls.is_enabled AND vls.current_stock > 0 AND vls.fill_pct < 25) AS under25
           FROM v_live_shelf_stock vls
          GROUP BY vls.machine_id
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
            WHEN s.units_last_7d > 0 AND (s.empty_shelves_count >= 1 OR s.runway_days IS NOT NULL AND s.runway_days < p.p1_runway_crit OR s.units_last_7d::numeric >= p.p1_strong_units AND s.runway_days IS NOT NULL AND s.runway_days < p.p1_strong_runway OR s.fill_pct < p.p1_fill_pct AND s.units_last_7d::numeric >= p.p1_fill_units OR COALESCE(u.under25, 0::bigint)::numeric >= p.p1_under25_count AND s.units_last_7d::numeric >= p.p1_under25_units OR p.dead_stock_forces_p1 AND s.expired_skus_now::numeric >= p.p1_expired_min_skus) THEN 'P1_RESTOCK'::text
            WHEN s.dead_slot_pct >= p.p2_dead_slot_pct OR s.days_since_visit::numeric >= p.p2_stale_days OR s.active_intent_count > 0 OR s.empty_shelves_count >= 1 AND COALESCE(s.units_last_7d, 0) = 0 THEN 'P2_MAINTAIN'::text
            ELSE 'P3_OK'::text
        END AS p_tier,
    (
        CASE
            WHEN s.empty_shelves_count >= 1 THEN p.w_empty_base + LEAST((s.empty_shelves_count - 1)::numeric * p.w_empty_step, p.w_empty_cap)
            ELSE 0::numeric
        END +
        CASE
            WHEN s.runway_days < 2::numeric THEN p.w_runway_lt2
            WHEN s.units_last_7d::numeric >= p.p1_strong_units AND s.runway_days < p.p1_strong_runway THEN p.w_runway_strong_lt4
            WHEN s.runway_days < p.p1_runway_crit THEN p.w_runway_lt3
            WHEN s.runway_days < 5::numeric AND s.units_last_7d >= 30 THEN p.w_runway_lt5_vel30
            ELSE 0::numeric
        END +
        CASE
            WHEN s.fill_pct < 40::numeric AND s.units_last_7d::numeric >= p.p1_fill_units THEN p.w_fill_lt40_vel20
            WHEN s.fill_pct < p.p1_fill_pct AND s.units_last_7d::numeric >= p.p1_fill_units THEN p.w_fill_lt50_vel20
            WHEN s.fill_pct < 60::numeric AND s.units_last_7d::numeric >= p.p1_strong_units THEN p.w_fill_lt60_vel50
            ELSE 0::numeric
        END +
        CASE
            WHEN s.units_last_7d::numeric >= p.p1_under25_units THEN LEAST(COALESCE(u.under25, 0::bigint)::numeric * p.w_under25_step, p.w_under25_cap)
            ELSE 0::numeric
        END +
        CASE
            WHEN p.dead_stock_forces_p1 AND s.expired_skus_now::numeric >= p.p1_expired_min_skus THEN p.w_expired_now
            ELSE 0::numeric
        END +
        CASE
            WHEN s.units_last_7d::numeric >= p.p1_strong_units THEN p.w_high_velocity
            ELSE 0::numeric
        END +
        CASE
            WHEN s.days_since_visit >= 21 THEN p.w_stale_21
            WHEN s.days_since_visit::numeric >= p.p2_stale_days THEN p.w_stale_14
            WHEN s.days_since_visit >= 10 THEN p.w_stale_10
            ELSE 0::numeric
        END +
        CASE
            WHEN s.dead_slot_pct >= p.p2_dead_slot_pct THEN p.w_dead_slot_30
            WHEN s.dead_slot_pct >= 15::numeric THEN p.w_dead_slot_15
            ELSE 0::numeric
        END +
        CASE
            WHEN s.active_intent_count > 0 THEN p.w_intent
            ELSE 0::numeric
        END)::numeric(6,2) AS p_score,
    array_remove(ARRAY[
        CASE
            WHEN s.empty_shelves_count > 1 THEN 'empty_multi'::text
            ELSE NULL::text
        END,
        CASE
            WHEN s.empty_shelves_count = 1 THEN 'empty_one'::text
            ELSE NULL::text
        END,
        CASE
            WHEN s.runway_days IS NOT NULL AND s.runway_days < 3::numeric THEN 'runway_critical'::text
            ELSE NULL::text
        END,
        CASE
            WHEN s.units_last_7d >= 50 AND s.runway_days IS NOT NULL AND s.runway_days < 4::numeric THEN 'strong_seller_low_runway'::text
            ELSE NULL::text
        END,
        CASE
            WHEN s.fill_pct < 50::numeric AND s.units_last_7d >= 20 THEN 'low_fill'::text
            ELSE NULL::text
        END,
        CASE
            WHEN s.units_last_7d >= 20 AND COALESCE(u.under25, 0::bigint) >= 2 THEN 'shelves_under25'::text
            ELSE NULL::text
        END,
        CASE
            WHEN s.expired_skus_now >= 1 THEN 'expired_now'::text
            ELSE NULL::text
        END,
        CASE
            WHEN s.units_last_7d >= 50 THEN 'high_velocity'::text
            ELSE NULL::text
        END,
        CASE
            WHEN s.dead_slot_pct >= 30::numeric THEN 'dead_slots'::text
            ELSE NULL::text
        END,
        CASE
            WHEN s.days_since_visit >= 14 THEN 'stale'::text
            ELSE NULL::text
        END,
        CASE
            WHEN s.active_intent_count > 0 THEN 'intent'::text
            ELSE NULL::text
        END], NULL::text) AS reasons_arr,
    COALESCE(s.venue_group, s.building_id, s.official_name) AS r_cluster
   FROM v_machine_health_signals s
     JOIN machines m ON m.machine_id = s.machine_id
     LEFT JOIN shelf_u25 u ON u.machine_id = s.machine_id
     CROSS JOIN refill_priority_params p;
