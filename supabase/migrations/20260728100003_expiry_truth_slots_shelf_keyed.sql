-- PRD-105 Expiry Truth at Shelf Grain — Change 2 (RC-1, RC-6)
-- Key the drawer's per-slot expiry by shelf_id, not by product name.
-- Removes product_boonz / product_expiry / prod_nearest_date / prod_nearest
-- (name-keyed, machine-blind, arbitrary-variant identity). Replaces them with
-- shelf-keyed CTEs: MIN(expiration_date) per shelf_id + SUM(current_stock) over
-- the batches defining that MIN. expiry_qty is now unconditional (7d window dropped).
-- compute_refill_decision no longer receives the arbitrary name-keyed boonz_product_id;
-- it gets the shelf's highest-stock one (the parameter is in fact unused by that
-- function, which derives identity internally, so scoring is provably unchanged).
-- nearest_expiry_days/_qty mirror expiry_days/_qty for FE compatibility.
-- Replaced-body md5 (byte-identical rollback): f57322b3c770e14c155008a9e10502b4
CREATE OR REPLACE FUNCTION public.get_machine_slots_with_expiry(p_machine_name text)
 RETURNS TABLE(slot text, product text, current_stock integer, max_stock integer, fill_pct integer, expiry_days integer, expiry_qty numeric, target_stock numeric, refill_qty numeric, stance text, action_code text, global_product_status text, local_performance_role text, suggested_product text, units_sold_7d numeric, final_score numeric, decision jsonb, shelf_id uuid, pod_product_id uuid, suggested_pod_product_id uuid, nearest_expiry_days integer, nearest_expiry_qty numeric)
 LANGUAGE sql
 STABLE
