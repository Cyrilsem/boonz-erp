-- PRD-128d step 01: get_machine_slots_with_expiry resolved nearest_expiry_* per SHELF, with
-- no filter tying the result back to the lane's own pod_product_id. A shelf carrying stale
-- v_machine_expiry_batches rows from a since-replaced product surfaced that OLD product's
-- expiry instead of the current lane's. Live example: AMZ-1038-3001-O1 A10 holds "Hunter
-- Cans" but reported nearest expiry "Zigi - Sea Salted" (a product no longer in that lane,
-- with its own stale batch rows still sitting on the same physical shelf); A11 holds
-- "Krambals" but reported "Nutella - Biscuit T3".
--
-- Fix: resolve nearest_expiry_* strictly from the lane's own pod_product_id, through
-- product_mapping, to boonz_product_id -- the same resolution shape v_current_price_filled's
-- resolved_mapping CTE already uses for pricing, except pricing only needs one representative
-- flavour (LIMIT 1) while expiry needs every Active flavour a "mix" pod_product maps to
-- (Hunter Cans maps to three canister flavours; the batch physically nearest to expiring
-- could be any of them) -- same flavour-sum shape as PRD-127's engine_add_pod fix, not a
-- LIMIT-1 pick.
--
-- shelf_min_batch_product and shelf_top_boonz are both removed: the former was the direct
-- source of this bug, the latter had the identical defect one step removed (an unfiltered
-- shelf-level "top stock" pick fed to compute_refill_decision's third argument). Verified
-- that argument is dead: `prosrc ilike '%p_boonz_product_id%'` on compute_refill_decision
-- returns false, so passing the lane's own resolved boonz_product_id there instead changes
-- nothing about that function's output -- compute_refill_decision itself is not modified,
-- per the constraint on this task.
--
-- Verified live before writing this migration: A10's shelf physically carries both stale
-- Zigi batches and current Hunter Canister batches (three flavours); the soonest
-- Hunter-flavour batch expires 2027-05-25, qty 6 (before facings/tie aggregation). Fleet-wide
-- sweep after the fix: 0 lanes where nearest_expiry_boonz_product_id does not map back to the
-- lane's own pod_product_id via an Active product_mapping row.

CREATE OR REPLACE FUNCTION public.get_machine_slots_with_expiry(p_machine_name text)
 RETURNS TABLE(slot text, product text, current_stock integer, max_stock integer, fill_pct integer, expiry_days integer, expiry_qty numeric, target_stock numeric, refill_qty numeric, stance text, action_code text, global_product_status text, local_performance_role text, suggested_product text, units_sold_7d numeric, final_score numeric, decision jsonb, shelf_id uuid, pod_product_id uuid, suggested_pod_product_id uuid, nearest_expiry_days integer, nearest_expiry_qty numeric, nearest_expiry_product_name text, nearest_expiry_boonz_product_id uuid)
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
  pod_alias AS (
    VALUES ('168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid, '51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid)
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
      v.machine_id, sc.shelf_id, v.pod_product_id,
      COALESCE(pa.column2, v.pod_product_id) AS canonical_pod_product_id
    FROM public.v_live_shelf_stock v
    LEFT JOIN public.shelf_configurations sc
      ON sc.machine_id = v.machine_id AND sc.is_phantom = false
     AND v.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text
    LEFT JOIN pod_alias pa ON pa.column1 = v.pod_product_id
    WHERE v.machine_id = (SELECT machine_id FROM machine)
  ),
  -- Every boonz_product_id this lane's own pod_product_id actively maps to. Machine-specific
  -- mapping rows and global-default rows both count -- a "mix" pod product legitimately maps
  -- to several flavours, all of which are the lane's own product for expiry purposes.
  lane_boonz AS (
    SELECT ai.slot, ai.shelf_id, ai.machine_id, pm.boonz_product_id
    FROM aisles ai
    JOIN public.product_mapping pm
      ON pm.pod_product_id = ai.canonical_pod_product_id
     AND pm.status = 'Active'
     AND (pm.machine_id IS NULL OR pm.machine_id = ai.machine_id)
    WHERE ai.shelf_id IS NOT NULL
  ),
  lane_min_exp AS (
    SELECT lb.slot, MIN(b.expiration_date) AS min_exp
    FROM lane_boonz lb
    JOIN public.v_machine_expiry_batches b
      ON b.shelf_id = lb.shelf_id AND b.boonz_product_id = lb.boonz_product_id AND b.machine_id = lb.machine_id
    WHERE b.expiration_date IS NOT NULL
    GROUP BY lb.slot
  ),
  lane_min_batch AS (
    SELECT lme.slot, lme.min_exp,
      SUM(b.current_stock) AS min_exp_qty,
      (array_agg(b.boonz_product_id ORDER BY b.current_stock DESC, b.boonz_product_id))[1] AS boonz_product_id
    FROM lane_min_exp lme
    JOIN lane_boonz lb ON lb.slot = lme.slot
    JOIN public.v_machine_expiry_batches b
      ON b.shelf_id = lb.shelf_id AND b.expiration_date = lme.min_exp AND b.boonz_product_id = lb.boonz_product_id
     AND b.machine_id = lb.machine_id
    GROUP BY lme.slot, lme.min_exp
  ),
  lane_sales AS (
    SELECT vsi.machine_id, vsi.pod_product_id,
      vsi.units_7d / NULLIF(vsi.facings, 0)::numeric AS units_7d
    FROM public.v_shelf_sales_identity vsi
    WHERE vsi.machine_id = (SELECT machine_id FROM machine)
  ),
  latest_ri AS (
    SELECT ri.* FROM refill_instructions ri
    WHERE ri.machine_id = (SELECT machine_id FROM machine)
      AND ri.report_timestamp = (SELECT MAX(report_timestamp) FROM refill_instructions WHERE machine_id = (SELECT machine_id FROM machine))
  )
  SELECT
    ai.slot, ai.product, ai.current_stock, ai.max_stock,
    CASE WHEN ai.max_stock > 0 THEN ROUND((ai.current_stock::numeric / ai.max_stock) * 100)::int ELSE 0 END,
    (lmb.min_exp - (SELECT today FROM dubai))::int,
    lmb.min_exp_qty,
    COALESCE((d.decision->>'target_units')::numeric, ai.current_stock),
    COALESCE((d.decision->>'refill_qty')::numeric, 0),
    COALESCE(d.decision->>'stance', 'KEEP'),
    compute_action_code(
      compute_local_role(COALESCE(ls.units_7d * 4, 0), 0),
      COALESCE(d.decision->>'global_badge', gps.global_status, '📦 Core Range')),
    COALESCE(d.decision->>'global_badge', gps.global_status, '📦 Core Range'),
    COALESCE(d.decision->>'local_badge', '✅ Standard'),
    ri.suggested_product,
    COALESCE(ls.units_7d, 0),
    COALESCE((d.decision->>'final_score')::numeric, 0),
    d.decision,
    ai.shelf_id,
    ai.pod_product_id,
    sbn.pod_product_id,
    (lmb.min_exp - (SELECT today FROM dubai))::int,
    lmb.min_exp_qty,
    nebp.boonz_product_name,
    lmb.boonz_product_id
  FROM aisles ai
  LEFT JOIN lane_min_batch lmb ON lmb.slot = ai.slot
  LEFT JOIN public.boonz_products nebp ON nebp.product_id = lmb.boonz_product_id
  LEFT JOIN lane_sales ls ON ls.machine_id = ai.machine_id AND ls.pod_product_id = ai.canonical_pod_product_id
  LEFT JOIN mv_global_product_scores gps ON LOWER(TRIM(gps.product)) = LOWER(ai.product)
  LEFT JOIN latest_ri ri ON normalize_slot(ri.slot_name) = normalize_slot(ai.slot)
  LEFT JOIN pod_by_name sbn ON sbn.product_lower = LOWER(TRIM(ri.suggested_product))
  LEFT JOIN LATERAL (
    SELECT public.compute_refill_decision(ai.machine_id, ai.shelf_id, lmb.boonz_product_id, 10) AS decision
    WHERE ai.shelf_id IS NOT NULL
  ) d ON true
  ORDER BY COALESCE((d.decision->>'final_score')::numeric, 0) DESC, ai.slot;
$function$;
