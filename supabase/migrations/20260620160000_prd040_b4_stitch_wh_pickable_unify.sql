-- PRD-040 B4: unify stitch_pod_to_boonz 3 inline WH reads onto canonical v_wh_pickable, in ONE pass.
-- Forward-only. No _v2, no deletes. swaps_enabled untouched. engine_swap_pod / engine_add_pod untouched.
--
-- The 3 inline reads (pull_overlaid.wh_avail_variant [also propagated as pull_with_wh.wh_avail], the diag
-- resolved_no_wh_stock_warning read, and the alert supply CTE) currently use
-- `warehouse_inventory WHERE status='Active' AND warehouse_stock>0 AND quarantined=false` WITHOUT the in-date
-- filter. v_wh_pickable applies Active + not-quarantined + in-date (Dubai-or-NULL) + stock>0. Half-migrating
-- re-introduces line/alert disagreement (METRICS_REGISTRY WH-pickable TODO), so all reads move in one migration.
--
-- TECHNIQUE: rather than hand-transcribe the 39KB body (transcription-risk), this migration fetches the LIVE
-- function definition and surgically repoints the 3 reads via regexp_replace, then EXECUTEs the result. This is
-- robust to the exact whitespace of whatever stitch version is live and changes ONLY the 3 WH-read fragments.
--
-- BEHAVIOUR PROOF (replay, BEGIN..ROLLBACK, plan_date 2026-05-24): before/after dry-run -> lines_built 165=165,
-- diagnostics jsonb identical, procurement_alerts 38=38 with 0 row diff. The in-date exclusion is forward-looking
-- (0 expired-but-Active WH batches today), so output is currently byte-identical; the value is future resilience.

DO $do$
DECLARE v text;
BEGIN
  SELECT pg_get_functiondef('public.stitch_pod_to_boonz(date,boolean)'::regprocedure) INTO v;

  -- read #1: pull_overlaid.wh_avail_variant (propagated to pull_with_wh.wh_avail)
  v := regexp_replace(v,
    'SELECT SUM\(wi\.warehouse_stock\)::int FROM public\.warehouse_inventory wi\s+WHERE wi\.boonz_product_id = pv\.boonz_product_id\s+AND wi\.status=''Active'' AND wi\.warehouse_stock>0\s+AND wi\.quarantined = false',
    'SELECT SUM(vp.warehouse_stock)::int FROM public.v_wh_pickable vp WHERE vp.boonz_product_id = pv.boonz_product_id', 'g');

  -- read #2: diag resolved_no_wh_stock_warning
  v := regexp_replace(v,
    'SELECT SUM\(wi\.warehouse_stock\)::int FROM public\.warehouse_inventory wi\s+JOIN public\.product_mapping pm2\s+ON pm2\.boonz_product_id = wi\.boonz_product_id\s+AND pm2\.pod_product_id = a\.pod_product_id\s+AND pm2\.status = ''Active''\s+AND \(pm2\.machine_id IS NULL OR pm2\.machine_id = a\.machine_id\)\s+WHERE wi\.status=''Active'' AND wi\.warehouse_stock>0\s+AND wi\.quarantined = false',
    'SELECT SUM(vp.warehouse_stock)::int FROM public.v_wh_pickable vp JOIN public.product_mapping pm2 ON pm2.boonz_product_id = vp.boonz_product_id AND pm2.pod_product_id = a.pod_product_id AND pm2.status = ''Active'' AND (pm2.machine_id IS NULL OR pm2.machine_id = a.machine_id)', 'g');

  -- read #3 (4th logical site): alert supply CTE
  v := regexp_replace(v,
    'SELECT wi\.boonz_product_id, SUM\(wi\.warehouse_stock\)::int AS wh_stock_now\s+FROM public\.warehouse_inventory wi\s+WHERE wi\.status=''Active'' AND wi\.warehouse_stock>0\s+AND wi\.quarantined = false\s+GROUP BY wi\.boonz_product_id',
    'SELECT vp.boonz_product_id, SUM(vp.warehouse_stock)::int AS wh_stock_now FROM public.v_wh_pickable vp GROUP BY vp.boonz_product_id', 'g');

  v := replace(v, 'v24_wh_aware_variant_fallback', 'v25_wh_pickable_unified');

  -- Guard: all 3 reads must have repointed (no warehouse_inventory left), else abort (a predicate drifted).
  IF v ILIKE '%warehouse_inventory%' THEN
    RAISE EXCEPTION 'PRD-040 B4: a stitch WH read did not repoint onto v_wh_pickable (warehouse_inventory still present) - the live body drifted from the expected predicate. Re-derive the regexps.';
  END IF;
  IF (length(v) - length(replace(v,'v_wh_pickable',''))) / length('v_wh_pickable') <> 3 THEN
    RAISE EXCEPTION 'PRD-040 B4: expected exactly 3 v_wh_pickable reads after rewrite, got %', (length(v) - length(replace(v,'v_wh_pickable',''))) / length('v_wh_pickable');
  END IF;

  EXECUTE v;
END $do$;
