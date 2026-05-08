-- Phase B.7: Product first-seen view (sales OR snapshot, whichever is earlier).
-- Used by evaluate-lifecycle to compute PRODUCT_RAMPING grace period.
CREATE OR REPLACE VIEW public.v_product_first_seen AS
WITH sales_first AS (
  SELECT pp.pod_product_id, MIN(sh.transaction_date) AS first_sale_at
  FROM public.pod_products pp
  LEFT JOIN public.sales_history sh
    ON lower(regexp_replace(trim(coalesce(sh.pod_product_name,'')), '\s+', ' ', 'g'))
     = lower(regexp_replace(trim(pp.pod_product_name), '\s+', ' ', 'g'))
    AND sh.delivery_status = 'Successful'
  GROUP BY pp.pod_product_id
),
snap_first AS (
  SELECT pp.pod_product_id, MIN(ws.snapshot_at) AS first_snapshot_at
  FROM public.pod_products pp
  LEFT JOIN public.weimi_aisle_snapshots ws
    ON lower(regexp_replace(trim(coalesce(ws.product_name,'')), '\s+', ' ', 'g'))
     = lower(regexp_replace(trim(pp.pod_product_name), '\s+', ' ', 'g'))
  GROUP BY pp.pod_product_id
)
SELECT s.pod_product_id, s.first_sale_at, n.first_snapshot_at,
  LEAST(s.first_sale_at, n.first_snapshot_at) AS first_seen_at
FROM sales_first s JOIN snap_first n USING (pod_product_id);

ALTER VIEW public.v_product_first_seen SET (security_invoker = true);
