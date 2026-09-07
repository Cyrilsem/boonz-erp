-- PRD-119b follow-up 2: the pod-grain fix (prd119b_followup_orphan_expiry_
-- pod_grain_not_boonz_grain) still produced false lane_mismatch rows for
-- boonz products with an AMBIGUOUS Active product_mapping -- more than one
-- distinct pod_product_id at the SAME best-priority tier (machine-scoped or
-- global). Verified live: "Coca Cola - Zero" has two Active machine-scoped
-- mappings for MC-2004-0100-O1 ("Coca Cola Zero" 100% split_pct AND "Coca
-- Cola Mix" 60% split_pct) -- product_mapping has no shelf_id column, so it
-- cannot express "this boonz product is Coca Cola Zero on THIS lane and
-- Coca Cola Mix on THAT lane," and the prior fix's tie-break (machine-scope
-- DESC, is_global_default DESC) picked one arbitrarily, sometimes disagreeing
-- with the lane's own correctly-resolved pod product and firing a false
-- mismatch. Fleet-wide affected class: Coca Cola/Pepsi/7Up/Evian family
-- products (3 candidate pod products each) plus several Zigi/Krambals SKUs
-- (2 candidates each) -- confirmed via a direct product_mapping GROUP BY.
--
-- Fix: lot_pod now resolves a boonz_product_id to a pod_product_id ONLY
-- when its best-priority tier has exactly ONE distinct pod_product_id;
-- otherwise left NULL (unresolved -- excluded from lane_mismatch, same
-- "don't guess" treatment as an unresolved lane name). Fleet-wide count:
-- 143 rows / 675 units (pod-grain fix alone) -> 106 rows / 496 units (this
-- fix). NISSAN-0804-0000-L0 unaffected by this specific fix (still 3 Zigi
-- rows on shelf A13 -- Zigi has a single, unambiguous machine-scoped
-- mapping, confirmed via direct product_mapping inspection both before and
-- after).
--
-- Residual, deliberately not resolved: a small number of rows (e.g.
-- IRIS-1070-0000-O1 A12, "Pepsi - Black" boonz product) still flag because
-- the machine's OWN product_mapping maps that boonz product to a DIFFERENT
-- pod product ("Soft Drinks Mix") than what the live WEIMI lane name
-- literally says ("Pepsi Black", which name-matches a pod_products row of
-- the same name). This is a genuine disagreement between two data sources
-- (product_mapping's admin config vs. the live WEIMI-reported name), not a
-- resolution bug in this function -- listing it, not adjudicating which
-- source is stale, per this task's own "no data remediation, list only"
-- instruction.
--
-- No data remediation -- detection/reporting fix only. The 3 unresolved-vs-
-- ambiguous exclusion classes this function now applies (unresolved lane
-- name, no Active mapping at all, ambiguous Active mapping) are three
-- distinct, real data-quality conditions worth their own follow-up, not
-- guessed through here.
--
-- Cody: approve, Article 16, no schema change, read-only.
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
  live_shelf_pod AS (
    SELECT DISTINCT ON (sc.shelf_id)
      sc.shelf_id, sc.shelf_code,
      COALESCE(
        (SELECT pp.pod_product_id FROM public.pod_products pp
          WHERE LOWER(TRIM(pp.pod_product_name)) = LOWER(TRIM(v.goods_name_raw)) LIMIT 1),
        (SELECT pp.pod_product_id FROM public.product_name_conventions pnc
           JOIN public.pod_products pp ON LOWER(TRIM(pp.pod_product_name)) = LOWER(TRIM(pnc.official_name))
          WHERE LOWER(TRIM(pnc.original_name)) = LOWER(TRIM(v.goods_name_raw)) LIMIT 1)
      ) AS lane_pod_product_id,
      TRIM(v.goods_name_raw) AS lane_product_name
    FROM public.v_live_shelf_stock v
    JOIN public.shelf_configurations sc
      ON sc.machine_id = v.machine_id AND sc.is_phantom = false
     AND v.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text
    WHERE v.machine_id = (SELECT machine_id FROM machine) AND v.is_enabled
    ORDER BY sc.shelf_id, lane_pod_product_id NULLS LAST
  ),
  lot_pod_tiered AS (
    SELECT pm.boonz_product_id, pm.pod_product_id,
      CASE WHEN pm.machine_id = (SELECT machine_id FROM machine) THEN 0 ELSE 1 END AS tier
    FROM public.product_mapping pm
    WHERE pm.status = 'Active'
      AND (pm.machine_id = (SELECT machine_id FROM machine) OR pm.machine_id IS NULL)
  ),
  lot_pod_best_tier AS (
    SELECT boonz_product_id, MIN(tier) AS best_tier FROM lot_pod_tiered GROUP BY boonz_product_id
  ),
  lot_pod AS (
    SELECT lpt.boonz_product_id,
      CASE WHEN COUNT(DISTINCT lpt.pod_product_id) = 1
           THEN (array_agg(DISTINCT lpt.pod_product_id))[1]
           ELSE NULL END AS pod_product_id
    FROM lot_pod_tiered lpt
    JOIN lot_pod_best_tier bt ON bt.boonz_product_id = lpt.boonz_product_id AND bt.best_tier = lpt.tier
    GROUP BY lpt.boonz_product_id
  ),
  live_shelf AS (
    SELECT DISTINCT shelf_id FROM live_shelf_pod
  ),
  live_pod AS (
    SELECT DISTINCT lane_pod_product_id FROM live_shelf_pod WHERE lane_pod_product_id IS NOT NULL
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
    LEFT JOIN lot_pod lp ON lp.boonz_product_id = b.boonz_product_id
    WHERE b.machine_id = (SELECT machine_id FROM machine)
      AND (b.shelf_id IS NULL OR b.shelf_id NOT IN (SELECT shelf_id FROM live_shelf))
      AND (lp.pod_product_id IS NULL OR lp.pod_product_id NOT IN (SELECT lane_pod_product_id FROM live_pod))
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
    JOIN live_shelf_pod lsp ON lsp.shelf_id = b.shelf_id
    LEFT JOIN lot_pod lp ON lp.boonz_product_id = b.boonz_product_id
    LEFT JOIN public.boonz_products bp ON bp.product_id = b.boonz_product_id
    WHERE b.machine_id = (SELECT machine_id FROM machine)
      AND lsp.lane_pod_product_id IS NOT NULL
      AND lp.pod_product_id IS NOT NULL
      AND lp.pod_product_id IS DISTINCT FROM lsp.lane_pod_product_id
    GROUP BY b.boonz_product_id, bp.boonz_product_name, b.shelf_id, lsp.shelf_code, lsp.lane_product_name
  )
  SELECT * FROM unassigned
  UNION ALL
  SELECT * FROM lane_mismatch
  ORDER BY units DESC;
$function$;
