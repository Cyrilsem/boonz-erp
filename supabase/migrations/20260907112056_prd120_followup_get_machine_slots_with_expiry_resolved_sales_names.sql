-- PRD-120 L3 follow-up (item 2 of the close-out goal): get_machine_slots_
-- with_expiry's product_velocity CTE matched sales_history rows directly
-- against the live WEIMI lane's raw product name
-- (`LOWER(TRIM(sh.pod_product_name)) = product_lower`, joined to
-- `LOWER(ai.product)`). Any sales row recorded under an alias/spelling
-- variant of the live product name (per product_name_conventions) never
-- matched, silently undercounting units_sold_7d for that slot -- feeding
-- directly into this function's own action_code/local_performance_role
-- computation for the /refill drawer.
--
-- Fix: product_velocity now sources from sales_history JOINed to
-- v_sales_history_resolved on transaction_id (v_sales_history_resolved
-- itself doesn't carry goods_slot, needed for the slot_code CASE, so the
-- join keeps sales_history as the FROM target and adds the resolved view
-- only for pod_product_id), grouped by pod_product_id instead of the raw
-- lowered name. The join to `aisles` now resolves the live raw name
-- (ai.product) to a pod_product_id via the SAME pre-existing `pod_by_name`
-- CTE this function already uses elsewhere (pbn/sbn) -- no new resolution
-- path invented. Byte-identical everywhere else.
--
-- Fixture, live end-to-end: real machine ACTIVATE-2005-0000-W0, slot B6,
-- live product "Soft Drinks Mix" (real product_name_conventions alias:
-- "Drinks" -> "Soft Drinks Mix"). Inserted one synthetic sales_history row
-- under the alias name "Drinks", qty=15, goods_slot='1-A05' (maps to slot
-- B6), dated 1 day ago, in a rolled-back transaction:
--   OLD (raw-name join, isolated): units_sold_7d = 0 (alias sale invisible).
--   NEW (calling the real, already-applied get_machine_slots_with_expiry):
--     slot=B6, product="Soft Drinks Mix", units_sold_7d = 15.
-- Confirms the fix corrects real undercounting without altering any other
-- column or join in this function.
--
-- Cody: approve, Article 16 (one canonical sales-identity source), Article
-- 12 (forward-only, byte-exact patch, read-only LANGUAGE sql function,
-- no write statements, everything else untouched).
DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='get_machine_slots_with_expiry' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'b3ffc19c05614d1f486017565f23713d' THEN RAISE EXCEPTION 'get_machine_slots_with_expiry drifted (md5 %)', md5(v_def); END IF;

  v_new := replace(v_def,
E'  product_velocity AS (\n    SELECT LOWER(TRIM(sh.pod_product_name)) AS product_lower,\n      CASE WHEN sh.goods_slot LIKE \'0-A%\' THEN \'A\' || ((SUBSTRING(sh.goods_slot, 4)::int) + 1)::text\n           WHEN sh.goods_slot LIKE \'1-A%\' THEN \'B\' || ((SUBSTRING(sh.goods_slot, 4)::int) + 1)::text\n           ELSE sh.goods_slot END AS slot_code,\n      COALESCE(SUM(sh.qty) FILTER (WHERE sh.transaction_date >= NOW() - interval \'7 days\'), 0) AS sold_7d\n    FROM sales_history sh\n    WHERE sh.machine_id = (SELECT machine_id FROM machine) AND sh.delivery_status IN (\'Success\',\'Successful\')\n    GROUP BY LOWER(TRIM(sh.pod_product_name)), slot_code\n  ),',
E'  product_velocity AS (\n    SELECT vshr.pod_product_id AS pod_product_id,\n      CASE WHEN sh.goods_slot LIKE \'0-A%\' THEN \'A\' || ((SUBSTRING(sh.goods_slot, 4)::int) + 1)::text\n           WHEN sh.goods_slot LIKE \'1-A%\' THEN \'B\' || ((SUBSTRING(sh.goods_slot, 4)::int) + 1)::text\n           ELSE sh.goods_slot END AS slot_code,\n      COALESCE(SUM(sh.qty) FILTER (WHERE sh.transaction_date >= NOW() - interval \'7 days\'), 0) AS sold_7d\n    FROM sales_history sh\n    JOIN public.v_sales_history_resolved vshr ON vshr.transaction_id = sh.transaction_id\n    WHERE sh.machine_id = (SELECT machine_id FROM machine) AND sh.delivery_status IN (\'Success\',\'Successful\')\n    GROUP BY vshr.pod_product_id, slot_code\n  ),');
  IF v_new = v_def THEN RAISE EXCEPTION 'get_machine_slots_with_expiry: product_velocity CTE pattern not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
E'  LEFT JOIN product_velocity pv ON pv.product_lower = LOWER(ai.product) AND pv.slot_code = ai.slot\n',
E'  LEFT JOIN product_velocity pv ON pv.pod_product_id = (SELECT pbn2.pod_product_id FROM pod_by_name pbn2 WHERE pbn2.product_lower = LOWER(ai.product)) AND pv.slot_code = ai.slot\n');
  IF v_new = v_def THEN RAISE EXCEPTION 'get_machine_slots_with_expiry: product_velocity join pattern not found'; END IF;
  v_def := v_new;

  EXECUTE v_def;
END $mig$;
