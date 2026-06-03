-- Procurement demand: VOX-sourced vs Boonz-sourced toggle support.
--
-- Root cause fixed: the previous body filtered `pm.source_of_supply != 'VOX'`,
-- but the canonical value for venue/VOX-sourced products is 'venue_team'
-- (CHECK product_mapping_source_check = {'boonz','venue_team'}). The 'VOX'
-- literal never matched, so VOX-sourced SKUs (Aquafina, Pepsi, Ice Tea, the
-- VOX-branded line, Fade Fit, the large candy bags, 7Up) leaked into the
-- Boonz procurement demand list even though the banner claimed exclusion.
--
-- This migration:
--   1. Adds p_source filter param ('boonz' | 'venue_team' | NULL=all),
--      default 'boonz' so existing 2-arg callers keep getting Boonz-only.
--   2. Returns source_of_supply so the FE can label / toggle.
--   3. Filters on the correct 'venue_team' marker.
--
-- DROP+CREATE required: both the signature and the RETURNS TABLE shape change.
-- Old 2-arg signature is dropped (the new defaulted 3-arg resolves 2-arg calls).

DROP FUNCTION IF EXISTS public.get_procurement_demand(integer, numeric);

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
  demand AS (
    SELECT
      bp.product_id                                AS boonz_product_id,
      bp.boonz_product_name,
      pp.pod_product_name,
      pp.product_category,
      pm.split_pct,
      ps.sales_14d,
      ROUND(ps.sales_14d * pm.split_pct / 100, 0)  AS variant_demand_14d,
      COALESCE(wh.wh_stock, 0)                      AS wh_stock,
      COALESCE(pm.source_of_supply, 'boonz')        AS source_of_supply
    FROM pod_sales ps
    JOIN public.pod_products pp    ON pp.pod_product_id = ps.pod_product_id
    JOIN public.product_mapping pm ON pm.pod_product_id = pp.pod_product_id
                                  AND pm.status = 'Active'
                                  AND pm.is_global_default = TRUE
                                  AND (p_source IS NULL
                                       OR COALESCE(pm.source_of_supply, 'boonz') = p_source)
    JOIN public.boonz_products bp  ON bp.product_id = pm.boonz_product_id
    LEFT JOIN wh                   ON wh.boonz_product_id = bp.product_id
  )
SELECT
  boonz_product_id,
  boonz_product_name,
  pod_product_name,
  product_category,
  split_pct,
  sales_14d,
  variant_demand_14d,
  wh_stock,
  GREATEST(0, variant_demand_14d - wh_stock)                              AS gap,
  CEIL(GREATEST(0, variant_demand_14d - wh_stock) * (1 + p_buffer_pct))   AS suggested_qty,
  source_of_supply
FROM demand
WHERE GREATEST(0, variant_demand_14d - wh_stock) > 0
ORDER BY gap DESC;
$function$;
