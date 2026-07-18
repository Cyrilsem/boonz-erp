-- Rollback for PRD-100: live get_machine_health as of 2026-07-14 (PRD-075 six-chip breakdown).
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
            - round(pup.w_lowfill  * COALESCE(mp.s_lowfill,0), 2)),
         ('capacity',         round(pup.w_capacity * COALESCE(mp.s_capacity,0), 2)),
         ('expiry',           round(pup.w_expiry   * COALESCE(mp.s_expiry,0), 2)),
         ('stale',            round(pup.w_stale    * COALESCE(mp.s_stale,0), 2)),
         ('empty shelves',    round(pup.w_empty    * COALESCE(mp.s_empty,0), 2)),
         ('low-fill sellers', round(pup.w_lowfill  * COALESCE(mp.s_lowfill,0), 2))
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
