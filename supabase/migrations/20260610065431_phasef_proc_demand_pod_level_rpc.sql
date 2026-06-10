-- PRD-3 (Procurement Brain v3) — pod-level demand RPC.
-- Migration name: phasef_proc_demand_pod_level_rpc
-- Articles: 4 (read-only DEFINER, validated), 1 (no writes — pure reader over canonical sources).
--
-- get_procurement_demand_pod returns demand at the pod_product level — i.e. the sales reality
-- BEFORE the mix_weight trickle-down that get_procurement_demand collapses into boonz rows.
-- Same pod-sales window and same demand_context_factors machinery as the boonz RPC (v3), so the
-- two tabs reconcile. Each pod row carries a pod_breakdown jsonb of its mapped boonz variants
-- (mix_weight, attributed qty, source, and PRD-1 block_reason) for the FE "Pod demand" sub-tab.
--
-- Read-only. SECURITY DEFINER to match get_procurement_demand (RLS-independent read over
-- v_sales_history_resolved / product_mapping / pod_products / boonz_products / demand_context_factors).
-- No writes anywhere in the body.

CREATE OR REPLACE FUNCTION public.get_procurement_demand_pod(
  p_lookback_days integer DEFAULT 14,
  p_source        text    DEFAULT 'boonz'
)
RETURNS TABLE(
  pod_product_id       uuid,
  pod_product_name     text,
  product_category     text,
  sales_14d            numeric,
  velocity_per_day     numeric,
  ctx_multiplier       numeric,
  forecast_demand      numeric,
  mapped_variant_count integer,
  pod_breakdown        jsonb
)
LANGUAGE sql
STABLE
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
  -- demand_context_factors active in the next p_lookback_days window (identical to v3).
  fac AS (
    SELECT
      scope_type, product_category, boonz_product_id, multiplier,
      (LEAST(ends_on, CURRENT_DATE + (p_lookback_days - 1))
       - GREATEST(starts_on, CURRENT_DATE) + 1)::numeric AS overlap_days
    FROM public.demand_context_factors
    WHERE ends_on >= CURRENT_DATE
      AND starts_on <= CURRENT_DATE + (p_lookback_days - 1)
  ),
  -- Active global-default mappings for the pod, filtered by the Boonz/VOX source toggle.
  pm_src AS (
    SELECT
      pm.pod_product_id,
      pm.boonz_product_id,
      pm.mix_weight,
      pm.split_pct,
      COALESCE(pm.source_of_supply, 'boonz') AS source_of_supply,
      bp.boonz_product_name
    FROM public.product_mapping pm
    JOIN public.boonz_products bp ON bp.product_id = pm.boonz_product_id
    WHERE pm.status = 'Active'
      AND pm.is_global_default = TRUE
      AND (p_source IS NULL OR COALESCE(pm.source_of_supply, 'boonz') = p_source)
  ),
  base AS (
    SELECT
      pp.pod_product_id,
      pp.pod_product_name,
      pp.product_category,
      ps.sales_14d
    FROM pod_sales ps
    JOIN public.pod_products pp ON pp.pod_product_id = ps.pod_product_id
    WHERE EXISTS (SELECT 1 FROM pm_src m WHERE m.pod_product_id = ps.pod_product_id)
  ),
  -- Pod-level context resolves category > global > 1 (the boonz_product scope of v3 has no
  -- single pod analogue — a pod fans out to many boonz variants — so category is the pod tier).
  ctx AS (
    SELECT
      b.pod_product_id,
      COALESCE(
        (SELECT 1 + SUM((f.multiplier - 1) * f.overlap_days / p_lookback_days)
         FROM fac f WHERE f.scope_type = 'category' AND f.product_category = b.product_category),
        (SELECT 1 + SUM((f.multiplier - 1) * f.overlap_days / p_lookback_days)
         FROM fac f WHERE f.scope_type = 'global'),
        1
      ) AS ctx_multiplier
    FROM base b
  )
SELECT
  b.pod_product_id,
  b.pod_product_name,
  b.product_category,
  b.sales_14d,
  ROUND(b.sales_14d / NULLIF(p_lookback_days, 0), 2)        AS velocity_per_day,
  ROUND(c.ctx_multiplier, 3)                                AS ctx_multiplier,
  ROUND(b.sales_14d * c.ctx_multiplier, 0)                  AS forecast_demand,
  (SELECT COUNT(*)::int FROM pm_src m WHERE m.pod_product_id = b.pod_product_id) AS mapped_variant_count,
  (SELECT jsonb_agg(jsonb_build_object(
            'boonz_product_id',   m.boonz_product_id,
            'boonz_product_name', m.boonz_product_name,
            'mix_weight',         m.mix_weight,
            'split_pct',          m.split_pct,
            'source_of_supply',   m.source_of_supply,
            'attributed_14d',     ROUND(b.sales_14d * m.mix_weight, 0),
            'block_reason',       public.boonz_product_block_reason(m.boonz_product_id)
          ) ORDER BY m.mix_weight DESC NULLS LAST)
     FROM pm_src m WHERE m.pod_product_id = b.pod_product_id)  AS pod_breakdown
FROM base b
JOIN ctx c ON c.pod_product_id = b.pod_product_id
ORDER BY forecast_demand DESC;
$function$;

GRANT EXECUTE ON FUNCTION public.get_procurement_demand_pod(integer, text) TO authenticated, service_role;

COMMENT ON FUNCTION public.get_procurement_demand_pod(integer, text) IS
  'PRD-3. Read-only pod_product-level demand (sales, velocity/day, category-context multiplier, forecast) BEFORE mix_weight trickle-down, with a pod_breakdown jsonb of mapped boonz variants (incl. PRD-1 block_reason). Powers the /app/procurement Demand "Pod demand" sub-tab. Reconciles with get_procurement_demand (same window + context factors). p_source = Boonz/VOX toggle.';
