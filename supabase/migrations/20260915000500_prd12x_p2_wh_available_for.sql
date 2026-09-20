-- PRD-125 D3 / ONE-LOOP Phase 2 -- stock at the supplying warehouse.
--
-- wh_available_for(machine_id, boonz_product_id): the single availability
-- read. venue_team-supplied products (per product_mapping.source_of_supply,
-- machine-specific Active mapping first, global default second) resolve
-- against WH_MCC + WH_MM; everything else against WH_CENTRAL. Free stock =
-- raw warehouse_inventory (Active, not quarantined, stock>0) minus pins
-- (refill_dispatching rows for that product/warehouse, action Refill/Add New,
-- not cancelled/skipped/returned/packed/dispatched, dispatch_date within the
-- next 30 days).
--
-- Verified live: Aquafina for ACTIVATE-2005 resolves to WH_MCC (377 free)
-- and WH_MM (915 free), not WH_CENTRAL (which the machine's own
-- secondary_warehouse_id column actually points to -- see the 000600
-- migration's note on why engine_add_pod needed this, not just push).
CREATE OR REPLACE FUNCTION public.wh_available_for(p_machine_id uuid, p_boonz_product_id uuid)
 RETURNS TABLE(warehouse_id uuid, free_stock numeric, fefo_expiry date)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH supply AS (
    SELECT pm.source_of_supply
      FROM public.product_mapping pm
     WHERE pm.boonz_product_id = p_boonz_product_id AND pm.status = 'Active'
       AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)
     ORDER BY (pm.machine_id = p_machine_id) DESC NULLS LAST, pm.is_global_default DESC
     LIMIT 1
  ),
  whs AS (
    SELECT unnest(
      CASE WHEN (SELECT source_of_supply FROM supply) = 'venue_team'
        THEN ARRAY['4fcfb52c-271f-4aa7-a373-3495e3271cd3'::uuid, '0aef9ccf-32ad-4545-8413-29bebd931d0b'::uuid]
        ELSE ARRAY['4bebef68-9e36-4a5c-9c2c-142f8dbdae85'::uuid]
      END
    ) AS wh_id
  ),
  raw_stock AS (
    SELECT wi.warehouse_id, SUM(wi.warehouse_stock) AS stock, MIN(wi.expiration_date) AS fefo
      FROM public.warehouse_inventory wi
      JOIN whs ON whs.wh_id = wi.warehouse_id
     WHERE wi.boonz_product_id = p_boonz_product_id
       AND COALESCE(wi.status,'Active') = 'Active'
       AND COALESCE(wi.quarantined,false) = false
       AND wi.warehouse_stock > 0
     GROUP BY wi.warehouse_id
  ),
  pinned AS (
    SELECT COALESCE(rd.from_warehouse_id, wi2.warehouse_id) AS wh_id, SUM(rd.quantity) AS qty
      FROM public.refill_dispatching rd
      LEFT JOIN public.warehouse_inventory wi2 ON wi2.wh_inventory_id = rd.from_wh_inventory_id
     WHERE rd.boonz_product_id = p_boonz_product_id
       AND rd.action IN ('Refill','Add New')
       AND COALESCE(rd.cancelled,false) = false
       AND COALESCE(rd.skipped,false) = false
       AND COALESCE(rd.returned,false) = false
       AND COALESCE(rd.packed,false) = false
       AND COALESCE(rd.dispatched,false) = false
       AND rd.dispatch_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 30
       AND COALESCE(rd.from_warehouse_id, wi2.warehouse_id) IS NOT NULL
     GROUP BY 1
  )
  SELECT whs.wh_id,
         GREATEST(COALESCE(raw_stock.stock,0) - COALESCE(pinned.qty,0), 0) AS free_stock,
         raw_stock.fefo
    FROM whs
    LEFT JOIN raw_stock ON raw_stock.warehouse_id = whs.wh_id
    LEFT JOIN pinned ON pinned.wh_id = whs.wh_id;
$function$;
