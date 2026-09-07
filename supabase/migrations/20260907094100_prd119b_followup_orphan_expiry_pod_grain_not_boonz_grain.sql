-- PRD-119b follow-up: get_machine_orphan_expiry's lane_mismatch class produced
-- a FALSE positive on every multi-flavor lane. It compared the lot's own
-- boonz_product_id directly against the lane's resolved boonz_product_id (via
-- pod_products name match -> product_mapping). But product_mapping is a
-- pod_product_id : MANY boonz_product_id relationship (split_pct/mix_weight
-- columns exist for exactly this reason) -- a single physical lane
-- legitimately dispenses several different boonz-level flavors of the SAME
-- pod product. Comparing at boonz grain flagged every flavor except
-- whichever one the lane's raw WEIMI name happened to name-match as an
-- "orphan". Verified live: NISSAN-0804-0000-L0 alone had 24 lane_mismatch
-- rows before this fix -- e.g. its "Chocolate Bar" lane (A10) flagged
-- Snickers/Kinder Bueno/Mars/Bounty/Twix as five separate mismatches, its
-- "Snack Bar" lane (A11) flagged five different snack-bar boonz products --
-- all genuinely valid flavors of their lane's pod product per Active
-- product_mapping rows, none of them real orphans. Fleet-wide: 729 rows /
-- 3168 units before this fix, most of it this same false-positive class.
--
-- Fix: compare at POD PRODUCT grain, not boonz grain.
--   - Lane identity: resolve the WEIMI raw name to pod_product_id using the
--     EXACT v_sales_history_resolved pattern (direct trim/lower match against
--     pod_products.pod_product_name, falling back through
--     product_name_conventions.original_name -> official_name) -- the
--     established canonical name-resolution path in this codebase, not a
--     new one.
--   - Lot identity: resolve the lot's boonz_product_id to pod_product_id via
--     product_mapping (status='Active'), preferring a machine-scoped mapping
--     over the global default (same cascade driver_substitute_dispatch_line
--     already uses).
--   - A lot is orphaned only when BOTH sides resolve AND the pod products
--     differ (lane_mismatch), or its pod product is not live anywhere on the
--     machine and its shelf isn't a live shelf (unassigned, pod-grain now
--     too for the same reason). If either side fails to resolve, the lot is
--     left unflagged rather than guessed -- an unresolved WEIMI name is a
--     separate, PRD-120 L3-tracked bug class, not this one.
--   - "the lane no longer exists in the latest WEIMI snapshot" was already
--     covered by the 'unassigned' class (that shelf simply isn't in
--     live_shelf) -- no separate branch needed.
--
-- Verified live after fix: NISSAN-0804-0000-L0 drops from 24 false
-- lane_mismatch rows to 3 genuine ones -- all "Zigi" flavors (Sea Salted,
-- Sweet Chilli, Honey Mustard) stranded on shelf A13, whose live lane is now
-- "McVities Digestive Nibbles" (a real, different pod product per
-- product_mapping -- confirmed Zigi's Active mapping is pod_product "Zigi",
-- machine-scoped to this exact machine). "McVities Digestive Nibbles -
-- Double Chocolate" and "McVities Digestive - Mini Milk Chocolate", which
-- the pre-fix output also flagged, correctly clear: both are Active,
-- machine-scoped mix flavors of their respective current lanes' pod
-- products. Fleet-wide: 729 rows / 3168 units -> 143 rows / 675 units (a
-- second, distinct false-positive class -- ambiguous product_mapping rows --
-- was found and fixed in the immediately following migration).
--
-- No data remediation in this migration -- detection/reporting fix only, per
-- instruction. The already-scheduled nightly assert_no_orphan_shelf_lots
-- (unchanged, reads this function) will report the corrected, smaller count
-- on its next run; confirmed zero pre-existing 'orphan_shelf_lots' alerts
-- exist in monitoring_alerts to clear -- the cron (21:10 UTC daily) had not
-- yet fired for real since it was created earlier this same session, so no
-- false alerts were ever actually raised outside rolled-back test
-- transactions.
--
-- Cody: approve, Article 16 (one canonical lot-identity comparison, now
-- correctly grained to match how this schema actually models a multi-flavor
-- lane), no schema change, read-only.
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
  lot_pod AS (
    SELECT DISTINCT ON (pm.boonz_product_id) pm.boonz_product_id, pm.pod_product_id
    FROM public.product_mapping pm
    WHERE pm.status = 'Active'
      AND (pm.machine_id = (SELECT machine_id FROM machine) OR pm.machine_id IS NULL)
    ORDER BY pm.boonz_product_id, (pm.machine_id = (SELECT machine_id FROM machine)) DESC NULLS LAST, pm.is_global_default DESC
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
