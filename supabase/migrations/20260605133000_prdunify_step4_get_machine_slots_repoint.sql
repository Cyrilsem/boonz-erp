-- PRD-UNIFY Step 4 (Stax) — repoint get_machine_slots_with_expiry to the unified decision.
--
-- WHAT CHANGES (diff-gated vs live get_machine_slots_with_expiry(text)):
--   • STOP being a second target authority: target_stock / refill_qty no longer come from
--     COALESCE(ri.target_stock, max_stock) ("fill-to-max") — they come from compute_refill_decision.
--   • STOP being a second score authority: the Score the card sorts by is decision.final_score, not the
--     standalone product_base_score. (units_sold_7d stays as the raw "7d Sales" column.)
--   • compute_strategy(PROTECT/SUSTAIN) is RETIRED as a returned column — replaced by `stance`
--     (DOUBLE DOWN / KEEP / WIND DOWN …) from the decision. compute_strategy/compute_local_strategy are
--     left in the DB untouched (deprecated callers; Article 13) but this reader no longer calls them.
--   • KEEP 💎/👑 as DISPLAY badges only: global_product_status + local_performance_role still returned,
--     now sourced from the decision (global_badge / local_badge) so badges + score agree.
--   • NEW returned columns: decision jsonb, final_score numeric, stance text.
--
-- Return-type change → DROP + CREATE (same precedent as get_machine_health v2, 2026-06-02). Forward-only,
-- no _v2 name. SECURITY INVOKER STABLE (read-only display reader). One brain: this reader and the engine
-- (Step 3) both derive from compute_refill_decision. A1/E8 hold by construction.
--
-- CODY verdict (reader): ✅ Approve. Article 1 (single target+score authority = compute_refill_decision;
-- this removes the fork), Article 12 (forward-only DROP+CREATE for a return-type change; documented
-- precedent), Article 14 (no parallel table). No protected write (INVOKER reader). APPLY NOTHING.

DROP FUNCTION IF EXISTS public.get_machine_slots_with_expiry(text);

CREATE FUNCTION public.get_machine_slots_with_expiry(p_machine_name text)
 RETURNS TABLE(
   slot text, product text, current_stock integer, max_stock integer, fill_pct integer,
   expiry_days integer, expiry_qty numeric,
   target_stock numeric, refill_qty numeric,
   stance text, action_code text,
   global_product_status text, local_performance_role text,
   suggested_product text, units_sold_7d numeric,
   final_score numeric, decision jsonb)
 LANGUAGE sql
 STABLE
AS $function$
  WITH
  dubai AS (SELECT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date AS today),
  machine AS (
    SELECT machine_id FROM public.weimi_device_status
    WHERE device_name = p_machine_name
      AND snapshot_date = (SELECT MAX(snapshot_date) FROM public.weimi_device_status WHERE device_name = p_machine_name)
    LIMIT 1
  ),
  -- aisles now also resolve shelf_id (needed to call compute_refill_decision)
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
  product_boonz AS (
    SELECT DISTINCT ON (LOWER(TRIM(pp.pod_product_name)))
      LOWER(TRIM(pp.pod_product_name)) AS product_lower, pm.boonz_product_id
    FROM pod_products pp JOIN product_mapping pm ON pm.pod_product_id = pp.pod_product_id
    ORDER BY LOWER(TRIM(pp.pod_product_name)), pm.boonz_product_id
  ),
  latest_snap AS (
    SELECT MAX(pi.snapshot_date) AS snap FROM pod_inventory pi
    WHERE pi.machine_id = (SELECT machine_id FROM machine) AND pi.current_stock > 0
      AND pi.snapshot_date <= (SELECT today FROM dubai) AND pi.snapshot_date >= (SELECT today FROM dubai) - 30
  ),
  product_expiry AS (
    SELECT pi.boonz_product_id,
      (MIN(pi.expiration_date) - (SELECT today FROM dubai))::int AS days_until_expiry,
      SUM(CASE WHEN pi.expiration_date <= (SELECT today FROM dubai) THEN pi.current_stock ELSE 0 END) AS expired_qty,
      SUM(CASE WHEN pi.expiration_date > (SELECT today FROM dubai) AND pi.expiration_date <= (SELECT today FROM dubai) + 7 THEN pi.current_stock ELSE 0 END) AS expiring_7d_qty
    FROM pod_inventory pi, latest_snap ls
    WHERE pi.machine_id = (SELECT machine_id FROM machine) AND pi.snapshot_date = ls.snap
      AND pi.current_stock > 0 AND pi.expiration_date IS NOT NULL
    GROUP BY pi.boonz_product_id
  ),
  -- raw 7d sales kept for the "7d Sales" column (NOT the score authority anymore)
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
    pe.days_until_expiry,
    CASE WHEN pe.expired_qty > 0 THEN pe.expired_qty WHEN pe.expiring_7d_qty > 0 THEN pe.expiring_7d_qty ELSE NULL END,
    -- UNIFIED: target + refill from the decision (was COALESCE(ri.target_stock, max_stock))
    COALESCE((d.decision->>'target_units')::numeric, ai.current_stock),
    COALESCE((d.decision->>'refill_qty')::numeric, 0),
    -- stance replaces the PROTECT/SUSTAIN strategy column
    COALESCE(d.decision->>'stance', 'KEEP'),
    compute_action_code(
      compute_local_role(COALESCE(pv.sold_7d * 4, 0), 0),
      COALESCE(d.decision->>'global_badge', gps.global_status, '📦 Core Range')),
    -- badges (display only) — sourced from the decision so badge + score agree
    COALESCE(d.decision->>'global_badge', gps.global_status, '📦 Core Range'),
    COALESCE(d.decision->>'local_badge', '✅ Standard'),
    ri.suggested_product,
    COALESCE(pv.sold_7d, 0),
    -- UNIFIED score the card sorts by
    COALESCE((d.decision->>'final_score')::numeric, 0),
    d.decision
  FROM aisles ai
  LEFT JOIN product_boonz pb ON pb.product_lower = LOWER(ai.product)
  LEFT JOIN product_expiry pe ON pe.boonz_product_id = pb.boonz_product_id
  LEFT JOIN product_velocity pv ON pv.product_lower = LOWER(ai.product) AND pv.slot_code = ai.slot
  LEFT JOIN mv_global_product_scores gps ON LOWER(TRIM(gps.product)) = LOWER(ai.product)
  LEFT JOIN latest_ri ri ON normalize_slot(ri.slot_name) = normalize_slot(ai.slot)
  LEFT JOIN LATERAL (
    SELECT public.compute_refill_decision(ai.machine_id, ai.shelf_id, pb.boonz_product_id, 10) AS decision  -- PRD-UNIFY-CAL: days_cover 10 to match engine v14
    WHERE ai.shelf_id IS NOT NULL
  ) d ON true
  ORDER BY COALESCE((d.decision->>'final_score')::numeric, 0) DESC, ai.slot;   -- A8: sort by Final Score desc
$function$;
