-- PRD-028 WS1: canonical machine expiry metric (Article 16)
-- Design: docs/prds/prd-028/WS1-expiry-unification-design.md
-- Chain: v_machine_expiry_batches (batch-resolution rule, row grain)
--   -> v_machine_expiry_summary (CANONICAL machine-grain expiry counts)
--   -> v_machine_health_signals / get_machine_health / get_machine_expiry_detail / get_machine_slots_with_expiry

-- 1) Batch-resolution rule: latest Active batch per shelf
--    (legacy NULL-shelf rows resolve per machine+product). No lookback window.
CREATE OR REPLACE VIEW public.v_machine_expiry_batches AS
WITH active_rows AS (
  SELECT pi.pod_inventory_id,
         pi.machine_id,
         pi.shelf_id,
         pi.boonz_product_id,
         pi.batch_id,
         pi.expiration_date,
         pi.current_stock,
         pi.snapshot_date,
         COALESCE(pi.shelf_id::text, 'product:' || pi.boonz_product_id::text) AS resolution_key
  FROM public.pod_inventory pi
  WHERE pi.status = 'Active' AND pi.current_stock > 0
),
latest AS (
  SELECT machine_id, resolution_key, max(snapshot_date) AS latest_snapshot
  FROM active_rows
  GROUP BY machine_id, resolution_key
)
SELECT a.pod_inventory_id,
       a.machine_id,
       a.shelf_id,
       a.boonz_product_id,
       a.batch_id,
       a.expiration_date,
       a.current_stock,
       a.snapshot_date
FROM active_rows a
JOIN latest l
  ON l.machine_id = a.machine_id
 AND l.resolution_key = a.resolution_key
 AND l.latest_snapshot = a.snapshot_date;

COMMENT ON VIEW public.v_machine_expiry_batches IS
'Article 16 batch-resolution rule for machine expiry: latest Active batch per shelf (NULL-shelf legacy rows: per machine+product), current_stock>0, no lookback window. Do NOT re-derive this rule inline; aggregate this view. See docs/architecture/METRICS_REGISTRY.md.';

-- 2) Canonical machine-grain expiry counts.
--    Existing columns preserved in order; SKU-grain columns appended.
--    Today = Dubai operational date (UTC CURRENT_DATE is the same disease as the plan-date bug).
CREATE OR REPLACE VIEW public.v_machine_expiry_summary AS
WITH dubai AS (SELECT (now() AT TIME ZONE 'Asia/Dubai')::date AS today)
SELECT b.machine_id,
       min(b.expiration_date) AS earliest_expiry,
       min(b.expiration_date) - d.today AS days_to_earliest,
       (sum(CASE WHEN b.expiration_date <= d.today THEN b.current_stock ELSE 0 END))::integer AS expired_units,
       (sum(CASE WHEN b.expiration_date > d.today AND b.expiration_date <= (d.today + 7) THEN b.current_stock ELSE 0 END))::integer AS expiring_7d_units,
       (sum(CASE WHEN b.expiration_date > d.today AND b.expiration_date <= (d.today + 30) THEN b.current_stock ELSE 0 END))::integer AS expiring_30d_units,
       (sum(b.current_stock))::integer AS total_tracked_units,
       (count(DISTINCT b.boonz_product_id) FILTER (WHERE b.expiration_date <= d.today))::integer AS expired_skus_now,
       (count(DISTINCT b.boonz_product_id) FILTER (WHERE b.expiration_date > d.today AND b.expiration_date <= (d.today + 3)))::integer AS expiring_skus_3d,
       (count(DISTINCT b.boonz_product_id) FILTER (WHERE b.expiration_date > d.today AND b.expiration_date <= (d.today + 7)))::integer AS expiring_skus_7d,
       (count(DISTINCT b.boonz_product_id) FILTER (WHERE b.expiration_date > d.today AND b.expiration_date <= (d.today + 30)))::integer AS expiring_skus_30d
FROM public.v_machine_expiry_batches b
CROSS JOIN dubai d
WHERE b.expiration_date IS NOT NULL
GROUP BY b.machine_id, d.today;

COMMENT ON VIEW public.v_machine_expiry_summary IS
'CANONICAL (Article 16, METRICS_REGISTRY.md): machine expiry counts (expired/expiring units + SKUs, earliest expiry). Aggregates v_machine_expiry_batches. Consumers: get_machine_health, v_machine_health_signals. Never re-derive expiry counts inline.';

-- 3) v_machine_health_signals: expiry_state now consumes the canonical summary.
--    Only the expiry_state CTE changes; output columns identical.
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
         COALESCE(sum(sh_1.qty), 0::numeric)::integer AS units_last_7d
  FROM base b_1
    LEFT JOIN sales_history sh_1 ON sh_1.machine_id = b_1.machine_id AND sh_1.transaction_date >= (CURRENT_DATE - '7 days'::interval)
  GROUP BY b_1.machine_id
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

