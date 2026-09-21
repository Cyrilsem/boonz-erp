-- Fix: the lane detail table on the refill page (SnapshotTab.tsx's slot intelligence
-- table) showed 0 units sold for any lane whose WEIMI display name differs from its
-- canonical pod_products name, even when the AED-based Final Score on the same row was
-- correct. Live example: AMZ-1038-3001-O1 lane A06, WEIMI name "Nutella T3", canonical
-- name "Nutella Biscuits T3" -- v_shelf_sales_identity correctly resolves units_7d=14 for
-- this lane, but the page rendered 0.
--
-- Root cause was NOT purely frontend: get_machine_slots_with_expiry's `aisles` CTE reads
-- v_live_shelf_stock.pod_product_id (already correctly resolved) but never selects it --
-- the RPC instead re-derives a pod_product_id downstream via an exact
-- LOWER(TRIM(pod_product_name)) string match (`pod_by_name`), which fails whenever the
-- live WEIMI name and the canonical pod_product name differ even slightly. This is why the
-- returned `pod_product_id` column was also NULL for this lane -- the frontend had no
-- reliable identity to key on even if it tried.
--
-- Fix: aisles now carries v_live_shelf_stock.pod_product_id straight through, and the
-- sales join (`lane_sales`) keys on it directly against v_shelf_sales_identity instead of
-- matching by name. `pod_alias` mirrors v_shelf_sales_identity's own one-row alias map
-- (an old "Hunter" pod_product_id merged into a canonical one) -- v_live_shelf_stock's
-- pod_product_id is unaliased, so without this the join silently misses every aliased
-- product's sales too (found during fleet-wide verification, not part of the original
-- report). The returned pod_product_id column itself now also comes from the correct
-- source, not the broken name lookup, so a future frontend consumer keying off it will not
-- inherit the same bug. facings-normalized (units_7d / facings) to match v_lane_grain's
-- existing convention for a product occupying more than one slot on the same machine.
--
-- final_score/AED is untouched -- it already comes from compute_refill_decision's own
-- independent slot-based calculation and already renders correctly (102.6 for this lane).
--
-- Known residual, reported not silently fixed: a fleet-wide sweep after this fix still
-- finds ~66 lanes where compute_refill_decision's OWN final_score is positive while
-- v_shelf_sales_identity shows zero real 7-day sales for the resolved product. That is a
-- SEPARATE, pre-existing bug in compute_refill_decision's raw sales_history query (it
-- matches by a `goods_slot` cabinet-prefix transform to the physical slot, not by
-- pod_product_id, so it can attribute a slot's stale sales history from a since-replaced
-- product to whatever product occupies that slot today). Fixing that touches
-- compute_refill_decision's actual refill-quantity recommendation math
-- (target_units/refill_qty), used fleet-wide by the real refill engine -- out of scope for
-- a lane-sales display fix and not done here without an explicit decision to do so.

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
    -- Mirrors v_shelf_sales_identity's own alias map exactly (one known duplicate
    -- pod_product today: an old "Hunter" id merged into a canonical id).
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
  shelf_expiry AS (
    SELECT b.shelf_id, MIN(b.expiration_date) AS min_exp
    FROM public.v_machine_expiry_batches b
    WHERE b.machine_id = (SELECT machine_id FROM machine)
      AND b.shelf_id IS NOT NULL AND b.expiration_date IS NOT NULL
    GROUP BY b.shelf_id
  ),
  shelf_min_batch AS (
    SELECT se.shelf_id, se.min_exp, SUM(b.current_stock) AS min_exp_qty
    FROM shelf_expiry se
    JOIN public.v_machine_expiry_batches b
      ON b.shelf_id = se.shelf_id AND b.expiration_date = se.min_exp
     AND b.machine_id = (SELECT machine_id FROM machine)
    GROUP BY se.shelf_id, se.min_exp
  ),
  shelf_min_batch_product AS (
    SELECT DISTINCT ON (b.shelf_id) b.shelf_id, b.boonz_product_id
    FROM shelf_expiry se
    JOIN public.v_machine_expiry_batches b
      ON b.shelf_id = se.shelf_id AND b.expiration_date = se.min_exp
     AND b.machine_id = (SELECT machine_id FROM machine)
    ORDER BY b.shelf_id, b.current_stock DESC, b.boonz_product_id
  ),
  shelf_top_boonz AS (
    SELECT DISTINCT ON (b.shelf_id) b.shelf_id, b.boonz_product_id
    FROM public.v_machine_expiry_batches b
    WHERE b.machine_id = (SELECT machine_id FROM machine)
      AND b.shelf_id IS NOT NULL
    ORDER BY b.shelf_id, b.current_stock DESC, b.boonz_product_id
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
    (sx.min_exp - (SELECT today FROM dubai))::int,
    sx.min_exp_qty,
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
    (sx.min_exp - (SELECT today FROM dubai))::int,
    sx.min_exp_qty,
    nebp.boonz_product_name,
    smbp.boonz_product_id
  FROM aisles ai
  LEFT JOIN shelf_min_batch sx ON sx.shelf_id = ai.shelf_id
  LEFT JOIN shelf_min_batch_product smbp ON smbp.shelf_id = ai.shelf_id
  LEFT JOIN public.boonz_products nebp ON nebp.product_id = smbp.boonz_product_id
  LEFT JOIN shelf_top_boonz stb ON stb.shelf_id = ai.shelf_id
  LEFT JOIN lane_sales ls ON ls.machine_id = ai.machine_id AND ls.pod_product_id = ai.canonical_pod_product_id
  LEFT JOIN mv_global_product_scores gps ON LOWER(TRIM(gps.product)) = LOWER(ai.product)
  LEFT JOIN latest_ri ri ON normalize_slot(ri.slot_name) = normalize_slot(ai.slot)
  LEFT JOIN pod_by_name sbn ON sbn.product_lower = LOWER(TRIM(ri.suggested_product))
  LEFT JOIN LATERAL (
    SELECT public.compute_refill_decision(ai.machine_id, ai.shelf_id, stb.boonz_product_id, 10) AS decision
    WHERE ai.shelf_id IS NOT NULL
  ) d ON true
  ORDER BY COALESCE((d.decision->>'final_score')::numeric, 0) DESC, ai.slot;
$function$;
