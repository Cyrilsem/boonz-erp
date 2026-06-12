-- PRD-028 WS3: canonical WH pickable stock + dispatch availability (Article 16)
-- Design: docs/prds/prd-028/WS3-wh-pickable-dispatch-availability-design.md
-- Applied via MCP as prd028_ws3_wh_pickable_dispatch_availability (version 20260612070658).
-- v_wh_pickable (CANONICAL pickable predicate, batch grain)
--   -> v_dispatch_availability (machine/line-scoped availability; consumes pickable)
--   -> packing FE badges

-- 1) Canonical pickable predicate. security_invoker: consumers must pass
--    warehouse_inventory RLS themselves; the view must not widen access.
CREATE OR REPLACE VIEW public.v_wh_pickable
WITH (security_invoker = true) AS
WITH dubai AS (SELECT (now() AT TIME ZONE 'Asia/Dubai')::date AS today)
SELECT wi.wh_inventory_id,
       wi.boonz_product_id,
       wi.warehouse_id,
       wi.wh_location,
       wi.batch_id,
       wi.warehouse_stock,
       wi.expiration_date,
       wi.reserved_for_machine_id,
       wi.snapshot_date
FROM public.warehouse_inventory wi
CROSS JOIN dubai d
WHERE wi.status = 'Active'
  AND NOT COALESCE(wi.quarantined, false)
  AND (wi.expiration_date >= d.today OR wi.expiration_date IS NULL)
  AND wi.warehouse_stock > 0;

COMMENT ON VIEW public.v_wh_pickable IS
'CANONICAL (Article 16, METRICS_REGISTRY.md): WH pickable stock, batch grain. Active, not quarantined, in-date (Dubai operational day) or no expiry, stock > 0. Machine-agnostic: serving-warehouse scoping + reservations live in v_dispatch_availability. Consumers: v_dispatch_availability, packing FE. Never re-derive the pickable predicate inline.';

-- 2) v_dispatch_availability: wh_avail consumes v_wh_pickable; commitments are
--    unpacked AND unpicked (registry rule), same-date window partition unchanged.
CREATE OR REPLACE VIEW public.v_dispatch_availability AS
WITH wh_avail AS (
  SELECT rd.machine_id,
         rd.boonz_product_id,
         COALESCE(sum(wp.warehouse_stock), 0::numeric)::integer AS stock_now
  FROM ( SELECT DISTINCT refill_dispatching.machine_id,
                refill_dispatching.boonz_product_id
         FROM refill_dispatching
         WHERE refill_dispatching.boonz_product_id IS NOT NULL) rd
    JOIN machines m ON m.machine_id = rd.machine_id
    LEFT JOIN v_wh_pickable wp ON wp.boonz_product_id = rd.boonz_product_id
      AND (wp.warehouse_id = ANY (ARRAY[m.primary_warehouse_id, m.secondary_warehouse_id]))
      AND (wp.reserved_for_machine_id IS NULL OR wp.reserved_for_machine_id = rd.machine_id)
  GROUP BY rd.machine_id, rd.boonz_product_id
), dispatch_with_meta AS (
  SELECT rd.dispatch_id,
         rd.machine_id,
         rd.shelf_id,
         rd.pod_product_id,
         rd.boonz_product_id,
         rd.dispatch_date,
         rd.action,
         rd.quantity,
         rd.filled_quantity,
         rd.expiry_date,
         rd.item_added,
         rd.dispatched,
         rd.comment,
         rd.include,
         rd.created_at,
         rd.packed,
         rd.picked_up,
         rd.returned,
         rd.return_reason,
         rd.expiry_warning,
         rd.from_warehouse_id,
         rd.to_warehouse_id,
         rd.from_wh_inventory_id,
         rd.driver_confirmed_qty,
         rd.driver_confirmed_at,
         rd.driver_confirmed_by,
         rd.driver_confirmed_breakdown,
         rd.wh_approved_at,
         rd.wh_approved_by,
         rd.is_m2m,
         rd.m2m_partner_id,
         rd.m2m_transfer_id,
         rd.source_origin,
         rd.from_machine_id,
         COALESCE(sum(
             CASE
                 WHEN (rd.action = ANY (ARRAY['Refill'::text, 'Add New'::text])) AND rd.packed = false AND rd.picked_up = false AND rd.source_origin = 'warehouse'::source_origin_enum THEN rd.quantity
                 ELSE 0::numeric
             END) OVER (PARTITION BY rd.boonz_product_id, rd.dispatch_date ORDER BY rd.dispatch_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0::numeric)::integer AS reserved_by_earlier
  FROM refill_dispatching rd
)
SELECT d.dispatch_id,
       d.machine_id,
       d.shelf_id,
       d.pod_product_id,
       d.boonz_product_id,
       d.dispatch_date,
       d.action,
       d.quantity AS target_qty,
       d.source_origin,
       d.from_machine_id,
       d.packed,
       d.picked_up,
       d.dispatched,
       d.returned,
       d.comment,
       COALESCE(wh.stock_now, 0) AS wh_stock_now,
       d.reserved_by_earlier,
       CASE
           WHEN d.source_origin = ANY (ARRAY['internal_transfer'::source_origin_enum, 'vox_at_venue'::source_origin_enum]) THEN d.quantity::integer
           WHEN d.action = ANY (ARRAY['Remove'::text, 'Machine To Warehouse'::text]) THEN d.quantity::integer
           ELSE LEAST(d.quantity, GREATEST(COALESCE(wh.stock_now, 0) - d.reserved_by_earlier, 0)::numeric)::integer
       END AS available_qty,
       CASE
           WHEN d.packed THEN 'packed'::text
           WHEN d.source_origin = ANY (ARRAY['internal_transfer'::source_origin_enum, 'vox_at_venue'::source_origin_enum]) THEN 'ready'::text
           WHEN d.action = ANY (ARRAY['Remove'::text, 'Machine To Warehouse'::text]) THEN 'ready'::text
           WHEN (COALESCE(wh.stock_now, 0) - d.reserved_by_earlier)::numeric >= d.quantity THEN 'ready'::text
           WHEN (COALESCE(wh.stock_now, 0) - d.reserved_by_earlier) > 0 THEN 'partial'::text
           ELSE 'blocked_no_wh'::text
       END AS pack_status
FROM dispatch_with_meta d
  LEFT JOIN wh_avail wh ON wh.machine_id = d.machine_id AND wh.boonz_product_id = d.boonz_product_id;

COMMENT ON VIEW public.v_dispatch_availability IS
'CANONICAL (Article 16, METRICS_REGISTRY.md): dispatch committed/available per line. available = pickable (v_wh_pickable, serving WHs, reservation-aware) minus earlier unpacked+unpicked warehouse-origin claims for the same product+dispatch_date. Consumers: packing FE. Never re-derive availability inline.';