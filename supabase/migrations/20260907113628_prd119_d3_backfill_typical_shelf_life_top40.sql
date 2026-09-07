-- PRD-119 D3: backfill boonz_products.typical_shelf_life_days for the
-- top 40 SKUs by 90-day sales volume (resolved via v_sales_history_resolved
-- -> product_mapping, Active mappings, machine-agnostic since this is a
-- product-level constant not a per-machine one), from the MEDIAN observed
-- (expiration_date - created_at::date) across that product's real
-- warehouse_inventory history. Excludes the 2099-12-31 sentinel (venue/
-- placeholder rows, not real shelf-life data) and any row where
-- expiration_date <= created_at (a data artifact, not a real interval).
--
-- Minimum sample size: 3 historical rows. 30 of the top 40 met this bar and
-- were backfilled (median 38-440 days depending on product; e.g. Coca Cola
-- - Zero 149d/n=42, Nestle Kit-kat - Regular 230d/n=16, Activia Mix & Go
-- - Greek Yogurt Honey & Oats 38d/n=29 -- a real, expected short shelf life
-- for a chilled yogurt product, sanity-checked before applying). 10 of 40
-- had zero matching warehouse_inventory rows at all (Aquafina, Arwa Water,
-- M&M Chocolate Bag, VOX Popcorn x3, VOX Lollies, VOX Cotton Candy,
-- Skittles Bag, LevelUp Al Ain Water) -- these are venue/consignment-heavy
-- or always-2099-sentinel products with no real warehouse receipt history
-- to compute a median from; left NULL rather than guessed. No SKU beyond
-- the top 40 is touched.
--
-- Cody: approve, Article 12 (one-time, idempotent-by-value backfill; safe
-- to re-run, would recompute the same medians from the same history).
UPDATE public.boonz_products bp
SET typical_shelf_life_days = ROUND(s.median_days)::int
FROM (
  WITH top40 AS (
    WITH resolved AS (
      SELECT vshr.pod_product_id, sh.qty
      FROM sales_history sh
      JOIN v_sales_history_resolved vshr ON vshr.transaction_id = sh.transaction_id
      WHERE sh.delivery_status IN ('Success','Successful')
        AND sh.transaction_date >= now() - interval '90 days'
        AND vshr.pod_product_id IS NOT NULL
    ),
    pod_totals AS (
      SELECT pod_product_id, SUM(qty) AS units_90d FROM resolved GROUP BY pod_product_id
    ),
    pod_to_boonz AS (
      SELECT DISTINCT ON (pm.pod_product_id) pm.pod_product_id, pm.boonz_product_id
      FROM public.product_mapping pm WHERE pm.status='Active'
      ORDER BY pm.pod_product_id, pm.is_global_default DESC, pm.split_pct DESC NULLS LAST
    ),
    boonz_totals AS (
      SELECT p2b.boonz_product_id, SUM(pt.units_90d) AS units_90d
      FROM pod_totals pt JOIN pod_to_boonz p2b ON p2b.pod_product_id = pt.pod_product_id
      GROUP BY p2b.boonz_product_id
    )
    SELECT boonz_product_id, units_90d FROM boonz_totals ORDER BY units_90d DESC LIMIT 40
  ),
  samples AS (
    SELECT t.boonz_product_id, wi.expiration_date - wi.created_at::date AS shelf_life_days
    FROM top40 t
    JOIN public.warehouse_inventory wi ON wi.boonz_product_id = t.boonz_product_id
    WHERE wi.expiration_date IS NOT NULL AND wi.created_at IS NOT NULL
      AND wi.expiration_date <> DATE '2099-12-31'
      AND wi.expiration_date > wi.created_at::date
  )
  SELECT boonz_product_id, count(*) AS n, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY shelf_life_days) AS median_days
  FROM samples GROUP BY boonz_product_id HAVING count(*) >= 3
) s
WHERE bp.product_id = s.boonz_product_id;
