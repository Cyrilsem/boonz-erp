-- PRD-105 Expiry Truth at Shelf Grain — Change 3 (RC-4)
-- Extend the orphan reader: surface batches whose shelf_id is NULL OR whose
-- shelf_id is not present in the machine's live WEIMI aisle (ghost shelves that
-- are counted in the KPI but invisible in both drawer and orphan panel).
-- Keeps the existing boonz_product_id NOT IN live_boonz exclusion.
-- Replaced-body md5 (byte-identical rollback): e5e19b3cef7a2a6fcc504940410c4077
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
  live_shelf AS (
    SELECT DISTINCT sc.shelf_id
    FROM public.v_live_shelf_stock v
    JOIN public.shelf_configurations sc
      ON sc.machine_id = v.machine_id AND sc.is_phantom = false
     AND v.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text
    WHERE v.machine_id = (SELECT machine_id FROM machine)
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
    AND (b.shelf_id IS NULL OR b.shelf_id NOT IN (SELECT shelf_id FROM live_shelf))
    AND b.boonz_product_id NOT IN (SELECT boonz_product_id FROM live_boonz)
  GROUP BY b.boonz_product_id, bp.boonz_product_name
  ORDER BY units DESC;
$function$
;
