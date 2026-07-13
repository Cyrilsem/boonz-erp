CREATE OR REPLACE FUNCTION public.find_substitutes_for_shelf(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_anchor_pod_product_id uuid, p_top_n integer DEFAULT 5, p_aggressiveness_pct integer DEFAULT 50)
 RETURNS TABLE(rank integer, pod_product_id uuid, pod_product_name text, pearson_score numeric, source text, wh_stock_units numeric, reason text)
 LANGUAGE plpgsql
 STABLE
AS $function$
#variable_conflict use_column
DECLARE
  v_loc_type text;
  v_wh_pri   uuid;
  v_wh_sec   uuid;
BEGIN
  IF p_anchor_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'p_anchor_pod_product_id is required';
  END IF;
  SELECT m.location_type, m.primary_warehouse_id, m.secondary_warehouse_id
    INTO v_loc_type, v_wh_pri, v_wh_sec
    FROM public.machines m WHERE m.machine_id = p_machine_id;

  RETURN QUERY
  WITH present AS (
    SELECT sl.pod_product_id FROM public.slot_lifecycle sl
     WHERE sl.machine_id = p_machine_id AND sl.archived = false AND sl.is_current = true
    UNION
    SELECT vls.pod_product_id FROM public.v_live_shelf_stock vls
     WHERE vls.machine_id = p_machine_id AND vls.pod_product_id IS NOT NULL AND vls.current_stock > 0
  ),
  basket AS (
    SELECT sl.pod_product_id FROM public.slot_lifecycle sl
     WHERE sl.machine_id = p_machine_id AND sl.archived = false AND sl.is_current = true
       AND (COALESCE(sl.velocity_7d,0) > 0 OR COALESCE(sl.velocity_30d,0) > 0)
  ),
  global_perf AS (
    SELECT sl.pod_product_id, AVG(sl.velocity_30d)::numeric AS global_v30
    FROM public.slot_lifecycle sl
    WHERE sl.archived = false AND sl.is_current = true
    GROUP BY sl.pod_product_id
  ),
  wh AS (
    -- p0_fix13: real pickable units per pod for THIS machine.
    -- Dedupe: DISTINCT (pod, boonz) mapping pairs guarantee each wh_inventory_id
    -- row is summed at most once per pod (no multi-mapping-row inflation).
    -- Scope: only the machine's primary/secondary warehouses, and rows not
    -- reserved for another machine.
    SELECT pm.pod_product_id, SUM(wi.warehouse_stock)::numeric AS wh_stock
    FROM (
      SELECT DISTINCT pm0.pod_product_id, pm0.boonz_product_id
      FROM public.product_mapping pm0
      WHERE pm0.status = 'Active'
        AND (pm0.machine_id IS NULL OR pm0.machine_id = p_machine_id)
    ) pm
    JOIN public.warehouse_inventory wi
      ON wi.boonz_product_id = pm.boonz_product_id AND wi.status = 'Active' AND wi.quarantined = false
     AND (wi.expiration_date >= CURRENT_DATE OR wi.expiration_date IS NULL)
     AND wi.warehouse_id IN (v_wh_pri, v_wh_sec)
     AND (wi.reserved_for_machine_id IS NULL OR wi.reserved_for_machine_id = p_machine_id)
    GROUP BY pm.pod_product_id
  ),
  cand AS (
    SELECT gp.pod_product_id AS cand, gp.global_v30, w.wh_stock
    FROM global_perf gp
    JOIN wh w ON w.pod_product_id = gp.pod_product_id AND w.wh_stock > 0
    JOIN public.pod_products pp ON pp.pod_product_id = gp.pod_product_id AND COALESCE(pp.is_catchall,false) = false
    WHERE gp.pod_product_id <> p_anchor_pod_product_id
      AND gp.global_v30 > 0
      AND gp.pod_product_id NOT IN (SELECT pod_product_id FROM present)
      -- p0_fix13: never recommend a product under an active decommission intent
      -- (mirrors engine_add_pod's blocked_intents identification)
      AND NOT EXISTS (
        SELECT 1 FROM public.strategic_intents si
         WHERE si.intent_type = 'decommission'
           AND si.status IN ('queued','in_progress')
           AND si.scope_pod_product_id = gp.pod_product_id
      )
  ),
  scored AS (
    SELECT c.cand, c.global_v30, c.wh_stock,
      COALESCE(
        (SELECT AVG(cm.pearson) FROM public.correlation_pod_per_machine cm
          WHERE cm.machine_id = p_machine_id AND cm.pod_product_b = c.cand
            AND cm.pod_product_a IN (SELECT pod_product_id FROM basket)),
        (SELECT AVG(cl.pearson) FROM public.correlation_pod_per_loc_type cl
          WHERE cl.location_type = v_loc_type AND cl.pod_product_b = c.cand
            AND cl.pod_product_a IN (SELECT pod_product_id FROM basket))
      )::numeric AS basket_corr
    FROM cand c
  ),
  ranked AS (
    -- p0_fix13: volume-aware score = COALESCE(basket_corr, 0.05) * ln(1 + wh_stock_real),
    -- ranked DESC, tie-break global_v30 DESC (closest product with high REAL WH volume)
    SELECT ROW_NUMBER() OVER (ORDER BY (COALESCE(s.basket_corr, 0.05) * ln(1 + s.wh_stock)) DESC, s.global_v30 DESC) AS rk,
           s.cand, s.basket_corr, s.global_v30, s.wh_stock
    FROM scored s
  )
  SELECT
    r.rk::int                                                                  AS rank,
    r.cand                                                                     AS pod_product_id,
    pp.pod_product_name                                                        AS pod_product_name,
    ROUND(r.basket_corr,3)                                                     AS pearson_score,
    CASE WHEN r.basket_corr > 0 THEN 'global_basket_fit' ELSE 'global_performer' END AS source,
    r.wh_stock                                                                 AS wh_stock_units,
    CASE WHEN r.basket_corr > 0
         THEN 'Global performer; fits this machine''s basket (corr ' || ROUND(r.basket_corr,2) || ')'
         ELSE 'Global performer (' || ROUND(r.global_v30,2) || '/day fleet), in stock' END AS reason
  FROM ranked r
  JOIN public.pod_products pp ON pp.pod_product_id = r.cand
  WHERE r.rk <= p_top_n
  ORDER BY r.rk;
END $function$