-- PRD-100 WS3: v_machine_priority + chip surface gain the per-shelf hole signal.
-- Canonical object (Article 16) — body PATCHED from the live definition, columns appended only.
-- s_holes = 100*LEAST(1, SUM(hole_wt over holes)/holes_norm), weighted at w_holes.
-- Tier overrides + reason tokens are GATED on w_holes > 0 (fully dialable: w_holes=0
-- reproduces the prior output byte-identically — T4 golden proven pre-apply).
-- Chip surface (Cody revision): get_machine_health adds the 'holes' chip and
-- check_priority_surface_consistency subtracts it in the runout residual + checks it.
-- Rollbacks: docs/prds/rollback/v_machine_priority_2026-07-14.sql,
--            get_machine_health_2026-07-14.sql, check_priority_surface_consistency_2026-07-14.sql

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
            100::numeric * COALESCE(g.empty_mult_sum, 0::numeric) / GREATEST(g.graded_shelves, 1::bigint)::numeric AS s_empty,
            100::numeric * COALESCE(g.low_mult_sum, 0::numeric) / GREATEST(g.graded_shelves, 1::bigint)::numeric AS s_lowfill,
            100::numeric * LEAST(1::numeric, COALESCE(ha.hole_wt_sum, 0::numeric) / NULLIF(p_1.holes_norm, 0::numeric)) AS s_holes,
            COALESCE(ha.holes_total, 0::bigint) AS holes_total,
            COALESCE(ha.holes_a, 0::bigint) AS holes_a,
            COALESCE(ha.holes_b, 0::bigint) AS holes_b,
            COALESCE(ha.holes_c, 0::bigint) AS holes_c,
            COALESCE(ha.holes_d, 0::bigint) AS holes_d,
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
             LEFT JOIN hole_agg ha ON ha.machine_id = s_1.machine_id
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
            WHEN ms.hero_below AND s.days_since_visit::numeric > p.cooldown_days OR s.days_since_visit::numeric > p.stale_override_days OR s.expired_skus_now >= p.p1_expired_min OR ms.empty_ab_count >= p.p1_empty_ab_min OR (p.w_holes > 0::numeric AND (ms.holes_a >= 1 OR ms.holes_total >= p.p1_holes_min)) OR (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill + p.w_holes * ms.s_holes) >= p.p1_threshold THEN 'P1_RESTOCK'::text
            WHEN s.expired_skus_3d >= p.p2_exp3d_min OR ms.any_ab_below OR (p.w_holes > 0::numeric AND ms.holes_total >= p.p2_holes_min) OR (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill + p.w_holes * ms.s_holes) >= p.p2_threshold THEN 'P2_MAINTAIN'::text
            ELSE 'P3_OK'::text
        END AS p_tier,
    (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill + p.w_holes * ms.s_holes)::numeric(6,2) AS p_score,
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
            WHEN (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill + p.w_holes * ms.s_holes) >= p.p1_threshold THEN 'high_urgency'::text
            ELSE NULL::text
        END,
        CASE
            WHEN ms.s_capacity >= 50::numeric THEN 'low_capacity'::text
            ELSE NULL::text
        END], NULL::text) AS reasons_arr,
    COALESCE(s.venue_group, s.building_id, s.official_name) AS r_cluster,
    (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill + p.w_holes * ms.s_holes)::numeric(6,2) AS urgency,
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
    ms.holes_d
   FROM v_machine_health_signals s
     JOIN machines m ON m.machine_id = s.machine_id
     LEFT JOIN shelf_u25 u ON u.machine_id = s.machine_id
     LEFT JOIN mscore ms ON ms.machine_id = s.machine_id
     CROSS JOIN pick_urgency_params p;


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
        SELECT lower(TRIM(pod_product_name)) as norm_product,
          COALESCE(SUM(qty) FILTER (WHERE transaction_date >= NOW() - interval '7 days'), 0) * 4
          + COALESCE(SUM(qty) FILTER (WHERE transaction_date >= NOW() - interval '15 days'), 0) * 0.5 as bs
        FROM sales_history
        WHERE machine_id = dm.machine_id
          AND delivery_status IN ('Success','Successful')
          AND lower(TRIM(pod_product_name)) = ANY(dm.current_products)
        GROUP BY lower(TRIM(pod_product_name))
        HAVING COALESCE(SUM(qty) FILTER (WHERE transaction_date >= NOW() - interval '7 days'), 0) * 4
             + COALESCE(SUM(qty) FILTER (WHERE transaction_date >= NOW() - interval '15 days'), 0) * 0.5 = 0
      ) x) as dead_stock_count,
      (SELECT COUNT(*)::int FROM (
        SELECT lower(TRIM(pod_product_name)) as norm_product,
          COALESCE(SUM(qty) FILTER (WHERE transaction_date >= NOW() - interval '7 days'), 0) * 4
          + COALESCE(SUM(qty) FILTER (WHERE transaction_date >= NOW() - interval '15 days'), 0) * 0.5 as bs
        FROM sales_history
        WHERE machine_id = dm.machine_id
          AND delivery_status IN ('Success','Successful')
          AND lower(TRIM(pod_product_name)) = ANY(dm.current_products)
        GROUP BY lower(TRIM(pod_product_name))
        HAVING COALESCE(SUM(qty) FILTER (WHERE transaction_date >= NOW() - interval '7 days'), 0) * 4
             + COALESCE(SUM(qty) FILTER (WHERE transaction_date >= NOW() - interval '15 days'), 0) * 0.5 > 5
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
    COALESCE(mp.svc_track, CASE WHEN we.venue_grp = 'VOX' THEN 'vox' ELSE 'main' END),
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
         ('runout',
          round(COALESCE(mp.urgency,0),2)
            - round(pup.w_capacity * COALESCE(mp.s_capacity,0), 2)
            - round(pup.w_expiry   * COALESCE(mp.s_expiry,0), 2)
            - round(pup.w_stale    * COALESCE(mp.s_stale,0), 2)
            - round(pup.w_empty    * COALESCE(mp.s_empty,0), 2)
            - round(pup.w_lowfill  * COALESCE(mp.s_lowfill,0), 2)
            - round(pup.w_holes    * COALESCE(mp.s_holes,0), 2)),
         ('capacity',         round(pup.w_capacity * COALESCE(mp.s_capacity,0), 2)),
         ('expiry',           round(pup.w_expiry   * COALESCE(mp.s_expiry,0), 2)),
         ('stale',            round(pup.w_stale    * COALESCE(mp.s_stale,0), 2)),
         ('empty shelves',    round(pup.w_empty    * COALESCE(mp.s_empty,0), 2)),
         ('low-fill sellers', round(pup.w_lowfill  * COALESCE(mp.s_lowfill,0), 2)),
         ('holes',            round(pup.w_holes    * COALESCE(mp.s_holes,0), 2))
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
      COALESCE((SELECT (e->>'pts')::numeric FROM jsonb_array_elements(COALESCE(g.urgency_breakdown,'[]'::jsonb)) e WHERE e->>'label'='stale'), 0)    AS chip_stale
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
       COALESCE(mp.svc_track, CASE WHEN m.venue_group = 'VOX' THEN 'vox' ELSE 'main' END)),
    ('urgency_breakdown_sum',
       COALESCE((SELECT round(sum((e->>'pts')::numeric), 2) FROM jsonb_array_elements(g.urgency_breakdown) e), 0)::text,
       COALESCE(mp.urgency, 0)::text),
    ('chip_capacity', round(ch.chip_capacity,2)::text, round(pup.w_capacity * COALESCE(mp.s_capacity,0), 2)::text),
    ('chip_expiry',   round(ch.chip_expiry,2)::text,   round(pup.w_expiry   * COALESCE(mp.s_expiry,0), 2)::text),
    ('chip_stale',    round(ch.chip_stale,2)::text,    round(pup.w_stale    * COALESCE(mp.s_stale,0), 2)::text),
    ('chip_runout',   round(ch.chip_runout,2)::text,
       round((round(COALESCE(mp.urgency,0),2)
        - round(pup.w_capacity * COALESCE(mp.s_capacity,0), 2)
        - round(pup.w_expiry   * COALESCE(mp.s_expiry,0), 2)
        - round(pup.w_stale    * COALESCE(mp.s_stale,0), 2)
        - round(pup.w_empty    * COALESCE(mp.s_empty,0), 2)
        - round(pup.w_lowfill  * COALESCE(mp.s_lowfill,0), 2)
        - round(pup.w_holes    * COALESCE(mp.s_holes,0), 2)), 2)::text),
    ('chip_holes',
       COALESCE((SELECT round((e->>'pts')::numeric,2) FROM jsonb_array_elements(COALESCE(g.urgency_breakdown,'[]'::jsonb)) e WHERE e->>'label'='holes'), 0)::text,
       round(pup.w_holes * COALESCE(mp.s_holes,0), 2)::text)
  ) d(field, hv, cv)
  WHERE d.hv IS DISTINCT FROM d.cv;
$function$;

