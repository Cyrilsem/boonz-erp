-- PRD-122 (lane-grain-priority) T5 / R5.
-- machines.service_model text NOT NULL DEFAULT 'boonz_filled' CHECK (IN
-- ('boonz_filled','partner_filled')), backfilled 'partner_filled' for exactly the 3
-- -V0 machines named in F1c (VOXMM-1001-0100-V0, VOXMCC-1012-0100-V0,
-- VOXMCC-1017-0200-V0), everything else defaults 'boonz_filled'.
--
-- v_machine_priority's svc_track now keys on m.service_model instead of
-- venue_group='VOX' -- this is the actual fix for 1c: venue_group records who OWNS
-- the venue (the landlord), not who physically refills the machine. The 8
-- Boonz-filled machines that venue_group was wrongly demoting (ACTIVATEMCC-1037,
-- ACTIVATE-2005, IFLYMCC-1024, MPMCC-1054, MPMCC-1058, VOXMCC-1005, VOXMCC-1011,
-- VOXMM-1013 -- all venue_group='VOX' but service_model='boonz_filled' by default)
-- now correctly show svc_track='main'.
--
-- get_machine_health's fallback simplifies to COALESCE(mp.svc_track, 'main') per R5's
-- literal text.
--
-- One follow-up fix, found by check_priority_surface_consistency itself doing its
-- job: R3b's stated premise for leaving the consistency check's service_track row
-- alone ("mp.svc_track is non-null for every machine carrying a priority row") turns
-- out to be false for exactly the 3 -V0 machines -- they have ZERO rows in
-- v_machine_priority at all (not just a null svc_track), because they don't appear
-- in v_machine_health_signals' base set. get_machine_health still produces a row for
-- them (its own base is weimi_device_status), so once its fallback simplified to a
-- literal 'main', it started disagreeing with check_priority_surface_consistency's
-- still-old venue_group-based canonical fallback for these 3. Fixed by updating that
-- one row's canonical to match: COALESCE(mp.svc_track, 'main'). This is a genuine
-- T5-introduced discrepancy, not a violation of R3b's "leave alone" (which was scoped
-- to T3's chip-shape realignment, not T5's later svc_track source change).
--
-- Cody: Approve (see the T1-T5 combined review, plus this follow-up fix). Article 2
-- (machines already RLS'd, unaffected by adding a column), Article 12 (forward-only
-- additive ALTER + new CHECK constraint, CREATE OR REPLACE on the two functions/view,
-- no signature changes). Out of scope respected: include_in_refill is untouched for
-- all three -V0 machines (still false before and after).
--
-- Verified live: exactly the 3 named -V0 machines backfilled to 'partner_filled'
-- (confirmed by direct query, zero others touched). All 8 previously-demoted
-- Boonz-filled machines now show svc_track='main' despite venue_group='VOX'.
-- check_priority_surface_consistency() returns 0 rows again after the follow-up fix
-- (A11 still holds).

ALTER TABLE public.machines
  ADD COLUMN service_model text NOT NULL DEFAULT 'boonz_filled'
  CHECK (service_model IN ('boonz_filled','partner_filled'));

