-- ============================================================================
-- PRD-REFILL-V2 · Item 2 reco fix · find_substitutes_for_shelf -> global-performer-first
-- ============================================================================
-- WHY: the live version anchors candidates on co-purchase correlation WITH THE
--   REMOVED product. A dead/new product has little or no co-purchase signal, so on
--   2026-06-09 it returned ZERO candidates for 2 of 3 dead shelves (Starbucks Ice
--   Coffee, Plaay Truffles) -> those shelves would fall to M2W and sit empty.
--   CS intent: "a product performing globally that we don't have -> worth having it;
--   correlation/Pearson as refinement." So the backbone becomes global performance.
--
-- NEW LOGIC (same signature + return columns; read-only, SECURITY INVOKER, STABLE):
--   candidate pool = pod products that (a) perform globally (fleet avg velocity_30d > 0),
--   (b) are NOT already in this machine, (c) have REAL warehouse stock (warehouse_stock
--   only — consumer_stock/in-transit excluded), (d) are not the anchor, not catchall.
--   ranked by: correlation-to-THIS-machine's-basket DESC (machine corr, fallback
--   loc_type corr) then global velocity DESC then WH stock DESC.
--   -> always returns strong, in-stock, machine-novel candidates; correlation only
--      reorders them for fit. p_aggressiveness_pct retained for signature compat (unused).
--
-- GOVERNANCE: read-only helper (Article 4 INVOKER). No protected-entity write. Same
--   columns -> FE "find a better substitute" + engine_swap_pod v10 both consume unchanged.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.find_substitutes_for_shelf(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_anchor_pod_product_id uuid, p_top_n integer DEFAULT 5, p_aggressiveness_pct integer DEFAULT 50)
 RETURNS TABLE(rank integer, pod_product_id uuid, pod_product_name text, pearson_score numeric, source text, wh_stock_units numeric, reason text)
 LANGUAGE plpgsql
 STABLE
AS $function$
#variable_conflict use_column
DECLARE
  v_loc_type text;
BEGIN
  IF p_anchor_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'p_anchor_pod_product_id is required';
  END IF;
  SELECT m.location_type INTO v_loc_type FROM public.machines m WHERE m.machine_id = p_machine_id;

  RETURN QUERY
  WITH present AS (   -- already in this machine -> exclude
    SELECT sl.pod_product_id FROM public.slot_lifecycle sl
     WHERE sl.machine_id = p_machine_id AND sl.archived = false AND sl.is_current = true
    UNION
    SELECT vls.pod_product_id FROM public.v_live_shelf_stock vls
     WHERE vls.machine_id = p_machine_id AND vls.pod_product_id IS NOT NULL AND vls.current_stock > 0
  ),
  basket AS (        -- products that SELL in this machine -> correlation refinement target
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
  wh AS (            -- REAL warehouse stock only (transit/consumer_stock excluded)
    SELECT pm.pod_product_id, SUM(wi.warehouse_stock)::numeric AS wh_stock
    FROM public.product_mapping pm
    JOIN public.warehouse_inventory wi
      ON wi.boonz_product_id = pm.boonz_product_id AND wi.status = 'Active' AND wi.quarantined = false
     AND (wi.expiration_date >= CURRENT_DATE OR wi.expiration_date IS NULL)
    WHERE pm.status = 'Active'
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
  ),
  scored AS (
    SELECT c.cand, c.global_v30, c.wh_stock,
      COALESCE(
        (SELECT AVG(cm.pearson) FROM public.correlation_pod_per_machine cm
          WHERE cm.machine_id = p_machine_id AND cm.pod_product_b = c.cand
            AND cm.pod_product_a IN (SELECT pod_product_id FROM basket)),
        (SELECT AVG(cl.pearson) FROM public.correlation_pod_per_loc_type cl
          WHERE cl.location_type = v_loc_type AND cl.pod_product_b = c.cand
            AND cl.pod_product_a IN (SELECT pod_product_id FROM basket)),
        0
      )::numeric AS basket_corr
    FROM cand c
  ),
  ranked AS (
    SELECT ROW_NUMBER() OVER (ORDER BY s.basket_corr DESC NULLS LAST, s.global_v30 DESC, s.wh_stock DESC) AS rk,
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
END $function$;