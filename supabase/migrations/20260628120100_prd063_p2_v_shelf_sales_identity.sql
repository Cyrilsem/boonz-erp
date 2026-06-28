-- PRD-063 step 2: v_shelf_sales_identity.
-- Per (machine, product-identity) shelf-velocity resolver. Joins the live shelf placement
-- (v_live_shelf_stock, per enabled/non-broken slot, pod_product_id already name-resolved) to
-- per-product 30d/7d sales. Sales identity is resolved from sales_history.pod_product_name (TEXT,
-- no ids) through the SAME tiered name match v_live_shelf_stock uses (pod_products direct ->
-- case-insensitive -> product_name_conventions), then both sides are folded through a scoped
-- pod-identity alias so renamed-but-same shelves merge (Hunter <-> "Hunter Ridge", the PRD-062
-- assorted-shelf relabel). Pepsi Regular and Pepsi Black are distinct pods -> stay separate.
--
-- Grain: (machine_id, pod_product_id) where pod_product_id is the CANONICAL (post-alias) identity.
-- "facings" = count of enabled non-broken slots holding that identity; stock/cap = sums.
-- Grading (A/B/C/D) is intentionally NOT done here -- it depends on tunable a_floor/b_floor and
-- lives in v_machine_priority. This view exposes raw dvel/dos + resolved/has_sales so coverage
-- (matched / enabled shelves) can be measured by any consumer.
--
-- ALIAS NOTE: the identity alias is a small in-view VALUES list (forward-migration tunable). pods
-- are mixes mapping to many boonz_products, so boonz_product_id is NOT a usable identity key;
-- a pod-level alias is the correct grain. If runtime tuning is wanted later, promote to a seed table.

CREATE OR REPLACE VIEW public.v_shelf_sales_identity AS
WITH alias(pod_product_id, canonical_pod) AS (
  VALUES
    -- Hunter (assorted) sells under "Hunter Ridge" after the rename; merge their velocity.
    ('168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid, '51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid)
),
shelf AS (
  SELECT v.machine_id,
         COALESCE(al.canonical_pod, v.pod_product_id) AS pod_product_id,
         min(v.goods_name_raw)              AS goods_name_sample,
         count(*)                           AS facings,
         sum(v.current_stock)               AS stock,
         sum(v.max_stock)                   AS cap
  FROM public.v_live_shelf_stock v
  LEFT JOIN alias al ON al.pod_product_id = v.pod_product_id
  WHERE v.is_enabled
    AND COALESCE(v.is_broken, false) = false
    AND v.is_eligible_machine
    AND v.pod_product_id IS NOT NULL
  GROUP BY v.machine_id, COALESCE(al.canonical_pod, v.pod_product_id)
),
sale_resolved AS (
  SELECT s.machine_id,
         COALESCE(al.canonical_pod,
                  COALESCE(d.pod_product_id, ci.pod_product_id, cv.pod_product_id)) AS pod_product_id,
         s.qty,
         s.transaction_date
  FROM public.sales_history s
  LEFT JOIN public.pod_products d  ON d.pod_product_name = s.pod_product_name
  LEFT JOIN public.pod_products ci ON lower(btrim(ci.pod_product_name)) = lower(btrim(s.pod_product_name))
  LEFT JOIN public.product_name_conventions pnc ON pnc.original_name = s.pod_product_name
  LEFT JOIN public.pod_products cv ON cv.pod_product_name = pnc.official_name
  LEFT JOIN alias al ON al.pod_product_id = COALESCE(d.pod_product_id, ci.pod_product_id, cv.pod_product_id)
  WHERE s.delivery_status IN ('Success','Successful')
    AND s.transaction_date >= now() - interval '30 days'
),
sales AS (
  SELECT machine_id, pod_product_id,
         sum(qty)                                                            AS units_30d,
         sum(qty) FILTER (WHERE transaction_date >= now() - interval '7 days') AS units_7d
  FROM sale_resolved
  WHERE pod_product_id IS NOT NULL
  GROUP BY machine_id, pod_product_id
)
SELECT
  sh.machine_id,
  sh.pod_product_id,
  sh.goods_name_sample,
  sh.facings,
  sh.stock,
  sh.cap,
  COALESCE(sa.units_30d, 0)                       AS units_30d,
  COALESCE(sa.units_7d, 0)                        AS units_7d,
  (COALESCE(sa.units_30d, 0) / 30.0)::numeric     AS dvel,                      -- units/day (30d window)
  CASE WHEN COALESCE(sa.units_30d, 0) > 0
       THEN (sh.stock / (sa.units_30d / 30.0))::numeric
       END                                        AS dos,                       -- days of supply; NULL when no sales
  true                                            AS resolved,                  -- shelf pod identity resolved (filtered NOT NULL above)
  (sa.machine_id IS NOT NULL)                     AS has_sales                  -- a 30d sale matched this identity on this machine
FROM shelf sh
LEFT JOIN sales sa
  ON sa.machine_id = sh.machine_id
 AND sa.pod_product_id = sh.pod_product_id;

COMMENT ON VIEW public.v_shelf_sales_identity IS
  'PRD-063 shelf-velocity identity resolver. Grain (machine_id, canonical pod_product_id) over enabled non-broken slots. dvel=units_30d/30, dos=stock/dvel. Sales resolved via pod_products/product_name_conventions name tiers + scoped pod alias (Hunter<->Hunter Ridge). Feeds v_machine_priority.';