UPDATE public.machines
SET service_model = 'partner_filled'
WHERE official_name IN ('VOXMM-1001-0100-V0','VOXMCC-1012-0100-V0','VOXMCC-1017-0200-V0');

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
                   100.0::numeric * COALESCE(sum(lg.w) FILTER (WHERE lg.is_empty), 0::numeric) / NULLIF(sum(lg.w), 0::numeric) AS s_empty,
                   100.0::numeric * COALESCE(sum(lg.w) FILTER (WHERE lg.is_quasi), 0::numeric) / NULLIF(sum(lg.w), 0::numeric) AS s_lowfill,
                   100.0::numeric * COALESCE(sum(lg.w * (1::numeric - COALESCE(lg.fill_ratio, 0::numeric))), 0::numeric) / NULLIF(sum(lg.w), 0::numeric) AS s_gap,
                   count(*) FILTER (WHERE lg.is_empty AND lg.grade = ANY (ARRAY['A'::text, 'B'::text])) AS empty_ab_count,
                   100.0::numeric * count(*) FILTER (WHERE lg.is_empty) / NULLIF(count(*), 0)::numeric AS pct_empty_lanes,
                   100.0::numeric * count(*) FILTER (WHERE lg.is_quasi) / NULLIF(count(*), 0)::numeric AS pct_quasi_lanes,
                   100.0::numeric * count(*) FILTER (WHERE lg.grade = ANY (ARRAY['A'::text, 'B'::text]) AND (lg.is_empty OR lg.is_quasi)) / NULLIF(count(*) FILTER (WHERE lg.grade = ANY (ARRAY['A'::text, 'B'::text])), 0)::numeric AS pct_ab_empty_or_quasi,
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
                   la.hero_runway_days AS hero_runway_days,
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
                   g.soonest_a_dos
                  FROM v_machine_health_signals s_1
                    LEFT JOIN magg g ON g.machine_id = s_1.machine_id
                    LEFT JOIN magg_breadth gb ON gb.machine_id = s_1.machine_id
                    LEFT JOIN hole_agg ha ON ha.machine_id = s_1.machine_id
                    LEFT JOIN lane_agg la ON la.machine_id = s_1.machine_id
                    CROSS JOIN pick_urgency_params p_1
               ), pscore AS (
                SELECT mscore.machine_id,
                   round(p_2.w_runout * round(mscore.s_runout_hero, 2), 2)
                 + round(p_2.w_gap * round(mscore.s_gap, 2), 2)
                 + round(p_2.w_holes * round(mscore.s_holes, 2), 2)
                 + round(p_2.w_expiry * round(mscore.s_expiry, 2), 2)
                 + round(p_2.w_stale * round(mscore.s_stale, 2), 2) AS p_score
                  FROM mscore
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
           ms.s_runout_hero::numeric(6,2) AS s_runout_hero
          FROM v_machine_health_signals s
            JOIN machines m ON m.machine_id = s.machine_id
            LEFT JOIN shelf_u25 u ON u.machine_id = s.machine_id
            LEFT JOIN mscore ms ON ms.machine_id = s.machine_id
            LEFT JOIN pscore ps ON ps.machine_id = s.machine_id
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
    pct_ab_empty_or_quasi,
    hero_runway_days,
    s_runout_hero
   FROM v_machine_priority_base;

CREATE OR REPLACE FUNCTION public.get_machine_health()
 RETURNS TABLE(machine_name text, machine_id uuid, is_online boolean, total_stock integer, max_capacity integer, fill_pct numeric, total_slots integer, slots_at_zero integer, slots_below_25pct integer, daily_velocity numeric, days_until_empty numeric, has_sensor_errors boolean, machine_status text, include_in_refill boolean, recently_offline boolean, expired_units integer, expiring_7d_units integer, expiring_30d_units integer, days_to_earliest_expiry integer, machine_health_label text, machine_strategy text, machine_days_active integer, dead_stock_count integer, local_hero_count integer, health_tier text, health_sort integer, days_since_visit integer, pending_swap_count integer, is_picked_tomorrow boolean, picker_reasons text[], service_track text, priority_tier text, priority_score numeric, last_plan_date date, last_plan_days integer, urgency_breakdown jsonb, reasons_arr text[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH device_metrics AS (
    SELECT
      ds.device_name, ds.machine_id,
      m.status as machine_status,
      m.venue_group as venue_grp,
      COALESCE(m.include_in_refill, true) as include_in_refill,
      GREATEST(ds.total_curr_stock, 0) as total_stock,
      (SELECT COALESCE(SUM(GREATEST((a->>'maxStock')::int,0)),0) FROM jsonb_array_elements(ds.door_statuses) cab, jsonb_array_elements(cab->'layers') lyr, jsonb_array_elements(lyr->'aisles') a) as max_capacity,
      (SELECT COUNT(*)::int FROM jsonb_array_elements(ds.door_statuses) cab, jsonb_array_elements(cab->'layers') lyr, jsonb_array_elements(lyr->'aisles') a) as total_slots,
      (SELECT COUNT(*)::int FROM jsonb_array_elements(ds.door_statuses) cab, jsonb_array_elements(cab->'layers') lyr, jsonb_array_elements(lyr->'aisles') a WHERE (a->>'currStock')::int <= 0) as slots_at_zero,
      (SELECT COUNT(*)::int FROM jsonb_array_elements(ds.door_statuses) cab, jsonb_array_elements(cab->'layers') lyr, jsonb_array_elements(lyr->'aisles') a WHERE (a->>'currStock')::int > 0 AND (a->>'currStock')::numeric / NULLIF((a->>'maxStock')::numeric,0) <= 0.25) as slots_below_25pct,
      (SELECT COUNT(*)::int > 0 FROM jsonb_array_elements(ds.door_statuses) cab, jsonb_array_elements(cab->'layers') lyr, jsonb_array_elements(lyr->'aisles') a WHERE (a->>'currStock')::int < 0) as has_sensor_errors,
      (SELECT array_agg(DISTINCT lower(TRIM(a->>'goodsName')))
       FROM jsonb_array_elements(ds.door_statuses) cab, jsonb_array_elements(cab->'layers') lyr, jsonb_array_elements(lyr->'aisles') a
       WHERE a->>'goodsName' IS NOT NULL AND TRIM(a->>'goodsName') != '') as current_products
    FROM weimi_device_status ds
    LEFT JOIN machines m ON m.machine_id = ds.machine_id
    WHERE ds.snapshot_date = (SELECT MAX(snapshot_date) FROM weimi_device_status)
      AND ds.device_name IS NOT NULL
  ),
  with_velocity AS (
    SELECT dm.*,
      COALESCE((SELECT vv.daily_velocity_7d FROM public.v_machine_velocity vv WHERE vv.machine_id = dm.machine_id), 0) as daily_velocity,
      COALESCE((SELECT SUM(sh.paid_amount) / NULLIF(GREATEST(EXTRACT(EPOCH FROM (NOW() - MIN(sh.transaction_date))) / 86400, 1), 0)
        FROM sales_history sh WHERE sh.machine_id = dm.machine_id AND sh.delivery_status IN ('Success','Successful') AND sh.transaction_date >= NOW() - interval '60 days'), 0) as daily_revenue,
      (SELECT EXTRACT(DAY FROM NOW() - vfs.first_sale_at)::int
       FROM v_machine_first_sale vfs
       WHERE vfs.machine_id = dm.machine_id) as days_active,
      (SELECT COUNT(*)::int FROM (
        SELECT sh_ds.pod_product_id as norm_product,
          COALESCE(SUM(sh_ds.qty) FILTER (WHERE sh_ds.transaction_date >= NOW() - interval '7 days'), 0) * 4
          + COALESCE(SUM(sh_ds.qty) FILTER (WHERE sh_ds.transaction_date >= NOW() - interval '15 days'), 0) * 0.5 as bs
        FROM public.v_sales_history_resolved sh_ds
        WHERE sh_ds.machine_id = dm.machine_id
          AND sh_ds.delivery_status IN ('Success','Successful')
          AND sh_ds.pod_product_id IN (SELECT pp_ds.pod_product_id FROM public.pod_products pp_ds WHERE lower(TRIM(pp_ds.pod_product_name)) = ANY(dm.current_products))
        GROUP BY sh_ds.pod_product_id
        HAVING COALESCE(SUM(sh_ds.qty) FILTER (WHERE sh_ds.transaction_date >= NOW() - interval '7 days'), 0) * 4
             + COALESCE(SUM(sh_ds.qty) FILTER (WHERE sh_ds.transaction_date >= NOW() - interval '15 days'), 0) * 0.5 = 0
      ) x) as dead_stock_count,
      (SELECT COUNT(*)::int FROM (
        SELECT sh_lh.pod_product_id as norm_product,
          COALESCE(SUM(sh_lh.qty) FILTER (WHERE sh_lh.transaction_date >= NOW() - interval '7 days'), 0) * 4
          + COALESCE(SUM(sh_lh.qty) FILTER (WHERE sh_lh.transaction_date >= NOW() - interval '15 days'), 0) * 0.5 as bs
        FROM public.v_sales_history_resolved sh_lh
        WHERE sh_lh.machine_id = dm.machine_id
          AND sh_lh.delivery_status IN ('Success','Successful')
          AND sh_lh.pod_product_id IN (SELECT pp_lh.pod_product_id FROM public.pod_products pp_lh WHERE lower(TRIM(pp_lh.pod_product_name)) = ANY(dm.current_products))
        GROUP BY sh_lh.pod_product_id
        HAVING COALESCE(SUM(sh_lh.qty) FILTER (WHERE sh_lh.transaction_date >= NOW() - interval '7 days'), 0) * 4
             + COALESCE(SUM(sh_lh.qty) FILTER (WHERE sh_lh.transaction_date >= NOW() - interval '15 days'), 0) * 0.5 > 5
      ) x) as local_hero_count
    FROM device_metrics dm
  ),
  with_expiry AS (
    SELECT wv.*,
      COALESCE(ex.expired_units, 0) as expired_units,
      COALESCE(ex.expiring_7d_units, 0) as expiring_7d_units,
      COALESCE(ex.expiring_30d_units, 0) as expiring_30d_units,
      ex.days_to_earliest as days_to_earliest_expiry
    FROM with_velocity wv
    LEFT JOIN v_machine_expiry_summary ex ON ex.machine_id = wv.machine_id
  ),
  swap_data AS (
    SELECT ps.machine_name, COUNT(*)::int as swap_count
    FROM planned_swaps ps
    WHERE ps.status = 'pending'
    GROUP BY ps.machine_name
  ),
  picker_data AS (
    SELECT mtv.machine_id, mtv.picked_reasons
    FROM machines_to_visit mtv
    WHERE mtv.plan_date = public.resolve_refill_plan_date()
      AND mtv.status IN ('picked','cs_added')
  )
  SELECT
    we.device_name, we.machine_id, true as is_online,
    we.total_stock, we.max_capacity,
    CASE WHEN we.max_capacity > 0 THEN ROUND((GREATEST(we.total_stock,0)::numeric / we.max_capacity)*100, 1) ELSE 0 END,
    we.total_slots, we.slots_at_zero, we.slots_below_25pct,
    ROUND(we.daily_velocity, 1),
    CASE WHEN we.daily_velocity > 0 THEN ROUND(GREATEST(we.total_stock,0)::numeric / we.daily_velocity, 1) ELSE 999 END,
    we.has_sensor_errors,
    COALESCE(we.machine_status, 'Active'),
    we.include_in_refill,
    false as recently_offline,
    we.expired_units, we.expiring_7d_units, we.expiring_30d_units, we.days_to_earliest_expiry,
    CASE WHEN we.days_active IS NOT NULL AND we.days_active < 30 THEN '🟦 Ramp-Up Performer'
      ELSE compute_machine_health_label(ROUND(we.daily_revenue::numeric, 1)) END,
    CASE WHEN we.days_active IS NOT NULL AND we.days_active < 30 THEN 'Maintain Visual Standards'
      ELSE compute_machine_strategy(ROUND(we.daily_revenue::numeric, 1)) END,
    we.days_active,
    COALESCE(we.dead_stock_count, 0),
    COALESCE(we.local_hero_count, 0),
    CASE
      WHEN NOT we.include_in_refill THEN 'excluded'
      WHEN COALESCE(we.machine_status,'Active') IN ('Warehouse','Inactive') THEN 'excluded'
      WHEN we.expired_units > 0 THEN 'critical'
      WHEN we.slots_at_zero > 0 THEN 'critical'
      WHEN we.max_capacity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.max_capacity) < 0.30 THEN 'critical'
      WHEN we.daily_velocity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.daily_velocity) < 2 THEN 'critical'
      WHEN we.expiring_7d_units > 0 THEN 'warning'
      WHEN we.max_capacity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.max_capacity) < 0.60 THEN 'warning'
      WHEN we.slots_below_25pct >= 2 THEN 'warning'
      WHEN we.daily_velocity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.daily_velocity) < 5 THEN 'warning'
      ELSE 'healthy'
    END,
    CASE
      WHEN NOT we.include_in_refill THEN 5
      WHEN COALESCE(we.machine_status,'Active') IN ('Warehouse','Inactive') THEN 5
      WHEN we.expired_units > 0 THEN 1
      WHEN we.slots_at_zero > 0 THEN 1
      WHEN we.max_capacity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.max_capacity) < 0.30 THEN 1
      WHEN we.daily_velocity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.daily_velocity) < 2 THEN 1
      WHEN we.expiring_7d_units > 0 THEN 2
      WHEN we.max_capacity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.max_capacity) < 0.60 THEN 2
      WHEN we.slots_below_25pct >= 2 THEN 2
      WHEN we.daily_velocity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.daily_velocity) < 5 THEN 2
      ELSE 3
    END,
    COALESCE(hs.days_since_visit, -1)::int,
    COALESCE(sd.swap_count, 0),
    pd.machine_id IS NOT NULL,
    pd.picked_reasons,
    COALESCE(mp.svc_track, 'main'),
    CASE
      WHEN NOT we.include_in_refill OR COALESCE(we.machine_status,'Active') IN ('Warehouse','Inactive')
        THEN 'excluded'
      WHEN mp.p_tier = 'P3_OK' OR mp.p_tier IS NULL THEN 'skip'
      ELSE mp.p_tier
    END,
    COALESCE(mp.p_score, 0),
    CASE WHEN hs.days_since_visit IS NULL OR hs.days_since_visit < 0 THEN NULL ELSE (CURRENT_DATE - hs.days_since_visit) END,
    COALESCE(hs.days_since_visit, -1)::int,
    CASE WHEN mp.machine_id IS NULL THEN NULL ELSE
      (SELECT COALESCE(jsonb_agg(jsonb_build_object('label', t.l, 'pts', t.pts) ORDER BY t.pts DESC), '[]'::jsonb)
       FROM (VALUES
         ('runout', round(pup.w_runout * COALESCE(mp.s_runout_hero,0), 2)),
         ('gap',    round(pup.w_gap    * COALESCE(mp.s_gap,0), 2)),
         ('holes',  round(pup.w_holes  * COALESCE(mp.s_holes,0), 2)),
         ('expiry', round(pup.w_expiry * COALESCE(mp.s_expiry,0), 2)),
         ('stale',  round(pup.w_stale  * COALESCE(mp.s_stale,0), 2))
       ) t(l, pts)
       WHERE t.pts <> 0)
    END,
    mp.reasons_arr
  FROM with_expiry we
  LEFT JOIN swap_data sd ON sd.machine_name = we.device_name
  LEFT JOIN picker_data pd ON pd.machine_id = we.machine_id
  LEFT JOIN public.v_machine_priority mp ON mp.machine_id = we.machine_id
  LEFT JOIN public.v_machine_health_signals hs ON hs.machine_id = we.machine_id
  CROSS JOIN public.pick_urgency_params pup
  ORDER BY 26,
    CASE WHEN we.max_capacity > 0 THEN ROUND((GREATEST(we.total_stock,0)::numeric / we.max_capacity)*100, 1) ELSE 0 END ASC;
