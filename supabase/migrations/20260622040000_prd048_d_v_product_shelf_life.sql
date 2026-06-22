-- PRD-048 Step 2 (Article 16 closure): canonical shelf-life-for-sizing object.
-- Replaces engine_add_pod's inline warehouse_inventory.expiration_date read with a single
-- canonical view that CONSUMES v_wh_pickable (the canonical WH-pickable object). FEFO remaining
-- shelf-life days per (warehouse, boonz_product). Read-only, security_invoker. Dara ✅ -> Cody -> MCP.

CREATE OR REPLACE VIEW public.v_product_shelf_life
  WITH (security_invoker = true) AS
  SELECT warehouse_id,
         boonz_product_id,
         MIN(expiration_date)                              AS earliest_expiry,
         GREATEST(MIN(expiration_date) - CURRENT_DATE, 0)  AS remaining_shelf_life_days
  FROM public.v_wh_pickable
  WHERE expiration_date IS NOT NULL   -- NULL expiry imposes no spoilage constraint
  GROUP BY warehouse_id, boonz_product_id;

COMMENT ON VIEW public.v_product_shelf_life IS
  'PRD-048 / Article 16 canonical: FEFO remaining shelf-life days per (warehouse, boonz_product) for base-stock spoilage capping. Consumes v_wh_pickable (do not re-derive the pickable predicate). Sole source for engine_add_pod base_stock shelf_life_days.';
