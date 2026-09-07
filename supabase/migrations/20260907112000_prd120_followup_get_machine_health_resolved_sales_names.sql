-- PRD-120 L3 follow-up (item 2 of the close-out goal): get_machine_health's
-- dead_stock_count/local_hero_count subqueries matched sales_history rows
-- directly against `lower(TRIM(pod_product_name)) = ANY(dm.current_products)`
-- (dm.current_products = the machine's currently-live WEIMI lane names,
-- lowered/trimmed). Any sales row recorded under an alias/spelling variant
-- of the live product name (e.g. "Freakin Healthy Balls 3P" for the live
-- "Freakin Protein Balls 3P", per product_name_conventions) never matched,
-- silently excluding those sales from both the dead-stock and local-hero
-- velocity classification -- the exact defect class v_sales_history_resolved
-- (PRD-120 L3) exists to fix.
--
-- Fix: both subqueries now source from v_sales_history_resolved (join on
-- pod_product_id) instead of raw sales_history text, and the "is this
-- product currently live" side resolves dm.current_products (WEIMI names)
-- to pod_product_id via pod_products, matching the same
-- resolve-to-pod_product_id pattern used everywhere else in this codebase.
-- Byte-identical everywhere else in the 100+ line function -- md5-guarded
-- surgical replace() on exactly the two subqueries (dead_stock_count,
-- local_hero_count), same shape (COUNT(*) over a GROUP BY/HAVING on
-- q7*4+q15*0.5), only the identity key and source object changed.
--
-- Fixture: no currently-live real case in production data has BOTH (a) a
-- real alias-recorded sale in the last 90 days per product_name_conventions
-- AND (b) that product still being the machine's live WEIMI lane today (the
-- lanes have since moved on) -- so the full function's dead_stock/
-- local_hero OUTPUT can't show a live before/after difference right now.
-- Isolated the exact join logic instead, in two rolled-back transactions
-- against a real machine (AMZ-1038-3001-O1) with a synthetic sales_history
-- row under a real alias ("Freakin Healthy Balls 3P" -> "Freakin Protein
-- Balls 3P" per product_name_conventions), qty=20, dated 1 day ago:
--   OLD join (raw text vs ARRAY['freakin protein balls 3p']): 0 rows, 0 qty.
--   NEW join (v_sales_history_resolved.pod_product_id vs the same live
--     name resolved through pod_products): 1 row, 20 qty.
-- Confirms the fix corrects real undercounting without altering any other
-- logic; live smoke test after apply (SELECT machine_name, dead_stock_count,
-- local_hero_count FROM get_machine_health() LIMIT 5) returns sane,
-- unchanged-shape results.
--
-- Cody: approve, Article 16 (one canonical sales-identity source, no inline
-- re-derivation), Article 12 (forward-only, byte-exact patch, everything
-- else in this SECURITY DEFINER read-only function untouched).
DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='get_machine_health' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '02ba537412a64ce3779d518d7e7ed84e' THEN RAISE EXCEPTION 'get_machine_health drifted (md5 %)', md5(v_def); END IF;

  v_new := replace(v_def,
E'      (SELECT COUNT(*)::int FROM (\n        SELECT lower(TRIM(pod_product_name)) as norm_product,\n          COALESCE(SUM(qty) FILTER (WHERE transaction_date >= NOW() - interval \'7 days\'), 0) * 4\n          + COALESCE(SUM(qty) FILTER (WHERE transaction_date >= NOW() - interval \'15 days\'), 0) * 0.5 as bs\n        FROM sales_history\n        WHERE machine_id = dm.machine_id\n          AND delivery_status IN (\'Success\',\'Successful\')\n          AND lower(TRIM(pod_product_name)) = ANY(dm.current_products)\n        GROUP BY lower(TRIM(pod_product_name))\n        HAVING COALESCE(SUM(qty) FILTER (WHERE transaction_date >= NOW() - interval \'7 days\'), 0) * 4\n             + COALESCE(SUM(qty) FILTER (WHERE transaction_date >= NOW() - interval \'15 days\'), 0) * 0.5 = 0\n      ) x) as dead_stock_count,',
E'      (SELECT COUNT(*)::int FROM (\n        SELECT sh_ds.pod_product_id as norm_product,\n          COALESCE(SUM(sh_ds.qty) FILTER (WHERE sh_ds.transaction_date >= NOW() - interval \'7 days\'), 0) * 4\n          + COALESCE(SUM(sh_ds.qty) FILTER (WHERE sh_ds.transaction_date >= NOW() - interval \'15 days\'), 0) * 0.5 as bs\n        FROM public.v_sales_history_resolved sh_ds\n        WHERE sh_ds.machine_id = dm.machine_id\n          AND sh_ds.delivery_status IN (\'Success\',\'Successful\')\n          AND sh_ds.pod_product_id IN (SELECT pp_ds.pod_product_id FROM public.pod_products pp_ds WHERE lower(TRIM(pp_ds.pod_product_name)) = ANY(dm.current_products))\n        GROUP BY sh_ds.pod_product_id\n        HAVING COALESCE(SUM(sh_ds.qty) FILTER (WHERE sh_ds.transaction_date >= NOW() - interval \'7 days\'), 0) * 4\n             + COALESCE(SUM(sh_ds.qty) FILTER (WHERE sh_ds.transaction_date >= NOW() - interval \'15 days\'), 0) * 0.5 = 0\n      ) x) as dead_stock_count,');
  IF v_new = v_def THEN RAISE EXCEPTION 'get_machine_health: dead_stock_count pattern not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
E'      (SELECT COUNT(*)::int FROM (\n        SELECT lower(TRIM(pod_product_name)) as norm_product,\n          COALESCE(SUM(qty) FILTER (WHERE transaction_date >= NOW() - interval \'7 days\'), 0) * 4\n          + COALESCE(SUM(qty) FILTER (WHERE transaction_date >= NOW() - interval \'15 days\'), 0) * 0.5 as bs\n        FROM sales_history\n        WHERE machine_id = dm.machine_id\n          AND delivery_status IN (\'Success\',\'Successful\')\n          AND lower(TRIM(pod_product_name)) = ANY(dm.current_products)\n        GROUP BY lower(TRIM(pod_product_name))\n        HAVING COALESCE(SUM(qty) FILTER (WHERE transaction_date >= NOW() - interval \'7 days\'), 0) * 4\n             + COALESCE(SUM(qty) FILTER (WHERE transaction_date >= NOW() - interval \'15 days\'), 0) * 0.5 > 5\n      ) x) as local_hero_count',
E'      (SELECT COUNT(*)::int FROM (\n        SELECT sh_lh.pod_product_id as norm_product,\n          COALESCE(SUM(sh_lh.qty) FILTER (WHERE sh_lh.transaction_date >= NOW() - interval \'7 days\'), 0) * 4\n          + COALESCE(SUM(sh_lh.qty) FILTER (WHERE sh_lh.transaction_date >= NOW() - interval \'15 days\'), 0) * 0.5 as bs\n        FROM public.v_sales_history_resolved sh_lh\n        WHERE sh_lh.machine_id = dm.machine_id\n          AND sh_lh.delivery_status IN (\'Success\',\'Successful\')\n          AND sh_lh.pod_product_id IN (SELECT pp_lh.pod_product_id FROM public.pod_products pp_lh WHERE lower(TRIM(pp_lh.pod_product_name)) = ANY(dm.current_products))\n        GROUP BY sh_lh.pod_product_id\n        HAVING COALESCE(SUM(sh_lh.qty) FILTER (WHERE sh_lh.transaction_date >= NOW() - interval \'7 days\'), 0) * 4\n             + COALESCE(SUM(sh_lh.qty) FILTER (WHERE sh_lh.transaction_date >= NOW() - interval \'15 days\'), 0) * 0.5 > 5\n      ) x) as local_hero_count');
  IF v_new = v_def THEN RAISE EXCEPTION 'get_machine_health: local_hero_count pattern not found'; END IF;
  v_def := v_new;

  EXECUTE v_def;
END $mig$;
