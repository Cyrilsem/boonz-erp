-- backported from prod schema_migrations on 2026-07-18, RC-15 parity
-- version: 20260714235045  name: fixD2_edit_dispatch_product_shelf_binding
-- FIX D2 — edit_dispatch_product: resolve pod from the shelf's live binding
-- (slot_lifecycle is_current) instead of the product_mapping is_global_default
-- default, mirroring the fix already shipped to add_dispatch_row.
--
-- Method: fetch the LIVE function text server-side, assert the old pod-resolution
-- hunk occurs exactly once, replace only that hunk, and re-create the function.
-- Every untouched region is preserved byte-identical (GUCs, role guard, FOR UPDATE
-- lock, picked_up/item_added guards, UPDATE columns, edit-log write, RETURN).
DO $mig$
DECLARE
  v_src text;
  v_cnt int;
  v_old text := $old$  -- Resolve pod_product_id via product_mapping (per-machine wins)
  SELECT pm.pod_product_id INTO v_new_pod
  FROM public.product_mapping pm
  WHERE pm.boonz_product_id = p_new_boonz_product_id
    AND pm.status = 'Active'
    AND (pm.machine_id = v_row.machine_id OR pm.machine_id IS NULL)
  ORDER BY (pm.machine_id = v_row.machine_id) DESC NULLS LAST, pm.is_global_default DESC
  LIMIT 1;
  IF v_new_pod IS NULL THEN
    RAISE EXCEPTION 'boonz_product % has no Active product_mapping for machine %', p_new_boonz_product_id, v_row.machine_id;
  END IF;$old$;
  v_new text := $new$  -- FIX D2: resolve pod from the SHELF BINDING (slot_lifecycle current pod), not the
  -- product_mapping default. Accept the shelf-bound pod only when it carries the new
  -- boonz SKU via an Active product_mapping, so pod_product_id stays consistent with
  -- boonz_product_id. Fall back to product_mapping (per-machine wins, then global
  -- default) only when the shelf has no current binding that carries this SKU.
  SELECT sl.pod_product_id INTO v_new_pod
  FROM public.slot_lifecycle sl
  WHERE sl.machine_id = v_row.machine_id
    AND sl.shelf_id   = v_row.shelf_id
    AND sl.is_current = true
    AND sl.archived   = false
    AND EXISTS (
      SELECT 1 FROM public.product_mapping pm2
      WHERE pm2.pod_product_id   = sl.pod_product_id
        AND pm2.boonz_product_id = p_new_boonz_product_id
        AND pm2.status = 'Active'
    )
  ORDER BY sl.rotated_in_at DESC NULLS LAST
  LIMIT 1;

  IF v_new_pod IS NULL THEN
    SELECT pm.pod_product_id INTO v_new_pod
    FROM public.product_mapping pm
    WHERE pm.boonz_product_id = p_new_boonz_product_id
      AND pm.status = 'Active'
      AND (pm.machine_id = v_row.machine_id OR pm.machine_id IS NULL)
    ORDER BY (pm.machine_id = v_row.machine_id) DESC NULLS LAST, pm.is_global_default DESC
    LIMIT 1;
  END IF;

  IF v_new_pod IS NULL THEN
    RAISE EXCEPTION 'boonz_product % has no Active product_mapping for machine %', p_new_boonz_product_id, v_row.machine_id;
  END IF;$new$;
BEGIN
  v_src := pg_get_functiondef('public.edit_dispatch_product(uuid,uuid,text,text,text)'::regprocedure);

  v_cnt := (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old);
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'fixD2 abort: expected exactly 1 occurrence of old pod-resolution hunk, found %', v_cnt;
  END IF;

  EXECUTE replace(v_src, v_old, v_new);
END
$mig$;
