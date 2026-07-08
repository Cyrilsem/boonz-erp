-- PRD-087 R4 — per-product stock overview: units live in machines vs units
-- in warehouse stock, for procurement. Read-only, no writes.
-- Rules (per WH-stock gotchas): boonz-level DIRECT sums (no product_mapping
-- join → no 10-40x inflation); warehouse side counts Active, non-quarantined,
-- non-expired batches; VOX_SOURCED sentinel rows (999 consignment
-- availability markers) are EXCLUDED — they are not owned stock.
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
WITH machine_side AS (
  SELECT pi.boonz_product_id,
         sum(pi.current_stock) AS machine_units,
         count(DISTINCT pi.machine_id) AS machine_count
  FROM pod_inventory pi
  JOIN machines m ON m.machine_id = pi.machine_id
  WHERE pi.status = 'Active'
    AND pi.current_stock > 0
    AND COALESCE(m.venue_group, '') <> 'WH'
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
  COALESCE(ms.machine_units, 0) AS machine_units,
  COALESCE(ms.machine_count, 0) AS machine_count,
  COALESCE(ws.wh_units, 0) AS wh_units,
  COALESCE(ws.wh_batches, 0) AS wh_batches,
  COALESCE(wsp.wh_by_warehouse, '{}'::jsonb) AS wh_by_warehouse,
  ws.nearest_wh_expiry,
  COALESCE(ms.machine_units, 0) + COALESCE(ws.wh_units, 0) AS total_units
FROM boonz_products bp
LEFT JOIN machine_side ms ON ms.boonz_product_id = bp.product_id
LEFT JOIN wh_side ws ON ws.boonz_product_id = bp.product_id
LEFT JOIN wh_split wsp ON wsp.boonz_product_id = bp.product_id
WHERE COALESCE(ms.machine_units, 0) + COALESCE(ws.wh_units, 0) > 0
ORDER BY total_units DESC;
$$;

COMMENT ON FUNCTION public.get_stock_overview() IS
'PRD-087 R4: per-boonz-product stock split — in-machine (pod_inventory Active) vs warehouse (Active, unquarantined, unexpired, VOX_SOURCED sentinels excluded). Read-only.';
