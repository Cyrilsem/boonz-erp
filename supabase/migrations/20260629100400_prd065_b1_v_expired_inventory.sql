-- PRD-065 B1 — v_expired_inventory. Single dashboard source for expired tiles.
-- Dara: unifies pod_inventory + warehouse_inventory rows that are Active and past expiry (Dubai date),
-- with location, product, shelf, units, expiry, age_days, and the sweep bucket:
--   zero_stock_residual (units = 0, auto-clearable) vs stock_bearing (units > 0, needs driver/manager).
-- Read-only view (no protected write) -> safe to apply on Cody green.

CREATE OR REPLACE VIEW public.v_expired_inventory AS
WITH dub AS (SELECT (now() AT TIME ZONE 'Asia/Dubai')::date AS today)
SELECT
  'machine'::text                                   AS location,
  p.pod_inventory_id                                AS row_id,
  p.machine_id                                      AS location_id,
  m.official_name                                   AS location_name,
  p.boonz_product_id,
  bp.boonz_product_name                             AS product_name,
  p.shelf_id,
  COALESCE(p.current_stock, 0)                      AS units,
  p.expiration_date                                 AS expiry,
  (d.today - p.expiration_date)                     AS age_days,
  CASE WHEN COALESCE(p.current_stock,0) = 0 THEN 'zero_stock_residual' ELSE 'stock_bearing' END AS bucket,
  p.status
FROM public.pod_inventory p
CROSS JOIN dub d
LEFT JOIN public.machines m       ON m.machine_id = p.machine_id
LEFT JOIN public.boonz_products bp ON bp.product_id = p.boonz_product_id
WHERE p.status = 'Active'
  AND p.expiration_date IS NOT NULL
  AND p.expiration_date < d.today

UNION ALL

SELECT
  'warehouse'::text                                 AS location,
  w.wh_inventory_id                                 AS row_id,
  w.warehouse_id                                    AS location_id,
  COALESCE(wh.display_name, wh.name, w.wh_location) AS location_name,
  w.boonz_product_id,
  bp.boonz_product_name                             AS product_name,
  NULL::uuid                                        AS shelf_id,
  COALESCE(w.warehouse_stock, 0)                    AS units,
  w.expiration_date                                 AS expiry,
  (d.today - w.expiration_date)                     AS age_days,
  CASE WHEN COALESCE(w.warehouse_stock,0) = 0 THEN 'zero_stock_residual' ELSE 'stock_bearing' END AS bucket,
  w.status
FROM public.warehouse_inventory w
CROSS JOIN dub d
LEFT JOIN public.warehouses wh     ON wh.warehouse_id = w.warehouse_id
LEFT JOIN public.boonz_products bp ON bp.product_id = w.boonz_product_id
WHERE w.status = 'Active'
  AND w.expiration_date IS NOT NULL
  AND w.expiration_date < d.today;

COMMENT ON VIEW public.v_expired_inventory IS
  'PRD-065 B1: pod + warehouse Active+past-expiry rows with location/units/age_days and bucket (zero_stock_residual vs stock_bearing). Single dashboard expired source; feeds sweep_expired_inventory.';

-- DOWN:
-- DROP VIEW IF EXISTS public.v_expired_inventory;
