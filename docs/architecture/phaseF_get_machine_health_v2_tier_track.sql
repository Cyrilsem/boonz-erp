-- Migration: phaseF_get_machine_health_v2_tier_track
-- Purpose: expose v7 priority model on the Stock Snapshot card grid.
--          Adds service_track, priority_tier, priority_score to get_machine_health(),
--          computed with the SAME thresholds as pick_machines_for_refill v7.
-- Read-only SQL helper (STABLE SECURITY DEFINER, no writes). Article 12 forward-only.
-- Mapping vs picker: units_7d = daily_velocity*7; runway = days_until_empty;
--   dead% = dead_stock_count/total_slots; intent proxied by pending_swap_count
--   (get_machine_health has no strategic_intents join).

DROP FUNCTION IF EXISTS public.get_machine_health();

CREATE FUNCTION public.get_machine_health()
 RETURNS TABLE(machine_name text, machine_id uuid, is_online boolean, total_stock integer, max_capacity integer, fill_pct numeric, total_slots integer, slots_at_zero integer, slots_below_25pct integer, daily_velocity numeric, days_until_empty numeric, has_sensor_errors boolean, machine_status text, include_in_refill boolean, recently_offline boolean, expired_units integer, expiring_7d_units integer, expiring_30d_units integer, days_to_earliest_expiry integer, machine_health_label text, machine_strategy text, machine_days_active integer, dead_stock_count integer, local_hero_count integer, health_tier text, health_sort integer, days_since_visit integer, pending_swap_count integer, is_picked_tomorrow boolean, picker_reasons text[], service_track text, priority_tier text, priority_score numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
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
      COALESCE((SELECT SUM(sh.qty)/NULLIF(7,0) FROM sales_history sh WHERE sh.machine_id = dm.machine_id AND sh.delivery_status IN ('Success','Successful') AND sh.transaction_date >= NOW() - interval '7 days'), 0) as daily_velocity,
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
  visit_data AS (
    SELECT rpo.machine_name, MAX(rpo.plan_date) as last_visit_date
    FROM refill_plan_output rpo
    WHERE rpo.operator_status = 'approved'
    GROUP BY rpo.machine_name
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
    WHERE mtv.plan_date = CURRENT_DATE + 1
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
    COALESCE(CURRENT_DATE - vd.last_visit_date, -1)::int,
    COALESCE(sd.swap_count, 0),
    pd.machine_id IS NOT NULL,
    pd.picked_reasons,
    -- NEW v7: service_track
    CASE WHEN we.venue_grp = 'VOX' THEN 'vox' ELSE 'main' END,
    -- NEW v7: priority_tier (mirrors pick_machines_for_refill v7)
    CASE
      WHEN we.slots_at_zero >= 1
        OR (h.runway_v IS NOT NULL AND h.runway_v < 7)
        OR (h.runway_v IS NOT NULL AND h.runway_v < 14 AND h.units7 >= 20)
        OR (we.slots_below_25pct >= 1 AND h.units7 >= 20)
        THEN 'P1_RESTOCK'
      WHEN h.dead_pct >= 15 OR h.dsv >= 14 OR we.expired_units >= 1 OR h.intent_cnt > 0
        THEN 'P2_MAINTAIN'
      ELSE 'skip'
    END,
    -- NEW v7: priority_score (mirrors pick_machines_for_refill v7)
    (  (CASE WHEN we.slots_at_zero >= 1 THEN 50 + LEAST((we.slots_at_zero-1)*12, 36) ELSE 0 END)
     + (CASE WHEN h.units7 >= 50 AND h.runway_v < 14 THEN 35
             WHEN h.units7 >= 20 AND h.runway_v < 10 THEN 28
             WHEN h.runway_v < 7 THEN 25
             WHEN h.runway_v < 14 THEN 12 ELSE 0 END)
     + (CASE WHEN h.units7 >= 15 THEN LEAST(we.slots_below_25pct*8, 24) ELSE 0 END)
     + (CASE WHEN h.units7 >= 50 THEN 10 ELSE 0 END)
     + (CASE WHEN h.dead_pct >= 30 THEN 15 WHEN h.dead_pct >= 15 THEN 8 ELSE 0 END)
     + (CASE WHEN h.dsv >= 21 THEN 10 WHEN h.dsv >= 14 THEN 6 WHEN h.dsv >= 10 THEN 3 ELSE 0 END)
     + (CASE WHEN we.expired_units >= 1 THEN 8 ELSE 0 END)
     + (CASE WHEN h.intent_cnt > 0 THEN 5 ELSE 0 END)
    )::numeric(6,2)
  FROM with_expiry we
  LEFT JOIN visit_data vd ON vd.machine_name = we.device_name
  LEFT JOIN swap_data sd ON sd.machine_name = we.device_name
  LEFT JOIN picker_data pd ON pd.machine_id = we.machine_id
  CROSS JOIN LATERAL (
    SELECT
      (we.daily_velocity * 7) AS units7,
      CASE WHEN we.daily_velocity > 0 THEN GREATEST(we.total_stock,0)::numeric / we.daily_velocity ELSE NULL END AS runway_v,
      CASE WHEN we.total_slots > 0 THEN we.dead_stock_count::numeric / we.total_slots * 100 ELSE 0 END AS dead_pct,
      COALESCE(CURRENT_DATE - vd.last_visit_date, -1) AS dsv,
      COALESCE(sd.swap_count, 0) AS intent_cnt
  ) h
  ORDER BY 26,
    CASE WHEN we.max_capacity > 0 THEN ROUND((GREATEST(we.total_stock,0)::numeric / we.max_capacity)*100, 1) ELSE 0 END ASC;
$function$;

-- Restore grants (DROP cleared them; PUBLIC default also re-applies on CREATE)
GRANT EXECUTE ON FUNCTION public.get_machine_health() TO anon, authenticated, service_role;
