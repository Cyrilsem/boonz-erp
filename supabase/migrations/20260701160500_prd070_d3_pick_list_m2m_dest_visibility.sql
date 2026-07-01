-- PRD-070 D-3: surface pending M2M destination legs in v_dispatch_pick_list.
--
-- convert_removes_to_m2m_transfer creates the dest Add New leg with dispatched=true (staged), which the
-- pick list excludes via its dispatched=false filter, so the driver never sees the leg to physically
-- move+refill it. push-created internal_transfer dest legs (dispatched=false) already surface.
--
-- Fix: relax ONLY the dispatched gate for pending M2M dest legs. Every other guard is preserved
-- (dispatch_date >= today, include, returned=false, picked_up=false, action <> Remove). Normal
-- warehouse legs are unchanged. This is a view CREATE OR REPLACE - it moves no stock and mutates no row.
-- The already-staged transfer 1538f35f (dest legs returned=true + past-dated) is NOT surfaced by this
-- change and is left untouched, as required.
--
-- Column list and order are byte-identical to the prior view definition; only the WHERE changed.

CREATE OR REPLACE VIEW public.v_dispatch_pick_list AS
 SELECT m.machine_id,
    m.official_name AS machine_name,
    sc.shelf_code,
    pp.pod_product_name,
    bp.product_id AS boonz_product_id,
    bp.boonz_product_name,
    s.supplier_name AS supplier,
    sum(rd.quantity) AS sku_pick_qty,
    COALESCE(( SELECT sum(wi.warehouse_stock) AS sum
           FROM warehouse_inventory wi
          WHERE ((wi.boonz_product_id = bp.product_id) AND (wi.status = 'Active'::text))), (0)::numeric) AS warehouse_stock_available,
    rd.from_warehouse_id,
    wh.name AS warehouse_name,
    rd.dispatch_date
   FROM (((((((refill_dispatching rd
     JOIN machines m ON ((m.machine_id = rd.machine_id)))
     JOIN shelf_configurations sc ON ((sc.shelf_id = rd.shelf_id)))
     JOIN pod_products pp ON ((pp.pod_product_id = rd.pod_product_id)))
     JOIN boonz_products bp ON ((bp.product_id = rd.boonz_product_id)))
     LEFT JOIN supplier_product_mapping spm ON ((spm.pod_product_id = rd.pod_product_id)))
     LEFT JOIN suppliers s ON ((s.supplier_id = spm.supplier_id)))
     LEFT JOIN warehouses wh ON ((wh.warehouse_id = rd.from_warehouse_id)))
  WHERE ((rd.dispatch_date >= CURRENT_DATE) AND (rd.include = true) AND (rd.picked_up = false) AND (rd.returned = false) AND (rd.action <> 'Remove'::text)
     AND ((rd.dispatched = false) OR ((COALESCE(rd.is_m2m, false) = true) AND (COALESCE(rd.item_added, false) = false))))
  GROUP BY m.machine_id, m.official_name, sc.shelf_code, pp.pod_product_name, bp.product_id, bp.boonz_product_name, s.supplier_name, rd.from_warehouse_id, wh.name, rd.dispatch_date;

-- DOWN: restore the dispatched=false-only WHERE (drop the M2M OR branch).
