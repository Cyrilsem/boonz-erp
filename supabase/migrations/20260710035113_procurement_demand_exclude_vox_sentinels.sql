-- Exclude VOX consignment sentinels (wh_location='VOX_SOURCED', 999/2099 rows that feed
-- VOX machine dispatch) from the procurement warehouse read. They are NOT Boonz-procurable
-- stock. Matches the Stock Overview page. Only the wh CTE changes.
CREATE OR REPLACE FUNCTION public.get_procurement_demand(
  p_lookback_days integer DEFAULT 14, p_buffer_pct numeric DEFAULT 0.10, p_source text DEFAULT 'boonz')
RETURNS TABLE(boonz_product_id uuid, boonz_product_name text, pod_product_name text, product_category text,
  split_pct numeric, sales_14d numeric, variant_demand_14d numeric, wh_stock numeric, machine_stock numeric,
  gap numeric, suggested_qty numeric, units_per_box smallint, source_of_supply text)
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $function$
WITH
  pod_sales AS (
    SELECT pod_product_id, SUM(qty) AS sales_14d FROM public.v_sales_history_resolved
    WHERE delivery_status='Successful' AND transaction_date >= NOW() - (p_lookback_days || ' days')::interval
    GROUP BY pod_product_id),
  wh AS (
    SELECT boonz_product_id, SUM(warehouse_stock) AS wh_stock FROM public.warehouse_inventory
    WHERE status='Active' AND (expiration_date IS NULL OR expiration_date > CURRENT_DATE)
      AND wh_location IS DISTINCT FROM 'VOX_SOURCED'   -- exclude VOX consignment sentinels
    GROUP BY boonz_product_id),
  machine AS (
    SELECT pod_product_id, SUM(current_stock) AS pod_machine_stock FROM public.v_live_shelf_stock
    WHERE COALESCE(is_enabled,TRUE)=TRUE AND COALESCE(is_broken,FALSE)=FALSE GROUP BY pod_product_id),
  contrib AS (
    SELECT bp.product_id AS boonz_product_id, bp.boonz_product_name, bp.units_per_box, pp.pod_product_name,
      pp.product_category, pm.split_pct, ps.sales_14d AS pod_sales,
      ROUND(ps.sales_14d * pm.split_pct / 100, 0) AS attributed,
      ROUND(COALESCE(mc.pod_machine_stock,0) * pm.split_pct / 100, 0) AS attributed_machine,
      COALESCE(pm.source_of_supply,'boonz') AS source_of_supply
    FROM pod_sales ps
    JOIN public.pod_products pp ON pp.pod_product_id=ps.pod_product_id
    JOIN public.product_mapping pm ON pm.pod_product_id=pp.pod_product_id AND pm.status='Active'
      AND pm.is_global_default=TRUE AND (p_source IS NULL OR COALESCE(pm.source_of_supply,'boonz')=p_source)
    JOIN public.boonz_products bp ON bp.product_id=pm.boonz_product_id
    LEFT JOIN machine mc ON mc.pod_product_id=ps.pod_product_id),
  agg AS (
    SELECT boonz_product_id, boonz_product_name, source_of_supply, MAX(units_per_box) units_per_box,
      MAX(product_category) product_category,
      STRING_AGG(DISTINCT pod_product_name, ', ' ORDER BY pod_product_name) pod_product_name,
      CASE WHEN COUNT(*)=1 THEN MAX(split_pct) ELSE NULL END split_pct,
      CASE WHEN COUNT(*)=1 THEN MAX(pod_sales) ELSE SUM(attributed) END sales_14d,
      SUM(attributed) variant_demand_14d, SUM(attributed_machine) machine_stock
    FROM contrib GROUP BY boonz_product_id, boonz_product_name, source_of_supply),
  calc AS (
    SELECT a.*, COALESCE(w.wh_stock,0) wh_stock,
      GREATEST(0, a.variant_demand_14d - COALESCE(w.wh_stock,0) - a.machine_stock) gap
    FROM agg a LEFT JOIN wh w ON w.boonz_product_id=a.boonz_product_id)
SELECT boonz_product_id, boonz_product_name, pod_product_name, product_category, split_pct, sales_14d,
  variant_demand_14d, wh_stock, machine_stock, gap,
  CASE WHEN units_per_box IS NOT NULL AND units_per_box>0
    THEN CEIL(CEIL(gap*(1+p_buffer_pct))/units_per_box::numeric)*units_per_box
    ELSE CEIL(gap*(1+p_buffer_pct)) END AS suggested_qty,
  units_per_box, source_of_supply
FROM calc WHERE gap>0 ORDER BY gap DESC;
$function$;