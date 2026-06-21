-- PRD-045 P0: warehouse availability & commitment correctness. Read-model only (CREATE OR REPLACE
-- VIEW); NO table change, NO stock mutation. Not consumed by any function (verified) - engine/stitch/
-- picker untouched. Fixes the over-counted `committed` that produced false Available=0.
--
-- v_dispatch_availability.reserved_by_earlier was a running window over (boonz_product_id,
-- dispatch_date) of Refill/AddNew unpacked warehouse lines. Two bugs:
--   (1) it did NOT exclude cancelled / skipped / not_filled lines (they still held a reservation).
--   (2) it counted the machine's OWN earlier lines, so a machine competed with itself (T9).
-- Fix:
--   - qualifying line = action in (Refill, Add New), NOT packed, NOT picked_up, source_origin=warehouse,
--     AND NOT cancelled AND NOT skipped AND pack_outcome <> not_filled.
--   - reserved_by_earlier = (earlier qualifying over boonz+date) MINUS (earlier qualifying over
--     boonz+date+machine) = earlier commitment from OTHER machines only (FEFO running fairness kept,
--     self-commit removed).
--   - new `oversubscribed` flag: true when a fillable line's demand exceeds stock after others'
--     commitment (so it is visible, not silently floored to 0). available_qty still floors at 0.
-- v_dispatch_pickable re-exposed to carry oversubscribed. v_wh_pickable unchanged (raw pickable,
-- engine input).

