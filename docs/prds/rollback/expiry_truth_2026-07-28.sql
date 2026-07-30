-- ROLLBACK for PRD-105 Expiry Truth (applied 2026-07-28).
-- Byte-identical restore of the pre-change bodies (md5s in PRD-105-EXECUTION-LOG.md).
-- Read-path only; no data to restore (zero writes were made).

-- 1) v_machine_expiry_batches  (restore md5 f2f6397dc4a4fb0e90fbad7ba85f02ab)
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
            COALESCE((pi.shelf_id)::text, ('product:'::text || (pi.boonz_product_id)::text)) AS resolution_key
           FROM pod_inventory pi
          WHERE ((pi.status = 'Active'::text) AND (pi.current_stock > (0)::numeric))
        ), latest AS (
         SELECT active_rows.machine_id,
            active_rows.resolution_key,
            max(active_rows.snapshot_date) AS latest_snapshot
           FROM active_rows
          GROUP BY active_rows.machine_id, active_rows.resolution_key
        )
 SELECT a.pod_inventory_id,
    a.machine_id,
    a.shelf_id,
    a.boonz_product_id,
    a.batch_id,
    a.expiration_date,
    a.current_stock,
    a.snapshot_date
   FROM (active_rows a
     JOIN latest l ON (((l.machine_id = a.machine_id) AND (l.resolution_key = a.resolution_key) AND (l.latest_snapshot = a.snapshot_date))));

-- 2) partial index (drop the one PRD-105 added)
DROP INDEX IF EXISTS public.idx_pod_inventory_active_shelf_expiry;

-- 3) get_machine_slots_with_expiry  (restore md5 f57322b3c770e14c155008a9e10502b4)
CREATE OR REPLACE FUNCTION public.get_machine_slots_with_expiry(p_machine_name text)
 RETURNS TABLE(slot text, product text, current_stock integer, max_stock integer, fill_pct integer, expiry_days integer, expiry_qty numeric, target_stock numeric, refill_qty numeric, stance text, action_code text, global_product_status text, local_performance_role text, suggested_product text, units_sold_7d numeric, final_score numeric, decision jsonb, shelf_id uuid, pod_product_id uuid, suggested_pod_product_id uuid, nearest_expiry_days integer, nearest_expiry_qty numeric)
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
  prod_nearest_date AS (
    SELECT b.boonz_product_id, MIN(b.expiration_date) AS nd
    FROM public.v_machine_expiry_batches b
    WHERE b.machine_id = (SELECT machine_id FROM machine) AND b.expiration_date IS NOT NULL
    GROUP BY b.boonz_product_id
  ),
  prod_nearest AS (
    SELECT n.boonz_product_id,
      (n.nd - (SELECT today FROM dubai))::int AS nearest_days,
      SUM(b.current_stock) AS nearest_qty
    FROM prod_nearest_date n
    JOIN public.v_machine_expiry_batches b
      ON b.boonz_product_id = n.boonz_product_id
     AND b.machine_id = (SELECT machine_id FROM machine)
     AND b.expiration_date = n.nd
    GROUP BY n.boonz_product_id, n.nd
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
    sbn.pod_product_id,
    pn.nearest_days,
    pn.nearest_qty
  FROM aisles ai
  LEFT JOIN product_boonz pb ON pb.product_lower = LOWER(ai.product)
  LEFT JOIN product_expiry pe ON pe.boonz_product_id = pb.boonz_product_id
  LEFT JOIN prod_nearest pn ON pn.boonz_product_id = pb.boonz_product_id
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

-- 4) get_machine_orphan_expiry  (restore md5 e5e19b3cef7a2a6fcc504940410c4077)
CREATE OR REPLACE FUNCTION public.get_machine_orphan_expiry(p_machine_name text)
 RETURNS TABLE(boonz_product_id uuid, boonz_product text, units integer, nearest_expiry_days integer, expired_units integer, batches integer)
 LANGUAGE sql
 STABLE
AS $function$
  WITH
  dubai AS (SELECT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date AS today),
  machine AS (
    SELECT machine_id FROM public.weimi_device_status
    WHERE device_name = p_machine_name
      AND snapshot_date = (SELECT MAX(snapshot_date) FROM public.weimi_device_status WHERE device_name = p_machine_name)
    LIMIT 1
  ),
  live_boonz AS (
    SELECT DISTINCT pm.boonz_product_id
    FROM public.v_live_shelf_stock v
    JOIN public.pod_products pp ON LOWER(TRIM(pp.pod_product_name)) = LOWER(TRIM(v.goods_name_raw))
    JOIN public.product_mapping pm ON pm.pod_product_id = pp.pod_product_id AND pm.status = 'Active'
    WHERE v.machine_id = (SELECT machine_id FROM machine) AND v.is_enabled
  )
  SELECT b.boonz_product_id,
    bp.boonz_product_name AS boonz_product,
    SUM(b.current_stock)::int AS units,
    (MIN(b.expiration_date) FILTER (WHERE b.expiration_date IS NOT NULL) - (SELECT today FROM dubai))::int AS nearest_expiry_days,
    SUM(CASE WHEN b.expiration_date <= (SELECT today FROM dubai) THEN b.current_stock ELSE 0 END)::int AS expired_units,
    COUNT(*)::int AS batches
  FROM public.v_machine_expiry_batches b
  LEFT JOIN public.boonz_products bp ON bp.product_id = b.boonz_product_id
  WHERE b.machine_id = (SELECT machine_id FROM machine)
    AND b.shelf_id IS NULL
    AND b.boonz_product_id NOT IN (SELECT boonz_product_id FROM live_boonz)
  GROUP BY b.boonz_product_id, bp.boonz_product_name
  ORDER BY units DESC;
$function$;
