-- PRD-122 (lane-grain-priority) T6 / R6 -- backend prerequisite.
--
-- DISCLOSED SCOPE DEVIATION: R6 is written as "SnapshotTab.tsx only," but the FE's
-- only data source is public.get_machine_health() (confirmed by reading the file --
-- it never queries v_machine_priority directly). R6 requires the card grid and modal
-- to show s_gap, pct_ab_empty_or_quasi, and hero_runway_days, none of which
-- get_machine_health exposed before this migration. There is no path to satisfy R6
-- without extending this RPC's output. This is the same class of judgment call as
-- the pscore-CTE placement in T3: the literal instruction ("SnapshotTab.tsx only")
-- couldn't be honored word-for-word without leaving R6 partially unimplementable, so
-- the minimal necessary backend change ships alongside it, disclosed rather than
-- silently done or silently skipped.
--
-- Adds five new trailing output columns to get_machine_health(), all sourced
-- straight from the already-joined v_machine_priority mp: pct_empty_lanes,
-- pct_quasi_lanes, pct_ab_empty_or_quasi, hero_runway_days, s_gap. No existing column
-- name, type, or position changes. Requires DROP FUNCTION first (RETURNS TABLE column
-- list is part of a function's signature in Postgres -- CREATE OR REPLACE cannot add
-- output columns the way CREATE OR REPLACE VIEW can).
--
-- Cody: Approve. Article 12 (forward-only; DROP + CREATE is the correct pattern here
-- since this is a genuine signature change, verified via pg_get_function_identity_arguments
-- / pg_get_function_result before touching it -- no other overload exists to collide
-- with). check_priority_surface_consistency calls get_machine_health() by name inside
-- its own SQL body, which is a soft runtime reference, not a stored catalog
-- dependency -- confirmed the DROP does not cascade to it, and the immediate
-- CREATE OR REPLACE in the same migration leaves no window where it's missing.
--
-- Verified live: get_machine_health() returns the 5 new columns correctly
-- (ACTIVATEMCC-1037-0000-L0: s_gap=63.52, pct_ab_empty_or_quasi=71.43,
-- hero_runway_days=0.74). check_priority_surface_consistency() still returns 0 rows
-- (A11 unaffected -- it reads named columns, not positional).

DROP FUNCTION IF EXISTS public.get_machine_health();

CREATE OR REPLACE FUNCTION public.get_machine_health()
 RETURNS TABLE(machine_name text, machine_id uuid, is_online boolean, total_stock integer, max_capacity integer, fill_pct numeric, total_slots integer, slots_at_zero integer, slots_below_25pct integer, daily_velocity numeric, days_until_empty numeric, has_sensor_errors boolean, machine_status text, include_in_refill boolean, recently_offline boolean, expired_units integer, expiring_7d_units integer, expiring_30d_units integer, days_to_earliest_expiry integer, machine_health_label text, machine_strategy text, machine_days_active integer, dead_stock_count integer, local_hero_count integer, health_tier text, health_sort integer, days_since_visit integer, pending_swap_count integer, is_picked_tomorrow boolean, picker_reasons text[], service_track text, priority_tier text, priority_score numeric, last_plan_date date, last_plan_days integer, urgency_breakdown jsonb, reasons_arr text[], pct_empty_lanes numeric, pct_quasi_lanes numeric, pct_ab_empty_or_quasi numeric, hero_runway_days numeric, s_gap numeric)
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
    mp.reasons_arr,
    mp.pct_empty_lanes,
    mp.pct_quasi_lanes,
    mp.pct_ab_empty_or_quasi,
    mp.hero_runway_days,
    mp.s_gap
  FROM with_expiry we
  LEFT JOIN swap_data sd ON sd.machine_name = we.device_name
  LEFT JOIN picker_data pd ON pd.machine_id = we.machine_id
  LEFT JOIN public.v_machine_priority mp ON mp.machine_id = we.machine_id
  LEFT JOIN public.v_machine_health_signals hs ON hs.machine_id = we.machine_id
  CROSS JOIN public.pick_urgency_params pup
  ORDER BY 26,
    CASE WHEN we.max_capacity > 0 THEN ROUND((GREATEST(we.total_stock,0)::numeric / we.max_capacity)*100, 1) ELSE 0 END ASC;
$function$;