CREATE OR REPLACE VIEW public.v_dispatch_availability AS
 WITH wh_avail AS (
   SELECT rd.machine_id, rd.boonz_product_id,
     (COALESCE(sum(wp.warehouse_stock), (0)::numeric))::integer AS stock_now
    FROM (((SELECT DISTINCT refill_dispatching.machine_id, refill_dispatching.boonz_product_id
              FROM refill_dispatching
             WHERE (refill_dispatching.boonz_product_id IS NOT NULL)) rd
      JOIN machines m ON ((m.machine_id = rd.machine_id)))
      LEFT JOIN v_wh_pickable wp ON (((wp.boonz_product_id = rd.boonz_product_id)
            AND (wp.warehouse_id = ANY (ARRAY[m.primary_warehouse_id, m.secondary_warehouse_id]))
            AND ((wp.reserved_for_machine_id IS NULL) OR (wp.reserved_for_machine_id = rd.machine_id)))))
    GROUP BY rd.machine_id, rd.boonz_product_id
 ), dispatch_with_meta AS (
   SELECT rd.dispatch_id, rd.machine_id, rd.shelf_id, rd.pod_product_id, rd.boonz_product_id,
     rd.dispatch_date, rd.action, rd.quantity, rd.filled_quantity, rd.expiry_date, rd.item_added,
     rd.dispatched, rd.comment, rd.include, rd.created_at, rd.packed, rd.picked_up, rd.returned,
     rd.return_reason, rd.expiry_warning, rd.from_warehouse_id, rd.to_warehouse_id, rd.from_wh_inventory_id,
     rd.driver_confirmed_qty, rd.driver_confirmed_at, rd.driver_confirmed_by, rd.driver_confirmed_breakdown,
     rd.wh_approved_at, rd.wh_approved_by, rd.is_m2m, rd.m2m_partner_id, rd.m2m_transfer_id,
     rd.source_origin, rd.from_machine_id,
     (
       COALESCE(sum(
         CASE WHEN ((rd.action = ANY (ARRAY['Refill'::text, 'Add New'::text]))
                AND (rd.packed = false) AND (rd.picked_up = false)
                AND (rd.source_origin = 'warehouse'::source_origin_enum)
                AND (COALESCE(rd.cancelled, false) = false)
                AND (COALESCE(rd.skipped, false) = false)
                AND (COALESCE(rd.pack_outcome::text, '') <> 'not_filled'))
              THEN rd.quantity ELSE (0)::numeric END)
         OVER (PARTITION BY rd.boonz_product_id, rd.dispatch_date ORDER BY rd.dispatch_id
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), (0)::numeric)
       - COALESCE(sum(
         CASE WHEN ((rd.action = ANY (ARRAY['Refill'::text, 'Add New'::text]))
                AND (rd.packed = false) AND (rd.picked_up = false)
                AND (rd.source_origin = 'warehouse'::source_origin_enum)
                AND (COALESCE(rd.cancelled, false) = false)
                AND (COALESCE(rd.skipped, false) = false)
                AND (COALESCE(rd.pack_outcome::text, '') <> 'not_filled'))
              THEN rd.quantity ELSE (0)::numeric END)
         OVER (PARTITION BY rd.boonz_product_id, rd.dispatch_date, rd.machine_id ORDER BY rd.dispatch_id
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), (0)::numeric)
     )::integer AS reserved_by_earlier
    FROM refill_dispatching rd
 )
 SELECT d.dispatch_id, d.machine_id, d.shelf_id, d.pod_product_id, d.boonz_product_id, d.dispatch_date,
    d.action, d.quantity AS target_qty, d.source_origin, d.from_machine_id, d.packed, d.picked_up,
    d.dispatched, d.returned, d.comment,
    COALESCE(wh.stock_now, 0) AS wh_stock_now,
    d.reserved_by_earlier,
    CASE
      WHEN (d.source_origin = ANY (ARRAY['internal_transfer'::source_origin_enum, 'vox_at_venue'::source_origin_enum])) THEN (d.quantity)::integer
      WHEN (d.action = ANY (ARRAY['Remove'::text, 'Machine To Warehouse'::text])) THEN (d.quantity)::integer
      ELSE (LEAST(d.quantity, (GREATEST((COALESCE(wh.stock_now, 0) - d.reserved_by_earlier), 0))::numeric))::integer
    END AS available_qty,
    CASE
      WHEN d.packed THEN 'packed'::text
      WHEN (d.source_origin = ANY (ARRAY['internal_transfer'::source_origin_enum, 'vox_at_venue'::source_origin_enum])) THEN 'ready'::text
      WHEN (d.action = ANY (ARRAY['Remove'::text, 'Machine To Warehouse'::text])) THEN 'ready'::text
      WHEN (((COALESCE(wh.stock_now, 0) - d.reserved_by_earlier))::numeric >= d.quantity) THEN 'ready'::text
      WHEN ((COALESCE(wh.stock_now, 0) - d.reserved_by_earlier) > 0) THEN 'partial'::text
      ELSE 'blocked_no_wh'::text
    END AS pack_status,
    CASE
      WHEN (d.source_origin = ANY (ARRAY['internal_transfer'::source_origin_enum, 'vox_at_venue'::source_origin_enum])) THEN false
      WHEN (d.action = ANY (ARRAY['Remove'::text, 'Machine To Warehouse'::text])) THEN false
      WHEN d.packed THEN false
      ELSE ((d.quantity)::numeric > (GREATEST((COALESCE(wh.stock_now, 0) - d.reserved_by_earlier), 0))::numeric)
    END AS oversubscribed
   FROM (dispatch_with_meta d
     LEFT JOIN wh_avail wh ON (((wh.machine_id = d.machine_id) AND (wh.boonz_product_id = d.boonz_product_id))));

CREATE OR REPLACE VIEW public.v_dispatch_pickable AS
 SELECT da.dispatch_id, da.machine_id, da.boonz_product_id, da.pod_product_id, da.shelf_id,
    da.dispatch_date, da.action, da.target_qty, da.packed, da.picked_up,
    da.wh_stock_now AS serving_pickable_units, da.reserved_by_earlier, da.available_qty, da.pack_status,
    COALESCE(s.stranded_units, 0) AS stranded_units, s.stranded_warehouses,
    da.oversubscribed
   FROM (v_dispatch_availability da
     LEFT JOIN LATERAL ( SELECT (sum(p.warehouse_stock))::integer AS stranded_units,
            array_agg(DISTINCT p.warehouse_id) AS stranded_warehouses
           FROM (v_wh_pickable p
             JOIN machines m ON ((m.machine_id = da.machine_id)))
          WHERE ((p.boonz_product_id = da.boonz_product_id)
             AND ((p.reserved_for_machine_id IS NULL) OR (p.reserved_for_machine_id = da.machine_id))
             AND (NOT (p.warehouse_id IN ( SELECT w.w
                   FROM unnest(ARRAY[m.primary_warehouse_id, m.secondary_warehouse_id]) w(w)
                  WHERE (w.w IS NOT NULL)))))) s ON (true));
