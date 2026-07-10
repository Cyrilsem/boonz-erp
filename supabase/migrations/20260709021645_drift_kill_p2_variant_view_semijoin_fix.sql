-- drift-kill P2 fix: product_mapping has duplicate Active rows per
-- (pod, boonz) pair (known bloat), so the JOIN fanned pod rows out
-- (stitch dry-run 196 -> 265 lines). Semi-join (EXISTS) guarantees <= 1 row
-- per pod row. Same columns, same contract.
CREATE OR REPLACE VIEW public.v_shelf_variant_identity AS
SELECT pil.machine_id, pil.shelf_id, pil.boonz_product_id,
       pil.current_stock, pil.expiration_date, pil.status,
       ssi.pod_product_id AS weimi_pod_product_id,
       ssi.pod_product_name AS weimi_pod_product_name
FROM public.v_pod_inventory_latest pil
JOIN public.v_shelf_slot_identity ssi
  ON ssi.machine_id = pil.machine_id AND ssi.shelf_id = pil.shelf_id
 AND ssi.match_method <> 'unmatched'
WHERE EXISTS (
  SELECT 1 FROM public.product_mapping pm
  WHERE pm.pod_product_id = ssi.pod_product_id
    AND pm.boonz_product_id = pil.boonz_product_id
    AND pm.status = 'Active')
UNION ALL
SELECT pil.machine_id, pil.shelf_id, pil.boonz_product_id,
       pil.current_stock, pil.expiration_date, pil.status, NULL, NULL
FROM public.v_pod_inventory_latest pil
WHERE NOT EXISTS (
  SELECT 1 FROM public.v_shelf_slot_identity ssi
  WHERE ssi.machine_id = pil.machine_id AND ssi.shelf_id = pil.shelf_id
    AND ssi.match_method <> 'unmatched');