-- 4) get_machine_expiry_detail: same signature, aggregates the canonical batch view, Dubai date.
CREATE OR REPLACE FUNCTION public.get_machine_expiry_detail(p_machine_name text)
RETURNS TABLE(boonz_product_name text, boonz_product_id uuid, total_qty numeric, earliest_expiry date, days_until_expiry integer, expired_qty numeric, expiring_7d_qty numeric, expiring_30d_qty numeric)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  WITH dubai AS (SELECT (now() AT TIME ZONE 'Asia/Dubai')::date AS today)
  SELECT
    bp.boonz_product_name,
    b.boonz_product_id,
    SUM(b.current_stock) AS total_qty,
    MIN(b.expiration_date) AS earliest_expiry,
    (MIN(b.expiration_date) - (SELECT today FROM dubai))::int AS days_until_expiry,
    SUM(CASE WHEN b.expiration_date <= (SELECT today FROM dubai) THEN b.current_stock ELSE 0 END) AS expired_qty,
    SUM(CASE WHEN b.expiration_date > (SELECT today FROM dubai) AND b.expiration_date <= (SELECT today FROM dubai) + 7 THEN b.current_stock ELSE 0 END) AS expiring_7d_qty,
    SUM(CASE WHEN b.expiration_date > (SELECT today FROM dubai) AND b.expiration_date <= (SELECT today FROM dubai) + 30 THEN b.current_stock ELSE 0 END) AS expiring_30d_qty
  FROM public.v_machine_expiry_batches b
  JOIN public.machines m ON m.machine_id = b.machine_id
  JOIN public.boonz_products bp ON bp.product_id = b.boonz_product_id
  WHERE m.official_name = p_machine_name
    AND b.expiration_date IS NOT NULL
  GROUP BY bp.boonz_product_name, b.boonz_product_id
  ORDER BY MIN(b.expiration_date) ASC;
$function$;

