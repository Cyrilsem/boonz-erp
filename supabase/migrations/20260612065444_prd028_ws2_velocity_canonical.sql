-- PRD-028 WS2: canonical machine velocity rollup (Article 16)
-- Design: docs/prds/prd-028/WS2-velocity-design.md
-- v_machine_velocity (CANONICAL) -> get_machine_health.daily_velocity + v_machine_health_signals.units_last_7d
-- Applied via MCP as prd028_ws2_velocity_canonical (version 20260612065444).

-- 1) Canonical machine-grain velocity.
CREATE OR REPLACE VIEW public.v_machine_velocity AS
SELECT sh.machine_id,
       (COALESCE(sum(sh.qty) FILTER (WHERE sh.transaction_date >= now() - interval '7 days'), 0))::integer AS units_7d,
       (COALESCE(sum(sh.qty), 0))::integer AS units_30d,
       COALESCE(sum(sh.qty) FILTER (WHERE sh.transaction_date >= now() - interval '7 days'), 0) / 7.0 AS daily_velocity_7d,
       COALESCE(sum(sh.qty), 0) / 30.0 AS daily_velocity_30d
FROM public.sales_history sh
WHERE sh.delivery_status IN ('Success','Successful')
  AND sh.transaction_date >= now() - interval '30 days'
GROUP BY sh.machine_id;

COMMENT ON VIEW public.v_machine_velocity IS
'CANONICAL (Article 16, METRICS_REGISTRY.md): machine-grain sales velocity (units_7d/units_30d, daily_velocity_7d/_30d). Success-only, rolling now()-interval windows. Consumers: get_machine_health, v_machine_health_signals. Never re-derive machine velocity inline; slot/product-grain velocities are a different registry row.';

-- 2) v_machine_health_signals: sales_recent now consumes the canonical view.
--    Only the sales_recent CTE changes; output columns identical.
CREATE OR REPLACE VIEW public.v_machine_health_signals AS
WITH base AS (
  SELECT m.machine_id,
         m.official_name,
         m.venue_group,
         m.location_type,
         m.building_id,
         m.relaunched_at
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
         COALESCE(ex.expired_skus_now, 0) AS expired_skus_now,
         COALESCE(ex.expiring_skus_3d, 0) AS expired_skus_3d,
         COALESCE(ex.expiring_skus_7d, 0) AS expired_skus_7d,
         COALESCE(ex.expiring_skus_30d, 0) AS expired_skus_30d
  FROM base b_1
    LEFT JOIN v_machine_expiry_summary ex ON ex.machine_id = b_1.machine_id
), last_visit AS (
  SELECT b_1.machine_id,
         max(rd.dispatch_date) AS last_visit_date
  FROM base b_1
    LEFT JOIN refill_dispatching rd ON rd.machine_id = b_1.machine_id AND rd.cancelled = false AND rd.skipped = false AND (rd.picked_up = true OR rd.returned = true OR rd.dispatched = true AND rd.packed = true)
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
           WHEN lv.last_visit_date IS NULL THEN 365
           ELSE LEAST(GREATEST(CURRENT_DATE - lv.last_visit_date, 0), 365)
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
  LEFT JOIN sales_recent sr USING (machine_id)
  LEFT JOIN ramping rmp USING (machine_id)
  LEFT JOIN intent_state int_ USING (machine_id);

-- 3) get_machine_health: daily_velocity now consumes the canonical view (formula identical),
--    + SET search_path (Cody Article 4 revision). Everything else verbatim.
CREATE OR REPLACE FUNCTION public.get_machine_health()
 RETURNS TABLE(machine_name text, machine_id uuid, is_online boolean, total_stock integer, max_capacity integer, fill_pct numeric, total_slots integer, slots_at_zero integer, slots_below_25pct integer, daily_velocity numeric, days_until_empty numeric, has_sensor_errors boolean, machine_status text, include_in_refill boolean, recently_offline boolean, expired_units integer, expiring_7d_units integer, expiring_30d_units integer, days_to_earliest_expiry integer, machine_health_label text, machine_strategy text, machine_days_active integer, dead_stock_count integer, local_hero_count integer, health_tier text, health_sort integer, days_since_visit integer, pending_swap_count integer, is_picked_tomorrow boolean, picker_reasons text[], service_track text, priority_tier text, priority_score numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
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
  visit_data AS (
    SELECT rpo.machine_name, MAX(rpo.plan_date) as last_visit_date
    FROM refill_plan_output rpo
    WHERE rpo.operator_status = 'approved'
      AND rpo.plan_date <= CURRENT_DATE
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
    COALESCE(CURRENT_DATE - vd.last_visit_date, -1)::int,
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
    COALESCE(mp.p_score, 0)
  FROM with_expiry we
  LEFT JOIN visit_data vd ON vd.machine_name = we.device_name
  LEFT JOIN swap_data sd ON sd.machine_name = we.device_name
  LEFT JOIN picker_data pd ON pd.machine_id = we.machine_id
  LEFT JOIN public.v_machine_priority mp ON mp.machine_id = we.machine_id
  ORDER BY 26,
    CASE WHEN we.max_capacity > 0 THEN ROUND((GREATEST(we.total_stock,0)::numeric / we.max_capacity)*100, 1) ELSE 0 END ASC;
$function$;