-- REPO HYGIENE RECONSTRUCTION (see the reconciliation audit that added this file).
--
-- supabase_migrations.schema_migrations records this exact version (20260921125938) under the
-- name "prd129_02a_sales_history_resolved_name_map", applied live. It was applied inline via
-- the migration tool during the PRD-129 session and never saved to a file at the time --
-- disclosed as a known gap in that session's own final report.
--
-- v_sales_history_resolved was previously a per-row correlated LIMIT-1 scalar subquery (tier 1:
-- exact/case-insensitive pod_product_name match; tier 2: via product_name_conventions ->
-- official_name -> pod_products), no set-based join, roughly 588ms per resolution when driven
-- per-machine. Rewritten as a name_map CTE (tier 1) + nm_convention CTE (tier 2, DISTINCT ON
-- dedup for duplicate lowered original_name values) + a final SELECT with LEFT JOIN and a
-- NOT EXISTS clause preserving tier-1-before-tier-2 precedence. Verified equivalent to the old
-- logic on all sales_history rows in the 90 days prior to applying, zero mismatches, before this
-- was applied.
--
-- Fully recoverable and faithful: this view has not been modified by any later migration, so its
-- current live definition (pulled via pg_get_viewdef immediately before writing this file) is
-- exactly what this migration created.

CREATE OR REPLACE VIEW public.v_sales_history_resolved AS
WITH name_map AS (
  SELECT lower(TRIM(pp.pod_product_name)) AS name_lower, pp.pod_product_id
  FROM public.pod_products pp
),
nm_convention AS (
  SELECT DISTINCT ON (lower(TRIM(pnc.original_name)))
    lower(TRIM(pnc.original_name)) AS name_lower, pp.pod_product_id
  FROM public.product_name_conventions pnc
  JOIN public.pod_products pp ON lower(TRIM(pp.pod_product_name)) = lower(TRIM(pnc.official_name))
  ORDER BY lower(TRIM(pnc.original_name)), pp.pod_product_id
)
SELECT sh.transaction_id,
  sh.machine_id,
  COALESCE(nm1.pod_product_id, nm2.pod_product_id) AS pod_product_id,
  sh.transaction_date,
  sh.qty,
  sh.delivery_status
FROM public.sales_history sh
LEFT JOIN name_map nm1 ON nm1.name_lower = lower(TRIM(sh.pod_product_name))
LEFT JOIN nm_convention nm2 ON nm2.name_lower = lower(TRIM(sh.pod_product_name))
  AND NOT EXISTS (SELECT 1 FROM name_map nm1x WHERE nm1x.name_lower = lower(TRIM(sh.pod_product_name)));