-- 5) get_machine_slots_with_expiry: product_expiry CTE reads the canonical batch view
--    (latest_snap CTE removed; everything else unchanged).
CREATE OR REPLACE FUNCTION public.get_machine_slots_with_expiry(p_machine_name text)
RETURNS TABLE(slot text, product text, current_stock integer, max_stock integer, fill_pct integer, expiry_days integer, expiry_qty numeric, target_stock numeric, refill_qty numeric, stance text, action_code text, global_product_status text, local_performance_role text, suggested_product text, units_sold_7d numeric, final_score numeric, decision jsonb, shelf_id uuid, pod_product_id uuid, suggested_pod_product_id uuid)
LANGUAGE sql
STABLE
AS $function$
  WITH
  pod_by_name AS (
    SELECT DISTINCT ON (LOWER(TRIM(pp.pod_product_name)))
      LOWER(TRIM(pp.pod_product_name)) AS product_lower, pp.pod_product_id
    FROM public.pod_products pp
    ORDER BY LOWER(TRIM(pp.pod_product_name)), pp.pod_product_id
  ),
  dubai AS (SELECT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date AS today),
  machine AS (
    SELECT machine_id FROM public.weimi_device_status
    WHERE device_name = p_machine_name
      AND snapshot_date = (SELECT MAX(snapshot_date) FROM public.weimi_device_status WHERE device_name = p_machine_name)
    LIMIT 1
  ),
  aisles AS (
    SELECT v.slot_name AS slot, TRIM(v.goods_name_raw) AS product,
      GREATEST(v.current_stock, 0) AS current_stock, GREATEST(v.max_stock, 1) AS max_stock,
      v.machine_id, sc.shelf_id
    FROM public.v_live_shelf_stock v
    LEFT JOIN public.shelf_configurations sc
      ON sc.machine_id = v.machine_id AND sc.is_phantom = false
     AND v.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text
    WHERE v.machine_id = (SELECT machine_id FROM machine)
  ),
  product_boonz AS (
    SELECT DISTINCT ON (LOWER(TRIM(pp.pod_product_name)))
      LOWER(TRIM(pp.pod_product_name)) AS product_lower, pm.boonz_product_id
    FROM pod_products pp JOIN product_mapping pm ON pm.pod_product_id = pp.pod_product_id
    ORDER BY LOWER(TRIM(pp.pod_product_name)), pm.boonz_product_id
  ),
  product_expiry AS (
    SELECT b.boonz_product_id,
      (MIN(b.expiration_date) - (SELECT today FROM dubai))::int AS days_until_expiry,
      SUM(CASE WHEN b.expiration_date <= (SELECT today FROM dubai) THEN b.current_stock ELSE 0 END) AS expired_qty,
      SUM(CASE WHEN b.expiration_date > (SELECT today FROM dubai) AND b.expiration_date <= (SELECT today FROM dubai) + 7 THEN b.current_stock ELSE 0 END) AS expiring_7d_qty
    FROM public.v_machine_expiry_batches b
    WHERE b.machine_id = (SELECT machine_id FROM machine)
      AND b.expiration_date IS NOT NULL
    GROUP BY b.boonz_product_id
  ),
  product_velocity AS (
    SELECT LOWER(TRIM(sh.pod_product_name)) AS product_lower,
      CASE WHEN sh.goods_slot LIKE '0-A%' THEN 'A' || ((SUBSTRING(sh.goods_slot, 4)::int) + 1)::text
           WHEN sh.goods_slot LIKE '1-A%' THEN 'B' || ((SUBSTRING(sh.goods_slot, 4)::int) + 1)::text
           ELSE sh.goods_slot END AS slot_code,
      COALESCE(SUM(sh.qty) FILTER (WHERE sh.transaction_date >= NOW() - interval '7 days'), 0) AS sold_7d
    FROM sales_history sh
    WHERE sh.machine_id = (SELECT machine_id FROM machine) AND sh.delivery_status IN ('Success','Successful')
    GROUP BY LOWER(TRIM(sh.pod_product_name)), slot_code
  ),
  latest_ri AS (
    SELECT ri.* FROM refill_instructions ri
    WHERE ri.machine_id = (SELECT machine_id FROM machine)
      AND ri.report_timestamp = (SELECT MAX(report_timestamp) FROM refill_instructions WHERE machine_id = (SELECT machine_id FROM machine))
  )
  SELECT
    ai.slot, ai.product, ai.current_stock, ai.max_stock,
    CASE WHEN ai.max_stock > 0 THEN ROUND((ai.current_stock::numeric / ai.max_stock) * 100)::int ELSE 0 END,
    pe.days_until_expiry,
    CASE WHEN pe.expired_qty > 0 THEN pe.expired_qty WHEN pe.expiring_7d_qty > 0 THEN pe.expiring_7d_qty ELSE NULL END,
    COALESCE((d.decision->>'target_units')::numeric, ai.current_stock),
    COALESCE((d.decision->>'refill_qty')::numeric, 0),
    COALESCE(d.decision->>'stance', 'KEEP'),
    compute_action_code(
      compute_local_role(COALESCE(pv.sold_7d * 4, 0), 0),
      COALESCE(d.decision->>'global_badge', gps.global_status, '📦 Core Range')),
    COALESCE(d.decision->>'global_badge', gps.global_status, '📦 Core Range'),
    COALESCE(d.decision->>'local_badge', '✅ Standard'),
    ri.suggested_product,
    COALESCE(pv.sold_7d, 0),
    COALESCE((d.decision->>'final_score')::numeric, 0),
    d.decision,
    ai.shelf_id,
    pbn.pod_product_id,
    sbn.pod_product_id
  FROM aisles ai
  LEFT JOIN product_boonz pb ON pb.product_lower = LOWER(ai.product)
  LEFT JOIN product_expiry pe ON pe.boonz_product_id = pb.boonz_product_id
  LEFT JOIN product_velocity pv ON pv.product_lower = LOWER(ai.product) AND pv.slot_code = ai.slot
  LEFT JOIN mv_global_product_scores gps ON LOWER(TRIM(gps.product)) = LOWER(ai.product)
  LEFT JOIN latest_ri ri ON normalize_slot(ri.slot_name) = normalize_slot(ai.slot)
  LEFT JOIN pod_by_name pbn ON pbn.product_lower = LOWER(ai.product)
  LEFT JOIN pod_by_name sbn ON sbn.product_lower = LOWER(TRIM(ri.suggested_product))
  LEFT JOIN LATERAL (
    SELECT public.compute_refill_decision(ai.machine_id, ai.shelf_id, pb.boonz_product_id, 10) AS decision
    WHERE ai.shelf_id IS NOT NULL
  ) d ON true
  ORDER BY COALESCE((d.decision->>'final_score')::numeric, 0) DESC, ai.slot;
$function$;

-- 6) Deprecation markers (no DROP in WS1; removal needs CS approval).
COMMENT ON VIEW public.v_pod_inventory_expiry_status IS
'DEPRECATED (PRD-028 WS1, 2026-06-12): non-canonical expiry derivation, no known consumers. Use v_machine_expiry_summary / v_machine_expiry_batches (Article 16). Scheduled for drop pending CS approval.';
COMMENT ON VIEW public.v_pod_inventory_health IS
'DEPRECATED (PRD-028 WS1, 2026-06-12): non-canonical expiry derivation, no known consumers. Use v_machine_expiry_summary / v_machine_expiry_batches (Article 16). Scheduled for drop pending CS approval.';
