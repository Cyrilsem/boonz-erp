-- drift-kill PHASE 2 (partial): engine_swap_pod's ONLY slot<->product identity
-- read (tag_resolved shelf fallback via v_pod_inventory_latest+mapping) now
-- resolves via the canonical v_shelf_slot_identity (WEIMI truth). Remaining
-- planogram reads are shelf-geometry/price metadata, NOT identity - kept.
-- pod_inventory stays the qty/expiry source elsewhere. swaps_enabled=false
-- (advisory output). Guarded transform; base md5 90f26896ba7e0a7099fa689e73eaab91.
DO $dk$
DECLARE
  v_def text;
  A text := E'             (SELECT pil.shelf_id FROM public.v_pod_inventory_latest pil\n                JOIN public.product_mapping pm ON pm.boonz_product_id = pil.boonz_product_id\n                                                AND pm.status=''Active'' AND pm.pod_product_id = tc.pod_out\n               WHERE pil.machine_id = tc.machine_id AND pil.status=''Active''\n               ORDER BY pil.current_stock DESC LIMIT 1)';
  B text := E'             (SELECT ssi.shelf_id FROM public.v_shelf_slot_identity ssi\n               WHERE ssi.machine_id = tc.machine_id AND ssi.pod_product_id = tc.pod_out\n                 AND ssi.match_method <> ''unmatched''\n               ORDER BY ssi.current_stock DESC NULLS LAST LIMIT 1)';
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc WHERE proname='engine_swap_pod';
  IF md5(v_def) <> '90f26896ba7e0a7099fa689e73eaab91' THEN RAISE EXCEPTION 'swap base drift %', md5(v_def); END IF;
  IF (length(v_def)-length(replace(v_def,A,'')))/length(A) <> 1 THEN RAISE EXCEPTION 'anchor count'; END IF;
  EXECUTE replace(v_def, A, B);
  RAISE NOTICE 'engine_swap_pod new md5 %', (SELECT md5(pg_get_functiondef(oid)) FROM pg_proc WHERE proname='engine_swap_pod');
END $dk$;