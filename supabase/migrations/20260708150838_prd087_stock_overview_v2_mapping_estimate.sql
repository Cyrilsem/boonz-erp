-- PRD-087 R4 v2 — machine-side units are now ESTIMATED from live shelf stock
-- × product_mapping split ratios (CS: pod_inventory batch grain undercounts
-- mixed shelves — e.g. Coca Cola Zero lives inside 'Coca Cola Mix' and
-- 'Soft Drinks Mix' shelves). Machine-specific Active mappings win over
-- global defaults; split_pct normalized within the chosen set (mix_weight
-- lesson). Warehouse side unchanged.
CREATE OR REPLACE FUNCTION public.get_stock_overview()
RETURNS TABLE(
  boonz_product_id uuid,
  product_name text,
  machine_units numeric,
  machine_count bigint,
  wh_units numeric,
  wh_batches bigint,
  wh_by_warehouse jsonb,
  nearest_wh_expiry date,
  total_units numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
WITH shelf AS (
  SELECT ls.machine_id, ls.pod_product_id, sum(ls.current_stock) AS stock
  FROM v_live_shelf_stock ls
  WHERE ls.current_stock > 0
    AND COALESCE(ls.is_eligible_machine, true)
    AND ls.pod_product_id IS NOT NULL
  GROUP BY 1, 2
),
map_scoped AS (
  SELECT s.machine_id, s.pod_product_id, s.stock,
         pm.boonz_product_id, pm.split_pct,
         sum(pm.split_pct) OVER (PARTITION BY s.machine_id, s.pod_product_id) AS tot_split
  FROM shelf s
  JOIN LATERAL (
    SELECT CASE WHEN EXISTS (
      SELECT 1 FROM product_mapping p2
      WHERE p2.pod_product_id = s.pod_product_id
        AND p2.machine_id = s.machine_id
        AND p2.status = 'Active'
    ) THEN 'machine' ELSE 'global' END AS lvl
  ) pick ON true
  JOIN product_mapping pm
    ON pm.pod_product_id = s.pod_product_id
   AND pm.status = 'Active'
   AND (
     (pick.lvl = 'machine' AND pm.machine_id = s.machine_id)
     OR (pick.lvl = 'global' AND (pm.machine_id IS NULL OR pm.is_global_default))
   )
),
machine_side AS (
  SELECT ms.boonz_product_id,
         sum(ms.split_pct / NULLIF(ms.tot_split, 0) * ms.stock) AS machine_units,
         count(DISTINCT ms.machine_id) FILTER (WHERE ms.split_pct > 0) AS machine_count
  FROM map_scoped ms
  GROUP BY 1
),
wh_side AS (
  SELECT wi.boonz_product_id,
         sum(wi.warehouse_stock) AS wh_units,
         count(*) AS wh_batches,
         min(wi.expiration_date) FILTER (WHERE wi.expiration_date IS NOT NULL) AS nearest_wh_expiry
  FROM warehouse_inventory wi
  WHERE wi.status = 'Active'
    AND COALESCE(wi.quarantined, false) = false
    AND wi.warehouse_stock > 0
    AND (wi.expiration_date IS NULL OR wi.expiration_date >= (now() AT TIME ZONE 'Asia/Dubai')::date)
    AND COALESCE(wi.wh_location, '') <> 'VOX_SOURCED'
  GROUP BY 1
),
wh_split AS (
  SELECT wi.boonz_product_id,
         jsonb_object_agg(COALESCE(w.display_name, w.name), wi_units) AS wh_by_warehouse
  FROM (
    SELECT wi.boonz_product_id, wi.warehouse_id, sum(wi.warehouse_stock) AS wi_units
    FROM warehouse_inventory wi
    WHERE wi.status = 'Active'
      AND COALESCE(wi.quarantined, false) = false
      AND wi.warehouse_stock > 0
      AND (wi.expiration_date IS NULL OR wi.expiration_date >= (now() AT TIME ZONE 'Asia/Dubai')::date)
      AND COALESCE(wi.wh_location, '') <> 'VOX_SOURCED'
    GROUP BY 1, 2
  ) wi
  JOIN warehouses w ON w.warehouse_id = wi.warehouse_id
  GROUP BY 1
)
SELECT
  bp.product_id AS boonz_product_id,
  bp.boonz_product_name AS product_name,
  round(COALESCE(ms.machine_units, 0)) AS machine_units,
  COALESCE(ms.machine_count, 0) AS machine_count,
  COALESCE(ws.wh_units, 0) AS wh_units,
  COALESCE(ws.wh_batches, 0) AS wh_batches,
  COALESCE(wsp.wh_by_warehouse, '{}'::jsonb) AS wh_by_warehouse,
  ws.nearest_wh_expiry,
  round(COALESCE(ms.machine_units, 0)) + COALESCE(ws.wh_units, 0) AS total_units
FROM boonz_products bp
LEFT JOIN machine_side ms ON ms.boonz_product_id = bp.product_id
LEFT JOIN wh_side ws ON ws.boonz_product_id = bp.product_id
LEFT JOIN wh_split wsp ON wsp.boonz_product_id = bp.product_id
WHERE round(COALESCE(ms.machine_units, 0)) + COALESCE(ws.wh_units, 0) > 0
ORDER BY total_units DESC;
$$;

COMMENT ON FUNCTION public.get_stock_overview() IS
'PRD-087 R4 v2: per-boonz-product stock split — machine side ESTIMATED from v_live_shelf_stock × normalized product_mapping split_pct (machine-specific mappings win); WH side = Active, unquarantined, in-date, VOX_SOURCED sentinels excluded. Read-only.';
