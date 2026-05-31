-- PRD-015 Phase D / AC#4 — v_pod_inventory_shelf_mismatch (read).
-- Per (machine_id, shelf_id): compares the Active pod_inventory product (mapped to
-- pod_product_id via product_mapping global default) against v_live_shelf_stock.pod_product_id,
-- on RESOLVED IDs (never raw-name compare), de-duping pod fan-out. Shelf<->slot join mirrors
-- pick_machines_for_refill (slot_name = LEFT(code,1) || SUBSTR(code,2)::int). NOT YET APPLIED.

CREATE OR REPLACE VIEW public.v_pod_inventory_shelf_mismatch AS
WITH pod_active AS (
  SELECT pi.machine_id, pi.shelf_id,
         count(*) AS active_row_count,
         (array_agg(pi.boonz_product_id ORDER BY pi.snapshot_at DESC NULLS LAST))[1] AS pod_boonz_id
  FROM public.pod_inventory pi
  WHERE pi.status = 'Active' AND pi.shelf_id IS NOT NULL
  GROUP BY pi.machine_id, pi.shelf_id
),
pod_resolved AS (
  SELECT pa.*,
    (SELECT pm.pod_product_id FROM public.product_mapping pm
      WHERE pm.boonz_product_id = pa.pod_boonz_id
        AND pm.is_global_default = true AND pm.status = 'Active' LIMIT 1) AS pod_pp_id
  FROM pod_active pa
),
weimi AS (
  SELECT DISTINCT ON (sc.machine_id, sc.shelf_id)
    sc.machine_id, sc.shelf_id, sc.shelf_code,
    vls.pod_product_id AS weimi_pp_id, vls.match_method, vls.fill_pct, vls.goods_name_raw
  FROM public.shelf_configurations sc
  JOIN public.v_live_shelf_stock vls ON vls.machine_id = sc.machine_id
    AND vls.slot_name = LEFT(sc.shelf_code, 1) || (SUBSTR(sc.shelf_code, 2)::int)::text
  WHERE sc.is_phantom = false
  ORDER BY sc.machine_id, sc.shelf_id, vls.snapshot_at DESC NULLS LAST
),
joined AS (
  SELECT COALESCE(w.machine_id, pr.machine_id) AS machine_id,
         COALESCE(w.shelf_id, pr.shelf_id)     AS shelf_id,
         w.shelf_code, pr.active_row_count, pr.pod_pp_id,
         w.weimi_pp_id, w.match_method, w.fill_pct, w.goods_name_raw
  FROM pod_resolved pr
  FULL JOIN weimi w USING (machine_id, shelf_id)
)
SELECT
  j.machine_id, m.official_name AS machine, j.shelf_id, j.shelf_code,
  j.pod_pp_id, podp.pod_product_name AS pod_inventory_product,
  j.weimi_pp_id, weip.pod_product_name AS weimi_product,
  j.goods_name_raw, j.match_method, j.fill_pct,
  COALESCE(j.active_row_count, 0) AS active_row_count,
  CASE
    WHEN COALESCE(j.active_row_count, 0) > 1 THEN 'multi_active_rows'
    WHEN j.active_row_count IS NULL          THEN 'no_pod_row'
    WHEN j.weimi_pp_id IS NULL OR j.match_method = 'unmatched' THEN 'weimi_unmatched'
    WHEN j.pod_pp_id IS DISTINCT FROM j.weimi_pp_id THEN 'product_mismatch'
    ELSE 'ok'
  END AS verdict
FROM joined j
JOIN public.machines m            ON m.machine_id = j.machine_id
LEFT JOIN public.pod_products podp ON podp.pod_product_id = j.pod_pp_id
LEFT JOIN public.pod_products weip ON weip.pod_product_id = j.weimi_pp_id;

COMMENT ON VIEW public.v_pod_inventory_shelf_mismatch IS
  'PRD-015 AC#4: resolved-ID pod_inventory vs WEIMI shelf comparison. verdict in '
  '(product_mismatch|multi_active_rows|no_pod_row|weimi_unmatched|ok). Read-only diagnostic; '
  'reconcile via reconcile_pod_inventory_shelf (operator-confirmed, per-shelf).';
