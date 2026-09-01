-- PRD-118 item D fix #3: stitch_pod_to_boonz has 3 fleet-wide SUM(v_wh_pickable) sites
-- (wh_avail_variant, resolved_no_wh_stock_warning classification, procurement_alerts
-- wh_stock_now), none excluding sentinel rows. Adds NOT _is_phantom_wh_row_v3(...) to
-- all 3. (Note: a 4th mention at the WH-aware sibling redistribution comment is not a
-- separate query site — that logic consumes the already-computed wh_avail_variant
-- column from site 1, so fixing site 1 fixes it too.) Verified against md5
-- 74121056985fc1cceffe2b7a94756f50. Cody: approve, Articles 1/12/16 — all 3 sites read
-- the canonical v_wh_pickable object directly (not re-derived); adding the canonical
-- sentinel predicate on top is a refinement, not a competing definition.
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.proname='stitch_pod_to_boonz' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '74121056985fc1cceffe2b7a94756f50' THEN
    RAISE EXCEPTION 'stitch_pod_to_boonz drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;

  v_new := replace(v_def,
    'FROM public.v_wh_pickable vp WHERE vp.boonz_product_id = pv.boonz_product_id), 0) AS wh_avail_variant',
    'FROM public.v_wh_pickable vp WHERE vp.boonz_product_id = pv.boonz_product_id AND NOT public._is_phantom_wh_row_v3(vp.batch_id, vp.expiration_date)), 0) AS wh_avail_variant');
  IF v_new = v_def THEN RAISE EXCEPTION 'site 1 (wh_avail_variant) not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
    $$WHEN COALESCE((SELECT SUM(vp.warehouse_stock)::int FROM public.v_wh_pickable vp WHERE EXISTS (SELECT 1 FROM public.product_mapping pm2 WHERE pm2.boonz_product_id = vp.boonz_product_id AND pm2.pod_product_id = a.pod_product_id AND pm2.status = 'Active' AND (pm2.machine_id IS NULL OR pm2.machine_id = a.machine_id))), 0) = 0$$,
    $$WHEN COALESCE((SELECT SUM(vp.warehouse_stock)::int FROM public.v_wh_pickable vp WHERE EXISTS (SELECT 1 FROM public.product_mapping pm2 WHERE pm2.boonz_product_id = vp.boonz_product_id AND pm2.pod_product_id = a.pod_product_id AND pm2.status = 'Active' AND (pm2.machine_id IS NULL OR pm2.machine_id = a.machine_id)) AND NOT public._is_phantom_wh_row_v3(vp.batch_id, vp.expiration_date)), 0) = 0$$);
  IF v_new = v_def THEN RAISE EXCEPTION 'site 2 (resolved_no_wh_stock_warning) not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
    'SELECT vp.boonz_product_id, SUM(vp.warehouse_stock)::int AS wh_stock_now FROM public.v_wh_pickable vp GROUP BY vp.boonz_product_id',
    'SELECT vp.boonz_product_id, SUM(vp.warehouse_stock)::int AS wh_stock_now FROM public.v_wh_pickable vp WHERE NOT public._is_phantom_wh_row_v3(vp.batch_id, vp.expiration_date) GROUP BY vp.boonz_product_id');
  IF v_new = v_def THEN RAISE EXCEPTION 'site 3 (procurement_alerts wh_stock_now) not found'; END IF;
  v_def := v_new;

  EXECUTE v_def;
END $mig$;
