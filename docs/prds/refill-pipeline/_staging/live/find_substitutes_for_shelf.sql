CREATE OR REPLACE FUNCTION public.find_substitutes_for_shelf(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_anchor_pod_product_id uuid, p_top_n integer DEFAULT 5, p_aggressiveness_pct integer DEFAULT 50)
 RETURNS TABLE(rank integer, pod_product_id uuid, pod_product_name text, pearson_score numeric, source text, wh_stock_units numeric, reason text)
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
DECLARE
  v_loc_type     text;
  v_agg          int := GREATEST(0, LEAST(100, COALESCE(p_aggressiveness_pct, 50)));
  v_include_loc  boolean := v_agg >= 34;
  v_include_cat  boolean := v_agg >= 67;
BEGIN
  IF p_anchor_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'p_anchor_pod_product_id is required';
  END IF;

  SELECT m.location_type INTO v_loc_type
  FROM public.machines m
  WHERE m.machine_id = p_machine_id;

  RETURN QUERY
  WITH candidates AS (
    SELECT cp.pod_product_b AS cand, cp.pearson AS score, 'machine'::text AS src
    FROM public.correlation_pod_per_machine cp
    WHERE cp.machine_id = p_machine_id
      AND cp.pod_product_a = p_anchor_pod_product_id
      AND cp.pod_product_b != p_anchor_pod_product_id
    UNION ALL
    SELECT cp.pod_product_b, cp.pearson, 'loc_type'::text
    FROM public.correlation_pod_per_loc_type cp
    WHERE v_include_loc
      AND cp.location_type = v_loc_type
      AND cp.pod_product_a = p_anchor_pod_product_id
      AND cp.pod_product_b != p_anchor_pod_product_id
    UNION ALL
    SELECT pp.pod_product_id, 0::numeric, 'category_fallback'::text
    FROM public.pod_products pp
    WHERE v_include_cat
      AND pp.product_category = (SELECT pp2.product_category FROM public.pod_products pp2 WHERE pp2.pod_product_id = p_anchor_pod_product_id)
      AND pp.pod_product_id != p_anchor_pod_product_id
      AND COALESCE(pp.is_catchall, false) = false
  ),
  ranked AS (
    SELECT
      ROW_NUMBER() OVER (ORDER BY
        CASE c.src WHEN 'machine' THEN 1 WHEN 'loc_type' THEN 2 ELSE 3 END,
        c.score DESC NULLS LAST
      ) AS rk,
      c.cand, c.score, c.src
    FROM candidates c
  )
  SELECT
    r.rk::int                                                                  AS rank,
    r.cand                                                                     AS pod_product_id,
    pp.pod_product_name                                                        AS pod_product_name,
    r.score                                                                    AS pearson_score,
    r.src                                                                      AS source,
    COALESCE(SUM(wi.warehouse_stock + COALESCE(wi.consumer_stock, 0)), 0)::numeric AS wh_stock_units,
    CASE
      WHEN r.src = 'machine'  THEN 'Co-purchase on this machine'
      WHEN r.src = 'loc_type' THEN 'Co-purchase across ' || COALESCE(v_loc_type, 'location_type') || ' machines'
      ELSE 'Same category, no co-purchase signal'
    END                                                                        AS reason
  FROM ranked r
  JOIN public.pod_products pp ON pp.pod_product_id = r.cand
  LEFT JOIN public.product_mapping pm ON pm.pod_product_id = r.cand
  LEFT JOIN public.warehouse_inventory wi
    ON wi.boonz_product_id = pm.boonz_product_id AND wi.status = 'Active'
  WHERE r.rk <= p_top_n
  GROUP BY r.rk, r.cand, pp.pod_product_name, r.score, r.src, v_loc_type
  ORDER BY r.rk;
END $function$