$function$;

CREATE OR REPLACE FUNCTION public.check_priority_surface_consistency()
 RETURNS TABLE(machine_name text, field text, health_value text, canonical_value text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT g.machine_name, d.field, d.hv, d.cv
  FROM get_machine_health() g
  JOIN machines m ON m.machine_id = g.machine_id AND m.status = 'Active'
  LEFT JOIN v_machine_priority mp ON mp.machine_id = g.machine_id
  LEFT JOIN v_machine_health_signals hs ON hs.machine_id = g.machine_id
  CROSS JOIN pick_urgency_params pup
  CROSS JOIN LATERAL (
    SELECT
      COALESCE((SELECT (e->>'pts')::numeric FROM jsonb_array_elements(COALESCE(g.urgency_breakdown,'[]'::jsonb)) e WHERE e->>'label'='runout'), 0)   AS chip_runout,
      COALESCE((SELECT (e->>'pts')::numeric FROM jsonb_array_elements(COALESCE(g.urgency_breakdown,'[]'::jsonb)) e WHERE e->>'label'='capacity'), 0) AS chip_capacity,
      COALESCE((SELECT (e->>'pts')::numeric FROM jsonb_array_elements(COALESCE(g.urgency_breakdown,'[]'::jsonb)) e WHERE e->>'label'='expiry'), 0)   AS chip_expiry,
      COALESCE((SELECT (e->>'pts')::numeric FROM jsonb_array_elements(COALESCE(g.urgency_breakdown,'[]'::jsonb)) e WHERE e->>'label'='stale'), 0)    AS chip_stale,
      COALESCE((SELECT (e->>'pts')::numeric FROM jsonb_array_elements(COALESCE(g.urgency_breakdown,'[]'::jsonb)) e WHERE e->>'label'='holes'), 0)    AS chip_holes,
      COALESCE((SELECT (e->>'pts')::numeric FROM jsonb_array_elements(COALESCE(g.urgency_breakdown,'[]'::jsonb)) e WHERE e->>'label'='intents'), 0)  AS chip_intents
  ) ch
  CROSS JOIN LATERAL (VALUES
    ('days_since_visit', g.days_since_visit::text, COALESCE(hs.days_since_visit, -1)::text),
    ('priority_score',   g.priority_score::text,   COALESCE(mp.p_score, 0)::text),
    ('priority_tier',    g.priority_tier,
       CASE WHEN NOT COALESCE(m.include_in_refill, true)
                 OR COALESCE(m.status, 'Active') IN ('Warehouse','Inactive') THEN 'excluded'
            WHEN mp.p_tier = 'P3_OK' OR mp.p_tier IS NULL THEN 'skip'
            ELSE mp.p_tier END),
    ('service_track',    g.service_track,
       COALESCE(mp.svc_track, 'main')),
    ('urgency_breakdown_sum',
       COALESCE((SELECT round(sum((e->>'pts')::numeric), 2) FROM jsonb_array_elements(g.urgency_breakdown) e), 0)::text,
       COALESCE(mp.p_score, 0)::text),
    ('chip_expiry',   round(ch.chip_expiry,2)::text,   round(pup.w_expiry   * COALESCE(mp.s_expiry,0), 2)::text),
    ('chip_stale',    round(ch.chip_stale,2)::text,    round(pup.w_stale    * COALESCE(mp.s_stale,0), 2)::text),
    ('chip_runout',   round(ch.chip_runout,2)::text,   round(pup.w_runout   * COALESCE(mp.s_runout_hero,0), 2)::text),
    ('chip_gap',
       round(COALESCE((SELECT (e->>'pts')::numeric FROM jsonb_array_elements(COALESCE(g.urgency_breakdown,'[]'::jsonb)) e WHERE e->>'label'='gap'), 0), 2)::text,
       round(pup.w_gap * COALESCE(mp.s_gap,0), 2)::text),
    ('chip_holes',    round(ch.chip_holes,2)::text,    round(pup.w_holes    * COALESCE(mp.s_holes,0), 2)::text)
  ) d(field, hv, cv)
  WHERE d.hv IS DISTINCT FROM d.cv;
$function$;
