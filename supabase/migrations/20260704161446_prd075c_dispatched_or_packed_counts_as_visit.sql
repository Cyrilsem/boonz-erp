-- PRD-075 follow-up 2 (CS ruling 2026-07-05): a refill log that reached dispatched or packed state
-- counts as a visit. Broadens last_visit CTE condition from (picked_up OR returned OR (dispatched AND packed))
-- to (picked_up OR returned OR dispatched OR packed). Approved-only plans still NEVER count.
-- Dry-run: fleet impact = 1 machine (ALHQ-1016, gains an old 2026-02-20 visit date). Everything else identical.
CREATE OR REPLACE VIEW v_machine_health_signals AS
 WITH base AS (
         SELECT m.machine_id, m.official_name, m.venue_group, m.location_type, m.building_id, m.relaunched_at
           FROM machines m
          WHERE m.include_in_refill = true AND m.status = 'Active'::text
        ), slot_health AS (
         SELECT b_1.machine_id,
            count(sl.machine_id)::numeric AS total_slots,
            count(*) FILTER (WHERE sl.signal = ANY (ARRAY['DEAD — SWAP NOW'::text, 'WIND DOWN'::text, 'ROTATE OUT'::text]))::numeric AS bad_slots,
            count(*) FILTER (WHERE sl.signal = 'HERO'::text)::integer AS hero_slots
           FROM base b_1
             LEFT JOIN slot_lifecycle sl ON sl.machine_id = b_1.machine_id AND sl.archived = false AND sl.is_current = true
          GROUP BY b_1.machine_id
        ), shelf_state AS (
         SELECT b_1.machine_id,
            count(vls.machine_id)::numeric AS shelf_count,
            count(*) FILTER (WHERE vls.current_stock = 0)::integer AS empty_count,
            sum(vls.current_stock)::integer AS cur_stock,
            sum(vls.max_stock)::integer AS max_cap
           FROM base b_1
             LEFT JOIN v_live_shelf_stock vls ON vls.machine_id = b_1.machine_id
          GROUP BY b_1.machine_id
        ), expiry_state AS (
         SELECT b_1.machine_id,
            COALESCE(ex_1.expired_skus_now, 0) AS expired_skus_now,
            COALESCE(ex_1.expiring_skus_3d, 0) AS expired_skus_3d,
            COALESCE(ex_1.expiring_skus_7d, 0) AS expired_skus_7d,
            COALESCE(ex_1.expiring_skus_30d, 0) AS expired_skus_30d
           FROM base b_1
             LEFT JOIN v_machine_expiry_summary ex_1 ON ex_1.machine_id = b_1.machine_id
        ), last_visit AS (
         SELECT b_1.machine_id,
            max(rd.dispatch_date) AS last_visit_date
           FROM base b_1
             LEFT JOIN refill_dispatching rd ON rd.machine_id = b_1.machine_id AND rd.cancelled = false AND rd.skipped = false AND (rd.picked_up = true OR rd.returned = true OR rd.dispatched = true OR rd.packed = true)
          GROUP BY b_1.machine_id
        ), manual_refill_visit AS (
         SELECT b_1.machine_id,
            max(pal.created_at::date) AS last_manual_refill_date
           FROM base b_1
             LEFT JOIN pod_inventory_audit_log pal ON pal.machine_id = b_1.machine_id AND (pal.reference_id ~~ 'manual-refill-%'::text OR pal.reference_id ~~ 'adjust-%'::text)
          GROUP BY b_1.machine_id
        ), sales_recent AS (
         SELECT b_1.machine_id,
            COALESCE(vv.units_7d, 0) AS units_last_7d
           FROM base b_1
             LEFT JOIN v_machine_velocity vv ON vv.machine_id = b_1.machine_id
        ), ramping AS (
         SELECT b_1.machine_id,
                CASE
                    WHEN b_1.relaunched_at IS NOT NULL AND b_1.relaunched_at > (now() - '14 days'::interval) THEN true
                    WHEN (( SELECT vmfs.first_sale_at
                       FROM v_machine_first_sale vmfs
                      WHERE vmfs.machine_id = b_1.machine_id)) > (now() - '14 days'::interval) THEN true
                    ELSE false
                END AS is_ramping
           FROM base b_1
        ), intent_state AS (
         SELECT b_1.machine_id,
            count(DISTINCT si.intent_id)::integer AS active_intent_count
           FROM base b_1
             JOIN slot_lifecycle sl ON sl.machine_id = b_1.machine_id AND sl.archived = false AND sl.is_current = true
             JOIN strategic_intents si ON (si.status = ANY (ARRAY['queued'::text, 'in_progress'::text])) AND si.scope_pod_product_id = sl.pod_product_id AND (si.scope_machine_ids IS NULL OR (b_1.machine_id = ANY (si.scope_machine_ids)))
          GROUP BY b_1.machine_id
        )
 SELECT b.machine_id,
    b.official_name,
    b.venue_group,
    b.location_type,
    b.building_id,
    round(
        CASE
            WHEN sh.total_slots > 0::numeric THEN sh.bad_slots * 100.0 / sh.total_slots
            ELSE 0::numeric
        END, 2) AS dead_slot_pct,
    round(
        CASE
            WHEN ss.shelf_count > 0::numeric THEN ss.empty_count::numeric * 100.0 / ss.shelf_count
            ELSE 0::numeric
        END, 2) AS empty_shelf_pct,
    round(
        CASE
            WHEN ss.max_cap > 0 THEN ss.cur_stock::numeric * 100.0 / ss.max_cap::numeric
            ELSE 0::numeric
        END, 2) AS fill_pct,
    COALESCE(sh.hero_slots, 0) AS hero_slot_count,
    COALESCE(ex.expired_skus_now, 0) AS expired_skus_now,
    COALESCE(ex.expired_skus_30d, 0) AS expired_skus_30d,
        CASE
            WHEN GREATEST(lv.last_visit_date, mrv.last_manual_refill_date) IS NULL THEN 365
            ELSE LEAST(GREATEST(CURRENT_DATE - GREATEST(lv.last_visit_date, mrv.last_manual_refill_date), 0), 365)
        END AS days_since_visit,
    COALESCE(sr.units_last_7d, 0) AS units_last_7d,
    rmp.is_ramping,
    COALESCE(int_.active_intent_count, 0) AS active_intent_count,
        CASE
            WHEN rmp.is_ramping THEN 'ramping'::text
            WHEN COALESCE(ex.expired_skus_now, 0) > 0 THEN 'at_risk'::text
            WHEN sh.total_slots > 0::numeric AND (sh.bad_slots * 1.0 / sh.total_slots) >= 0.50 AND COALESCE(sr.units_last_7d, 0) < 5 THEN 'zombie'::text
            WHEN COALESCE(sr.units_last_7d, 0) >= 70 THEN 'star'::text
            WHEN sh.total_slots > 0::numeric AND (sh.bad_slots * 1.0 / sh.total_slots) >= 0.30 OR ss.max_cap > 0 AND (ss.cur_stock::numeric * 100.0 / ss.max_cap::numeric) < 50::numeric THEN 'at_risk'::text
            ELSE 'healthy'::text
        END AS tier,
    COALESCE(ss.empty_count, 0) AS empty_shelves_count,
    COALESCE(ss.cur_stock, 0) AS cur_stock,
    COALESCE(ex.expired_skus_3d, 0) AS expired_skus_3d,
    COALESCE(ex.expired_skus_7d, 0) AS expired_skus_7d,
        CASE
            WHEN sr.units_last_7d > 0 AND ss.cur_stock > 0 THEN round(ss.cur_stock::numeric / (sr.units_last_7d::numeric / 7.0), 1)
            ELSE NULL::numeric
        END AS runway_days
   FROM base b
     LEFT JOIN slot_health sh USING (machine_id)
     LEFT JOIN shelf_state ss USING (machine_id)
     LEFT JOIN expiry_state ex USING (machine_id)
     LEFT JOIN last_visit lv USING (machine_id)
     LEFT JOIN manual_refill_visit mrv USING (machine_id)
     LEFT JOIN sales_recent sr USING (machine_id)
     LEFT JOIN ramping rmp USING (machine_id)
     LEFT JOIN intent_state int_ USING (machine_id);
