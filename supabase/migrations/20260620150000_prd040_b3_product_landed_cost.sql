-- PRD-040 B3 (part 1 of 2): canonical product landed-cost source for the value model.
-- Forward-only, read-only view. No writes, no _v2. Article 16: ONE canonical cost object the engine consumes.
-- CS decisions 2026-06-20: 4-source coalesce + category-median (physical_type) impute for the costless.
--
-- Coverage (validated read-only): coalesce(avg_30days_cost, avg_cost, AVG(product_mapping.avg_cost),
-- AVG(pod_products.purchasing_cost)) = 249/307; physical_type-median impute closes the rest -> 307/307, 0 costless.
--
-- PART 2 (separate migration, value-model-affecting): engine_swap_pod V() consumes landed_cost in place of the
-- inline `price - avg_30days_cost` proxy (incumbent KEEP cap + candidate margin). engine_add_pod is UNTOUCHED
-- (PRD-035 made ADD qty stance-free / velocity-driven; it does not consume margin -> T12 holds). Part 2 requires
-- the full PRD-039 (U/U/C/C/A/A/H + R1) + PRD-037 (T1-T13) value-model replay before apply.

CREATE OR REPLACE VIEW public.v_product_landed_cost AS
  WITH base AS (
    SELECT bp.product_id AS boonz_product_id, bp.physical_type,
      COALESCE(
        NULLIF(bp.avg_30days_cost, 0),
        NULLIF(bp.avg_cost, 0),
        (SELECT NULLIF(AVG(NULLIF(pm.avg_cost, 0)), 0) FROM public.product_mapping pm
          WHERE pm.boonz_product_id = bp.product_id AND pm.status = 'Active'),
        (SELECT NULLIF(AVG(NULLIF(pp.purchasing_cost, 0)), 0) FROM public.product_mapping pm
          JOIN public.pod_products pp ON pp.pod_product_id = pm.pod_product_id
          WHERE pm.boonz_product_id = bp.product_id AND pm.status = 'Active')
      ) AS coalesced_cost
    FROM public.boonz_products bp
  ),
  cat_median AS (
    SELECT physical_type, percentile_cont(0.5) WITHIN GROUP (ORDER BY coalesced_cost) AS med
    FROM base WHERE coalesced_cost > 0 GROUP BY physical_type
  )
  SELECT b.boonz_product_id, b.physical_type,
         b.coalesced_cost,
         cm.med AS category_median_cost,
         COALESCE(b.coalesced_cost, cm.med) AS landed_cost,
         CASE WHEN b.coalesced_cost > 0 THEN 'sourced' ELSE 'imputed_category_median' END AS cost_basis
  FROM base b LEFT JOIN cat_median cm ON cm.physical_type = b.physical_type;

COMMENT ON VIEW public.v_product_landed_cost IS
  'PRD-040 B3 canonical landed cost per boonz product. landed_cost = COALESCE(avg_30days_cost, avg_cost, '
  'AVG(product_mapping.avg_cost), AVG(pod_products.purchasing_cost), physical_type median). cost_basis flags '
  'sourced vs imputed. 307/307 coverage. The value model (engine_swap_pod V()) consumes landed_cost; margin = price - landed_cost.';

-- Read-only; no RLS needed beyond the underlying tables (security_invoker view semantics). GRANT for consumers.
GRANT SELECT ON public.v_product_landed_cost TO authenticated, service_role;
