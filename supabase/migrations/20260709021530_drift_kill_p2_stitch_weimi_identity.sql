-- drift-kill PHASE 2 (completion): stitch_pod_to_boonz identity source -> WEIMI.
--
-- v_shelf_variant_identity = pod_inventory rows FILTERED to variants of the
-- shelf's live WEIMI product (identity from v_shelf_slot_identity +
-- product_mapping; quantity/expiry still from the pod rows). Shelves WEIMI
-- cannot resolve (no snapshot / unmatched) pass through unfiltered so blind
-- shelves regress nothing. Column names mirror v_pod_inventory_latest usage
-- (machine_id, shelf_id, boonz_product_id, current_stock, expiration_date,
-- status) so stitch's four read sites swap sources with zero logic edits:
-- a pod row claiming a foreign product on a shelf is now INVISIBLE to stitch.
-- Guarded transform; stitch base md5 49235be6d9c9a14580f0abc92c4755bd
-- (v28 + drift-kill guard tail). engine_version -> v29_driftkill_weimi_identity.
-- Dara-designed, Cody-reviewed (Articles 1,12,14,16; Am.005).

CREATE OR REPLACE VIEW public.v_shelf_variant_identity AS
SELECT pil.machine_id, pil.shelf_id, pil.boonz_product_id,
       pil.current_stock, pil.expiration_date, pil.status,
       ssi.pod_product_id AS weimi_pod_product_id,
       ssi.pod_product_name AS weimi_pod_product_name
FROM public.v_pod_inventory_latest pil
JOIN public.v_shelf_slot_identity ssi
  ON ssi.machine_id = pil.machine_id AND ssi.shelf_id = pil.shelf_id
 AND ssi.match_method <> 'unmatched'
JOIN public.product_mapping pm
  ON pm.pod_product_id = ssi.pod_product_id
 AND pm.boonz_product_id = pil.boonz_product_id
 AND pm.status = 'Active'
UNION ALL
SELECT pil.machine_id, pil.shelf_id, pil.boonz_product_id,
       pil.current_stock, pil.expiration_date, pil.status, NULL, NULL
FROM public.v_pod_inventory_latest pil
WHERE NOT EXISTS (
  SELECT 1 FROM public.v_shelf_slot_identity ssi
  WHERE ssi.machine_id = pil.machine_id AND ssi.shelf_id = pil.shelf_id
    AND ssi.match_method <> 'unmatched');

COMMENT ON VIEW public.v_shelf_variant_identity IS
'drift-kill Phase 2: pod_inventory rows visible ONLY where their variant belongs to the shelf''s live WEIMI product (identity via v_shelf_slot_identity + product_mapping; qty/expiry from pod rows). WEIMI-blind shelves pass through unfiltered. Stitch reads shelf-variant identity exclusively through this view.';

DO $dk$
DECLARE
  v_def text; v_n int;
  A text := 'public.v_pod_inventory_latest pil';
  B text := 'public.v_shelf_variant_identity pil';
  V text := '''engine_version'',''v28_remove_conservation_planqty'',';
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc WHERE proname='stitch_pod_to_boonz';
  IF md5(v_def) <> '49235be6d9c9a14580f0abc92c4755bd' THEN RAISE EXCEPTION 'stitch base drift %', md5(v_def); END IF;
  v_n := (length(v_def)-length(replace(v_def,A,'')))/length(A);
  IF v_n <> 4 THEN RAISE EXCEPTION 'expected 4 identity sites, found %', v_n; END IF;
  v_def := replace(v_def, A, B);
  v_n := (length(v_def)-length(replace(v_def,V,'')))/length(V);
  IF v_n <> 1 THEN RAISE EXCEPTION 'version anchor count %', v_n; END IF;
  v_def := replace(v_def, V, '''engine_version'',''v29_driftkill_weimi_identity'',');
  EXECUTE v_def;
  RAISE NOTICE 'stitch v29 md5 %', (SELECT md5(pg_get_functiondef(oid)) FROM pg_proc WHERE proname='stitch_pod_to_boonz');
END $dk$;