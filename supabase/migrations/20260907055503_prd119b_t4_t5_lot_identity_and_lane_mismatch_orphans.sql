-- PRD-119b T4 (E5) + T5 (E6): expiry surfaces must show the LOT's own
-- product identity, never the lane's current WEIMI product; and a lane
-- whose WEIMI product changed without a recorded Remove must surface its
-- stranded old lot as an orphan, even though the shelf itself is live.
--
-- T4: get_machine_slots_with_expiry (the /refill drawer's source RPC) took
-- expiry_days/expiry_qty from the shelf's earliest-expiring batch but
-- labelled the row with `ai.product` (the LANE's current WEIMI-reported
-- product from v_live_shelf_stock), not the batch's own product. Verified
-- live: VOXMCC-1005-0201-B0 slot A16 lane product is "Aquafina" (never
-- expires, venue-sourced) while the earliest-expiring batch on that shelf
-- is "Vitamin Well - Zero Lemon" (expired -1d) -- exactly E5's reported
-- symptom ("Aquafina - EXPIRED 3" mislabeling a VW Zero Lemon lot). Fix:
-- widened output with two new trailing columns, nearest_expiry_product_name
-- and nearest_expiry_boonz_product_id, sourced from the SAME min-expiry
-- batch join already computing expiry_days (new shelf_min_batch_product
-- CTE, DISTINCT ON shelf_id ordered by current_stock DESC, matching the
-- existing shelf_top_boonz pattern for tie-breaking). The FE now shows the
-- lot's own name on the expiry row and a "lane now: <product>" annotation
-- when they differ (ai.product is unchanged, still the lane's product, for
-- the main Product column).
--
-- T5: get_machine_orphan_expiry previously only caught batches whose
-- shelf_id was NULL or not a live-shelf at all -- a batch sitting on a
-- REAL, currently-live shelf (A16 exists and is broadcasting "Aquafina")
-- was invisible to it even when its own boonz_product no longer matches
-- that shelf's current WEIMI product (E6's exact defect, and the same gap
-- PRD-105 flagged as "orphan live_boonz exclusion hides off-aisle ghosts").
-- Fix: new `lane_mismatch` reason class -- for every live shelf, resolve
-- its CURRENT boonz_product_id (new live_shelf_product CTE, DISTINCT ON
-- shelf_id since v_live_shelf_stock carries historical snapshot rows per
-- shelf, not just the latest -- confirmed live, 37 duplicate rows for one
-- machine+slot before the DISTINCT ON was added, which had inflated a first
-- draft's unit/batch counts 37x before this fix), then flag any Active
-- batch on that shelf whose boonz_product_id differs from the shelf's
-- current one. Output widened with reason ('unassigned' | 'lane_mismatch'),
-- shelf_id, shelf_code, lane_current_product so the FE can render "orphan
-- lot on <shelf>, lane now shows <product>" instead of a bare product/unit
-- count. The pre-existing 'unassigned' class (NULL-shelf or dead-shelf
-- batches) is untouched -- purely additive, same query, same results.
--
-- Fixture (rolled back, then re-verified after real apply): both functions
-- against VOXMCC-1005-0201-B0 A16 -- get_machine_slots_with_expiry: slot=A16,
-- product=Aquafina (lane, unchanged), nearest_expiry_product_name=
-- "Vitamin Well - Zero Lemon" (the lot, correct). get_machine_orphan_expiry:
-- returns boonz_product="Vitamin Well - Zero Lemon", units=3, batches=1,
-- expired_units=3, reason='lane_mismatch', shelf_code=A16,
-- lane_current_product=Aquafina -- units/batches now match pod_inventory's
-- real row (a5059e56, the same lot T1 repaired) exactly, confirming the
-- DISTINCT ON fan-out fix.
--
-- No dependents (checked: no other pg_proc source references either
-- function name), so DROP FUNCTION + CREATE FUNCTION is used to change the
-- RETURNS TABLE shape (CREATE OR REPLACE FUNCTION cannot alter a function's
-- return type). Both remain read-only, LANGUAGE sql, STABLE -- no
-- SECURITY DEFINER needed, no writes.
--
-- Cody: approve, Article 16 (adds to the ONE canonical lot-identity source
-- per shelf rather than inventing a second), no new write path, no RLS
-- impact (read-only functions).

DROP FUNCTION public.get_machine_orphan_expiry(text);
CREATE FUNCTION public.get_machine_orphan_expiry(p_machine_name text)
RETURNS TABLE(
  boonz_product_id uuid,
  boonz_product text,
  units integer,
  nearest_expiry_days integer,
  expired_units integer,
  batches integer,
  reason text,
  shelf_id uuid,
  shelf_code text,
  lane_current_product text
)
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
  live_shelf_product AS (
    SELECT DISTINCT ON (sc.shelf_id)
      sc.shelf_id, sc.shelf_code, pm.boonz_product_id, TRIM(v.goods_name_raw) AS lane_product_name
    FROM public.v_live_shelf_stock v
    JOIN public.shelf_configurations sc
      ON sc.machine_id = v.machine_id AND sc.is_phantom = false
     AND v.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text
    LEFT JOIN public.pod_products pp ON LOWER(TRIM(pp.pod_product_name)) = LOWER(TRIM(v.goods_name_raw))
    LEFT JOIN public.product_mapping pm ON pm.pod_product_id = pp.pod_product_id AND pm.status = 'Active'
    WHERE v.machine_id = (SELECT machine_id FROM machine) AND v.is_enabled
    ORDER BY sc.shelf_id, pm.boonz_product_id NULLS LAST
  ),
  live_shelf AS (
    SELECT DISTINCT shelf_id FROM live_shelf_product
  ),
  live_boonz AS (
    SELECT DISTINCT boonz_product_id FROM live_shelf_product WHERE boonz_product_id IS NOT NULL
  ),
  unassigned AS (
    SELECT b.boonz_product_id, bp.boonz_product_name AS boonz_product,
      SUM(b.current_stock)::int AS units,
      (MIN(b.expiration_date) FILTER (WHERE b.expiration_date IS NOT NULL) - (SELECT today FROM dubai))::int AS nearest_expiry_days,
      SUM(CASE WHEN b.expiration_date <= (SELECT today FROM dubai) THEN b.current_stock ELSE 0 END)::int AS expired_units,
      COUNT(*)::int AS batches,
      'unassigned'::text AS reason,
      NULL::uuid AS shelf_id,
      NULL::text AS shelf_code,
      NULL::text AS lane_current_product
    FROM public.v_machine_expiry_batches b
    LEFT JOIN public.boonz_products bp ON bp.product_id = b.boonz_product_id
    WHERE b.machine_id = (SELECT machine_id FROM machine)
      AND (b.shelf_id IS NULL OR b.shelf_id NOT IN (SELECT shelf_id FROM live_shelf))
      AND b.boonz_product_id NOT IN (SELECT boonz_product_id FROM live_boonz)
    GROUP BY b.boonz_product_id, bp.boonz_product_name
  ),
  lane_mismatch AS (
    SELECT b.boonz_product_id, bp.boonz_product_name AS boonz_product,
      SUM(b.current_stock)::int AS units,
      (MIN(b.expiration_date) FILTER (WHERE b.expiration_date IS NOT NULL) - (SELECT today FROM dubai))::int AS nearest_expiry_days,
      SUM(CASE WHEN b.expiration_date <= (SELECT today FROM dubai) THEN b.current_stock ELSE 0 END)::int AS expired_units,
      COUNT(*)::int AS batches,
      'lane_mismatch'::text AS reason,
      b.shelf_id,
      lsp.shelf_code,
      lsp.lane_product_name AS lane_current_product
    FROM public.v_machine_expiry_batches b
    JOIN live_shelf_product lsp ON lsp.shelf_id = b.shelf_id
    LEFT JOIN public.boonz_products bp ON bp.product_id = b.boonz_product_id
    WHERE b.machine_id = (SELECT machine_id FROM machine)
      AND lsp.boonz_product_id IS DISTINCT FROM b.boonz_product_id
    GROUP BY b.boonz_product_id, bp.boonz_product_name, b.shelf_id, lsp.shelf_code, lsp.lane_product_name
  )
  SELECT * FROM unassigned
  UNION ALL
  SELECT * FROM lane_mismatch
  ORDER BY units DESC;
$function$;

DROP FUNCTION public.get_machine_slots_with_expiry(text);
CREATE FUNCTION public.get_machine_slots_with_expiry(p_machine_name text)
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
  shelf_expiry AS (
    SELECT b.shelf_id,
           MIN(b.expiration_date) AS min_exp
    FROM public.v_machine_expiry_batches b
    WHERE b.machine_id = (SELECT machine_id FROM machine)
      AND b.shelf_id IS NOT NULL AND b.expiration_date IS NOT NULL
    GROUP BY b.shelf_id
  ),
  shelf_min_batch AS (
    SELECT se.shelf_id, se.min_exp,
           SUM(b.current_stock) AS min_exp_qty
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
    sx.min_exp_qty,
    nebp.boonz_product_name,
    smbp.boonz_product_id
  FROM aisles ai
  LEFT JOIN shelf_min_batch sx ON sx.shelf_id = ai.shelf_id
  LEFT JOIN shelf_min_batch_product smbp ON smbp.shelf_id = ai.shelf_id
  LEFT JOIN public.boonz_products nebp ON nebp.product_id = smbp.boonz_product_id
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
$function$;
