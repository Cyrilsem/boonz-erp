-- Procurement demand: aggregate to one row per boonz_product (SKU).
--
-- Bug: when a boonz_product is fed by >1 active-default pod mapping (e.g.
-- Coca Cola - Zero <- Coca Cola Mix + Coca Cola Zero + Soft Drinks Mix), the
-- previous body emitted one row PER pod and subtracted the SKU's warehouse
-- stock in EACH row. Result: (a) repeated rows in the UI, (b) duplicate
-- React keys (same boonz_product_id), (c) warehouse stock double/triple-counted
-- so the gap was understated and the SKU under-ordered.
--
-- Fix: sum attributed demand across all contributing pods, then subtract
-- warehouse stock ONCE. One row per SKU per source. split_pct / sales_14d are
-- preserved for single-pod SKUs (so the "(50%)" style annotation still shows)
-- and collapsed for multi-pod SKUs. pod_product_name becomes the comma list of
-- contributing pods. Signature and return shape are unchanged from the
-- source-toggle migration.

CREATE OR REPLACE FUNCTION public.get_procurement_demand(
  p_lookback_days integer DEFAULT 14,
  p_buffer_pct    numeric DEFAULT 0.10,
  p_source        text    DEFAULT 'boonz'
)
RETURNS TABLE(
  boonz_product_id   uuid,
  boonz_product_name text,
  pod_product_name   text,
  product_category   text,
  split_pct          numeric,
  sales_14d          numeric,
  variant_demand_14d numeric,
  wh_stock           numeric,
  gap                numeric,
  suggested_qty      numeric,
  source_of_supply   text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
WITH
  pod_sales AS (
    SELECT pod_product_id, SUM(qty) AS sales_14d
    FROM public.v_sales_history_resolved
    WHERE delivery_status = 'Successful'
      AND transaction_date >= NOW() - (p_lookback_days || ' days')::interval
    GROUP BY pod_product_id
  ),
  wh AS (
    SELECT boonz_product_id, SUM(warehouse_stock) AS wh_stock
    FROM public.warehouse_inventory
    WHERE status = 'Active'
      AND (expiration_date IS NULL OR expiration_date > CURRENT_DATE)
    GROUP BY boonz_product_id
  ),
  -- One row per (pod -> boonz) contribution.
  contrib AS (
    SELECT
      bp.product_id                                AS boonz_product_id,
      bp.boonz_product_name,
      pp.pod_product_name,
      pp.product_category,
      pm.split_pct,
      ps.sales_14d                                 AS pod_sales,
      ROUND(ps.sales_14d * pm.split_pct / 100, 0)  AS attributed,
      COALESCE(pm.source_of_supply, 'boonz')        AS source_of_supply
    FROM pod_sales ps
    JOIN public.pod_products pp    ON pp.pod_product_id = ps.pod_product_id
    JOIN public.product_mapping pm ON pm.pod_product_id = pp.pod_product_id
                                  AND pm.status = 'Active'
                                  AND pm.is_global_default = TRUE
                                  AND (p_source IS NULL
                                       OR COALESCE(pm.source_of_supply, 'boonz') = p_source)
    JOIN public.boonz_products bp  ON bp.product_id = pm.boonz_product_id
  ),
  -- Collapse to one row per SKU (per source).
  agg AS (
    SELECT
      boonz_product_id,
      boonz_product_name,
      source_of_supply,
      MAX(product_category)                                              AS product_category,
      STRING_AGG(DISTINCT pod_product_name, ', ' ORDER BY pod_product_name) AS pod_product_name,
      CASE WHEN COUNT(*) = 1 THEN MAX(split_pct)  ELSE NULL            END AS split_pct,
      CASE WHEN COUNT(*) = 1 THEN MAX(pod_sales)  ELSE SUM(attributed) END AS sales_14d,
      SUM(attributed)                                                    AS variant_demand_14d
    FROM contrib
    GROUP BY boonz_product_id, boonz_product_name, source_of_supply
  )
SELECT
  a.boonz_product_id,
  a.boonz_product_name,
  a.pod_product_name,
  a.product_category,
  a.split_pct,
  a.sales_14d,
  a.variant_demand_14d,
  COALESCE(w.wh_stock, 0)                                                   AS wh_stock,
  GREATEST(0, a.variant_demand_14d - COALESCE(w.wh_stock, 0))               AS gap,
  CEIL(GREATEST(0, a.variant_demand_14d - COALESCE(w.wh_stock, 0)) * (1 + p_buffer_pct)) AS suggested_qty,
  a.source_of_supply
FROM agg a
LEFT JOIN wh w ON w.boonz_product_id = a.boonz_product_id
WHERE GREATEST(0, a.variant_demand_14d - COALESCE(w.wh_stock, 0)) > 0
ORDER BY gap DESC;
$function$;