AS $function$
  WITH
  pod_by_name AS (
    SELECT DISTINCT ON (LOWER(TRIM(pp.pod_product_name)))
      LOWER(TRIM(pp.pod_product_name)) AS product_lower, pp.pod_product_id
    FROM public.pod_products pp
    ORDER BY LOWER(TRIM(pp.pod_product_name)), pp.pod_product_id
  ),
  dubai AS (SELECT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date AS today),
  machine AS (
    SELECT machine_id FROM public.weimi_device_status
    WHERE device_name = p_machine_name
      AND snapshot_date = (SELECT MAX(snapshot_date) FROM public.weimi_device_status WHERE device_name = p_machine_name)
    LIMIT 1
  ),
  aisles AS (
    SELECT v.slot_name AS slot, TRIM(v.goods_name_raw) AS product,
      GREATEST(v.current_stock, 0) AS current_stock, GREATEST(v.max_stock, 1) AS max_stock,
      v.machine_id, sc.shelf_id
    FROM public.v_live_shelf_stock v
    LEFT JOIN public.shelf_configurations sc
      ON sc.machine_id = v.machine_id AND sc.is_phantom = false
     AND v.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text
    WHERE v.machine_id = (SELECT machine_id FROM machine)
  ),
  -- Shelf-keyed expiry: earliest date per shelf over the (now correctly de-duped) batch view.
  shelf_expiry AS (
    SELECT b.shelf_id,
           MIN(b.expiration_date) AS min_exp
    FROM public.v_machine_expiry_batches b
    WHERE b.machine_id = (SELECT machine_id FROM machine)
      AND b.shelf_id IS NOT NULL AND b.expiration_date IS NOT NULL
    GROUP BY b.shelf_id
  ),
  -- Units in the batch(es) defining that MIN, on the same shelf.
  shelf_min_batch AS (
    SELECT se.shelf_id, se.min_exp,
           SUM(b.current_stock) AS min_exp_qty
    FROM shelf_expiry se
    JOIN public.v_machine_expiry_batches b
      ON b.shelf_id = se.shelf_id AND b.expiration_date = se.min_exp
     AND b.machine_id = (SELECT machine_id FROM machine)
    GROUP BY se.shelf_id, se.min_exp
  ),
  -- The shelf's highest-stock boonz_product_id, passed to the scorer in place of the
  -- old arbitrary name-keyed id (compute_refill_decision does not read this param).
  shelf_top_boonz AS (
    SELECT DISTINCT ON (b.shelf_id) b.shelf_id, b.boonz_product_id
    FROM public.v_machine_expiry_batches b
    WHERE b.machine_id = (SELECT machine_id FROM machine)
      AND b.shelf_id IS NOT NULL
    ORDER BY b.shelf_id, b.current_stock DESC, b.boonz_product_id
  ),
  product_velocity AS (
    SELECT LOWER(TRIM(sh.pod_product_name)) AS product_lower,
      CASE WHEN sh.goods_slot LIKE '0-A%' THEN 'A' || ((SUBSTRING(sh.goods_slot, 4)::int) + 1)::text
           WHEN sh.goods_slot LIKE '1-A%' THEN 'B' || ((SUBSTRING(sh.goods_slot, 4)::int) + 1)::text
           ELSE sh.goods_slot END AS slot_code,
      COALESCE(SUM(sh.qty) FILTER (WHERE sh.transaction_date >= NOW() - interval '7 days'), 0) AS sold_7d
    FROM sales_history sh
    WHERE sh.machine_id = (SELECT machine_id FROM machine) AND sh.delivery_status IN ('Success','Successful')
    GROUP BY LOWER(TRIM(sh.pod_product_name)), slot_code
  ),
  latest_ri AS (
    SELECT ri.* FROM refill_instructions ri
    WHERE ri.machine_id = (SELECT machine_id FROM machine)
      AND ri.report_timestamp = (SELECT MAX(report_timestamp) FROM refill_instructions WHERE machine_id = (SELECT machine_id FROM machine))
  )
  SELECT
    ai.slot, ai.product, ai.current_stock, ai.max_stock,
    CASE WHEN ai.max_stock > 0 THEN ROUND((ai.current_stock::numeric / ai.max_stock) * 100)::int ELSE 0 END,
    (sx.min_exp - (SELECT today FROM dubai))::int,
    sx.min_exp_qty,
    COALESCE((d.decision->>'target_units')::numeric, ai.current_stock),
    COALESCE((d.decision->>'refill_qty')::numeric, 0),
    COALESCE(d.decision->>'stance', 'KEEP'),
    compute_action_code(
      compute_local_role(COALESCE(pv.sold_7d * 4, 0), 0),
      COALESCE(d.decision->>'global_badge', gps.global_status, '📦 Core Range')),
    COALESCE(d.decision->>'global_badge', gps.global_status, '📦 Core Range'),
    COALESCE(d.decision->>'local_badge', '✅ Standard'),
    ri.suggested_product,
    COALESCE(pv.sold_7d, 0),
    COALESCE((d.decision->>'final_score')::numeric, 0),
    d.decision,
    ai.shelf_id,
    pbn.pod_product_id,
    sbn.pod_product_id,
    (sx.min_exp - (SELECT today FROM dubai))::int,
    sx.min_exp_qty
  FROM aisles ai
  LEFT JOIN shelf_min_batch sx ON sx.shelf_id = ai.shelf_id
  LEFT JOIN shelf_top_boonz stb ON stb.shelf_id = ai.shelf_id
  LEFT JOIN product_velocity pv ON pv.product_lower = LOWER(ai.product) AND pv.slot_code = ai.slot
  LEFT JOIN mv_global_product_scores gps ON LOWER(TRIM(gps.product)) = LOWER(ai.product)
  LEFT JOIN latest_ri ri ON normalize_slot(ri.slot_name) = normalize_slot(ai.slot)
  LEFT JOIN pod_by_name pbn ON pbn.product_lower = LOWER(ai.product)
  LEFT JOIN pod_by_name sbn ON sbn.product_lower = LOWER(TRIM(ri.suggested_product))
  LEFT JOIN LATERAL (
    SELECT public.compute_refill_decision(ai.machine_id, ai.shelf_id, stb.boonz_product_id, 10) AS decision
    WHERE ai.shelf_id IS NOT NULL
  ) d ON true
  ORDER BY COALESCE((d.decision->>'final_score')::numeric, 0) DESC, ai.slot;
$function$
;
