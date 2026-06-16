-- get_product_performance: add wh_available column (canonical WH pickable stock).
-- Adds per-product warehouse stock available, read from the canonical v_wh_pickable
-- (Article 16 WH-pickable object), summed per boonz variant and rolled up to each pod
-- product via DISTINCT active mappings. Signature change (new OUT column) requires
-- DROP + CREATE; sole caller is the /app/products Performance tab.
-- Constitution: Art 1, 3 (read-only), 4 (validates input+role), 12 (forward-only), 16
-- (reads canonical v_wh_pickable, no inline re-derivation).

DROP FUNCTION IF EXISTS public.get_product_performance(text, date);

CREATE FUNCTION public.get_product_performance(
  p_bucket text DEFAULT 'boonz',
  p_as_of  date DEFAULT (now() AT TIME ZONE 'Asia/Dubai')::date
)
RETURNS TABLE (
  rank         int,
  product      text,
  m3           int,
  m2           int,
  m1           int,
  mtd          int,
  expected     int,
  total_units  int,
  revenue      numeric,
  avg_price    numeric,
  wh_available numeric,
  month_labels text[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
  v_bucket text := lower(trim(coalesce(p_bucket, 'boonz')));
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = (SELECT auth.uid())
      AND up.role = ANY (ARRAY['operator_admin','superadmin','manager','warehouse'])
  ) THEN
    RAISE EXCEPTION 'get_product_performance: not authorized' USING ERRCODE = '42501';
  END IF;

  IF v_bucket NOT IN ('boonz','vox','all') THEN
    v_bucket := 'boonz';
  END IF;

  RETURN QUERY
  WITH params AS (
    SELECT
      v_bucket AS p_bucket,
      p_as_of  AS as_of,
      date_trunc('month', p_as_of)::date                          AS cur_start,
      (date_trunc('month', p_as_of) - interval '1 month')::date   AS m1s,
      (date_trunc('month', p_as_of) - interval '2 month')::date   AS m2s,
      (date_trunc('month', p_as_of) - interval '3 month')::date   AS m3s,
      (date_trunc('month', p_as_of) + interval '1 month')::date-1 AS month_end,
      (p_as_of - date_trunc('month', p_as_of)::date + 1)          AS elapsed
  ),
  cat_map AS (
    SELECT pod_name_key, boonz_product_id, product_category
    FROM (
      SELECT
        UPPER(TRIM(pp.pod_product_name)) AS pod_name_key,
        pm.boonz_product_id,
        bp.product_category,
        ROW_NUMBER() OVER (
          PARTITION BY UPPER(TRIM(pp.pod_product_name))
          ORDER BY SUM(COALESCE(pm.mix_weight, pm.split_pct, 0)) DESC, bp.product_category
        ) AS rn
      FROM product_mapping pm
      JOIN pod_products  pp ON pp.pod_product_id = pm.pod_product_id
      JOIN boonz_products bp ON bp.product_id     = pm.boonz_product_id
      WHERE pm.status = 'Active'
      GROUP BY UPPER(TRIM(pp.pod_product_name)), pm.boonz_product_id, bp.product_category
    ) z
    WHERE rn = 1
  ),
  -- canonical WH pickable stock (Article 16), summed per boonz variant
  wh AS (
    SELECT boonz_product_id, SUM(warehouse_stock)::numeric AS wh_units
    FROM v_wh_pickable
    GROUP BY boonz_product_id
  ),
  -- roll WH stock up to each pod product via DISTINCT active mappings (no fan-out)
  pod_wh AS (
    SELECT prod_key, SUM(wh_units) AS wh_available
    FROM (
      SELECT DISTINCT UPPER(TRIM(pp.pod_product_name)) AS prod_key, pm.boonz_product_id
      FROM product_mapping pm
      JOIN pod_products pp ON pp.pod_product_id = pm.pod_product_id
      WHERE pm.status = 'Active'
    ) d
    JOIN wh w ON w.boonz_product_id = d.boonz_product_id
    GROUP BY prod_key
  ),
  base AS (
    SELECT
      UPPER(TRIM(s.pod_product_name)) AS prod_key,
      TRIM(s.pod_product_name)        AS product,
      s.qty,
      s.total_amount,
      m.venue_group,
      s.machine_name,
      (s.transaction_date AT TIME ZONE 'Asia/Dubai')::date AS d_local,
      (UPPER(TRIM(s.pod_product_name)) IN (
        SELECT UPPER(TRIM(v.pod_product_name)) FROM vox_product_mapping v WHERE v.source_of_supply = 'VOX'
      )) AS prod_is_vox,
      (UPPER(TRIM(s.pod_product_name)) IN (
        SELECT UPPER(TRIM(v.pod_product_name)) FROM vox_product_mapping v WHERE v.source_of_supply = 'LLFP'
      )) AS prod_is_llfp
    FROM v_sales_transactions s
    JOIN machines m ON m.machine_id = s.machine_id
    WHERE s.delivery_status = 'Successful'
      AND TRIM(s.pod_product_name) <> 'Smart fridge'
  ),
  flt AS (
    SELECT b.*
    FROM base b, params p
    WHERE CASE p.p_bucket
      WHEN 'vox' THEN (b.venue_group = 'VOX' AND b.prod_is_vox)
      WHEN 'all' THEN true
      ELSE NOT (b.venue_group = 'VOX' AND b.prod_is_vox)
       AND NOT (b.machine_name LIKE 'LLFP%' AND b.prod_is_llfp)
    END
  ),
  agg AS (
    SELECT
      f.prod_key,
      MAX(f.product) AS product,
      COALESCE(SUM(f.qty) FILTER (WHERE f.d_local >= p.m3s AND f.d_local < p.m2s), 0)::int       AS m3,
      COALESCE(SUM(f.qty) FILTER (WHERE f.d_local >= p.m2s AND f.d_local < p.m1s), 0)::int       AS m2,
      COALESCE(SUM(f.qty) FILTER (WHERE f.d_local >= p.m1s AND f.d_local < p.cur_start), 0)::int AS m1,
      COALESCE(SUM(f.qty) FILTER (WHERE f.d_local >= p.cur_start AND f.d_local <= p.as_of), 0)::int AS mtd,
      COALESCE(SUM(f.qty) FILTER (WHERE f.d_local >= p.m3s AND f.d_local <= p.as_of), 0)::int    AS total_units,
      COALESCE(SUM(f.total_amount) FILTER (WHERE f.d_local >= p.m3s AND f.d_local <= p.as_of), 0) AS revenue
    FROM flt f, params p
    WHERE f.d_local >= p.m3s AND f.d_local <= p.as_of
    GROUP BY f.prod_key
  ),
  days AS (
    SELECT g::date AS day
    FROM params p, generate_series(p.as_of + 1, p.month_end, interval '1 day') g
  ),
  prod_day_factor AS (
    SELECT a.prod_key, d.day, COALESCE(EXP(SUM(LN(f.multiplier))), 1) AS day_factor
    FROM agg a
    LEFT JOIN cat_map cm ON cm.pod_name_key = a.prod_key
    CROSS JOIN days d
    LEFT JOIN demand_context_factors f
      ON d.day BETWEEN f.starts_on AND f.ends_on
     AND ( f.scope_type = 'global'
        OR (f.scope_type = 'category'      AND f.product_category  = cm.product_category)
        OR (f.scope_type = 'boonz_product' AND f.boonz_product_id  = cm.boonz_product_id) )
    GROUP BY a.prod_key, d.day
  ),
  prod_factor AS (
    SELECT prod_key, SUM(day_factor) AS factor_day_sum
    FROM prod_day_factor
    GROUP BY prod_key
  )
  SELECT
    ROW_NUMBER() OVER (ORDER BY a.total_units DESC, a.product)::int AS rank,
    a.product,
    a.m3, a.m2, a.m1, a.mtd,
    (a.mtd + round(
      (CASE WHEN p.elapsed > 0 THEN a.mtd::numeric / p.elapsed ELSE 0 END)
      * COALESCE(pf.factor_day_sum, 0)
    ))::int AS expected,
    a.total_units,
    round(a.revenue, 2) AS revenue,
    CASE WHEN a.total_units > 0 THEN round(a.revenue / a.total_units, 2) ELSE 0 END AS avg_price,
    COALESCE(pw.wh_available, 0) AS wh_available,
    ARRAY[to_char(p.m3s,'Mon'), to_char(p.m2s,'Mon'), to_char(p.m1s,'Mon')] AS month_labels
  FROM agg a
  CROSS JOIN params p
  LEFT JOIN prod_factor pf ON pf.prod_key = a.prod_key
  LEFT JOIN pod_wh pw      ON pw.prod_key = a.prod_key
  ORDER BY a.total_units DESC, a.product;
END;
$$;

REVOKE ALL ON FUNCTION public.get_product_performance(text, date) FROM public;
GRANT EXECUTE ON FUNCTION public.get_product_performance(text, date) TO authenticated;
