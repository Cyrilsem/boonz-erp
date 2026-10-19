-- Rollback for prd142b_c_retire_v_swap_candidate_ranking: recreates the PRD-005 view exactly as it was on prod
-- (definition from pg_get_viewdef on 2026-10-19, security_invoker = true, same grants).
CREATE VIEW public.v_swap_candidate_ranking WITH (security_invoker = true) AS
 WITH dead_or_rotating AS (
         SELECT sl.machine_id,
            sl.shelf_id,
            sl.pod_product_id,
            m.official_name AS machine_name,
            sc.shelf_code,
            pp.pod_product_name AS removed_pod_product
           FROM slot_lifecycle sl
             JOIN machines m ON m.machine_id = sl.machine_id
             JOIN shelf_configurations sc ON sc.shelf_id = sl.shelf_id
             JOIN pod_products pp ON pp.pod_product_id = sl.pod_product_id
          WHERE sl.signal = ANY (ARRAY['WIND DOWN'::text, 'ROTATE OUT'::text, 'DEAD'::text])
        ), candidates AS (
         SELECT d.machine_id,
            d.machine_name,
            d.shelf_id,
            d.shelf_code,
            d.pod_product_id AS removed_pod_product_id,
            d.removed_pod_product,
            sub.pod_product_id AS candidate_pod_product_id,
            sub.pod_product_name AS candidate_pod_product,
            sub.pearson_score,
            sub.source AS pearson_source,
            sub.wh_stock_units AS candidate_wh_stock
           FROM dead_or_rotating d
             CROSS JOIN LATERAL find_substitutes_for_shelf(CURRENT_DATE + 1, d.machine_id, d.shelf_id, d.pod_product_id, 10, 66) sub(rank, pod_product_id, pod_product_name, pearson_score, source, wh_stock_units, reason)
        ), candidate_dest AS (
         SELECT c.machine_id,
            c.machine_name,
            c.shelf_id,
            c.shelf_code,
            c.removed_pod_product_id,
            c.removed_pod_product,
            c.candidate_pod_product_id,
            c.candidate_pod_product,
            c.pearson_score,
            c.pearson_source,
            c.candidate_wh_stock,
            sc.max_capacity,
            COALESCE(( SELECT sum(pi.current_stock) AS sum
                   FROM pod_inventory pi
                  WHERE pi.machine_id = c.machine_id AND pi.shelf_id = c.shelf_id AND pi.status = 'Active'::text), 0::numeric) AS dest_shelf_current_stock
           FROM candidates c
             JOIN shelf_configurations sc ON sc.shelf_id = c.shelf_id
        )
 SELECT machine_id,
    machine_name,
    shelf_id,
    shelf_code,
    removed_pod_product_id,
    removed_pod_product,
    candidate_pod_product_id,
    candidate_pod_product,
    pearson_score,
    pearson_source,
    candidate_wh_stock,
    dest_shelf_current_stock,
    max_capacity,
        CASE
            WHEN max_capacity > 0 THEN dest_shelf_current_stock / max_capacity::numeric
            ELSE NULL::numeric
        END AS dest_shelf_fill_pct,
    COALESCE(pearson_score, 0::numeric) * 0.6 +
        CASE
            WHEN max_capacity > 0 THEN (1.0 - LEAST(dest_shelf_current_stock / max_capacity::numeric, 1.0)) * 25::numeric
            ELSE 0::numeric
        END + LEAST(COALESCE(candidate_wh_stock, 0::numeric) / 10.0, 1.0) * 15::numeric AS suggestion_score
   FROM candidate_dest;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.v_swap_candidate_ranking TO authenticated, service_role;
GRANT SELECT, TRIGGER, REFERENCES, TRUNCATE ON public.v_swap_candidate_ranking TO anon;
