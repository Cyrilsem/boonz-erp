-- PRD-119b T5 follow-up: the lane_mismatch class must only fire when the
-- shelf's CURRENT live product resolved to a real boonz_product_id. When
-- v_live_shelf_stock's raw WEIMI name doesn't match any pod_products row
-- (a name-resolution gap, the same bug class PRD-120 L3's
-- assert_sales_names_resolved already tracks -- NOT this task's scope),
-- lsp.boonz_product_id is NULL, and `IS DISTINCT FROM` treated every
-- Active lot on that shelf as a "mismatch" even when it's the exact same
-- product physically on the shelf. Verified live, fleet-wide: 852 raw
-- pod_inventory rows flagged before this fix; 123 of them (502 units) had
-- an unresolved lane product name, not a genuine identity mismatch. Fixed
-- by requiring lsp.boonz_product_id IS NOT NULL before comparing -- leaves
-- 729 genuine stranded-lot rows (3168 units) fleet-wide, reported to CS in
-- the PRD-119b report rather than silently dropped.
CREATE OR REPLACE FUNCTION public.get_machine_orphan_expiry(p_machine_name text)
RETURNS TABLE(
  boonz_product_id uuid,
  boonz_product text,
  units integer,
  nearest_expiry_days integer,
  expired_units integer,
  batches integer,
  reason text,
  shelf_id uuid,
  shelf_code text,
  lane_current_product text
)
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
  live_shelf_product AS (
    SELECT DISTINCT ON (sc.shelf_id)
      sc.shelf_id, sc.shelf_code, pm.boonz_product_id, TRIM(v.goods_name_raw) AS lane_product_name
    FROM public.v_live_shelf_stock v
    JOIN public.shelf_configurations sc
      ON sc.machine_id = v.machine_id AND sc.is_phantom = false
     AND v.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text
    LEFT JOIN public.pod_products pp ON LOWER(TRIM(pp.pod_product_name)) = LOWER(TRIM(v.goods_name_raw))
    LEFT JOIN public.product_mapping pm ON pm.pod_product_id = pp.pod_product_id AND pm.status = 'Active'
    WHERE v.machine_id = (SELECT machine_id FROM machine) AND v.is_enabled
    ORDER BY sc.shelf_id, pm.boonz_product_id NULLS LAST
  ),
  live_shelf AS (
    SELECT DISTINCT shelf_id FROM live_shelf_product
  ),
  live_boonz AS (
    SELECT DISTINCT boonz_product_id FROM live_shelf_product WHERE boonz_product_id IS NOT NULL
  ),
  unassigned AS (
    SELECT b.boonz_product_id, bp.boonz_product_name AS boonz_product,
      SUM(b.current_stock)::int AS units,
      (MIN(b.expiration_date) FILTER (WHERE b.expiration_date IS NOT NULL) - (SELECT today FROM dubai))::int AS nearest_expiry_days,
      SUM(CASE WHEN b.expiration_date <= (SELECT today FROM dubai) THEN b.current_stock ELSE 0 END)::int AS expired_units,
      COUNT(*)::int AS batches,
      'unassigned'::text AS reason,
      NULL::uuid AS shelf_id,
      NULL::text AS shelf_code,
      NULL::text AS lane_current_product
    FROM public.v_machine_expiry_batches b
    LEFT JOIN public.boonz_products bp ON bp.product_id = b.boonz_product_id
    WHERE b.machine_id = (SELECT machine_id FROM machine)
      AND (b.shelf_id IS NULL OR b.shelf_id NOT IN (SELECT shelf_id FROM live_shelf))
      AND b.boonz_product_id NOT IN (SELECT boonz_product_id FROM live_boonz)
    GROUP BY b.boonz_product_id, bp.boonz_product_name
  ),
  lane_mismatch AS (
    SELECT b.boonz_product_id, bp.boonz_product_name AS boonz_product,
      SUM(b.current_stock)::int AS units,
      (MIN(b.expiration_date) FILTER (WHERE b.expiration_date IS NOT NULL) - (SELECT today FROM dubai))::int AS nearest_expiry_days,
      SUM(CASE WHEN b.expiration_date <= (SELECT today FROM dubai) THEN b.current_stock ELSE 0 END)::int AS expired_units,
      COUNT(*)::int AS batches,
      'lane_mismatch'::text AS reason,
      b.shelf_id,
      lsp.shelf_code,
      lsp.lane_product_name AS lane_current_product
    FROM public.v_machine_expiry_batches b
    JOIN live_shelf_product lsp ON lsp.shelf_id = b.shelf_id
    LEFT JOIN public.boonz_products bp ON bp.product_id = b.boonz_product_id
    WHERE b.machine_id = (SELECT machine_id FROM machine)
      AND lsp.boonz_product_id IS NOT NULL
      AND lsp.boonz_product_id IS DISTINCT FROM b.boonz_product_id
    GROUP BY b.boonz_product_id, bp.boonz_product_name, b.shelf_id, lsp.shelf_code, lsp.lane_product_name
  )
  SELECT * FROM unassigned
  UNION ALL
  SELECT * FROM lane_mismatch
  ORDER BY units DESC;
$function$;
