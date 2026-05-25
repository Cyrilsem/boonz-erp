-- PRD-Phase-G v2 C.5: per-wh_inventory_id movement trail view.
-- SECURITY INVOKER (default for views), so underlying RLS gates visibility
-- per role. Read-only. Applied to prod 2026-05-25.
--
-- Streams:
--   1. inventory_audit_log entries (qty deltas with reason)
--   2. write_audit_log entries with row_pk = wh_inventory_id (any column change)
--   3. refill_dispatching rows with from_wh_inventory_id matching (pack/receive)
--   4. purchase_orders lines reached via batch_id LIKE provenance match
--   5. inventory_control_attempt rows touching this wh_inventory_id

CREATE OR REPLACE VIEW public.v_wh_inventory_movement_trail AS

SELECT
  ial.wh_inventory_id,
  'inventory_audit'::text AS event_class,
  ial.audited_at AS event_time,
  ial.adjusted_by AS actor,
  format('qty %s -> %s (delta %s) - %s',
    COALESCE(ial.old_qty::text, '?'),
    COALESCE(ial.new_qty::text, '?'),
    COALESCE(ial.delta::text, '?'),
    COALESCE(ial.reason, 'no reason')) AS summary,
  jsonb_build_object(
    'old_qty', ial.old_qty,
    'new_qty', ial.new_qty,
    'delta', ial.delta,
    'reason', ial.reason
  ) AS payload
FROM public.inventory_audit_log ial

UNION ALL

SELECT
  ial.row_pk::uuid AS wh_inventory_id,
  'write_audit'::text AS event_class,
  ial.occurred_at AS event_time,
  ial.actor,
  format('%s %s by %s%s',
    ial.operation, ial.table_name,
    COALESCE(ial.actor_role, '?'),
    CASE WHEN ial.rpc_name IS NOT NULL
         THEN ' via ' || ial.rpc_name ELSE '' END) AS summary,
  ial.payload
FROM public.write_audit_log ial
WHERE ial.table_name = 'warehouse_inventory'
  AND ial.row_pk ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

UNION ALL

SELECT
  rd.from_wh_inventory_id AS wh_inventory_id,
  'dispatch'::text AS event_class,
  rd.dispatch_date::timestamptz AS event_time,
  NULL::uuid AS actor,
  format('%s qty %s for machine %s (packed=%s, picked_up=%s, dispatched=%s, returned=%s)',
    COALESCE(rd.action, '?'),
    COALESCE(rd.quantity::text, '?'),
    COALESCE(rd.machine_id::text, '?'),
    rd.packed, rd.picked_up, rd.dispatched, rd.returned) AS summary,
  jsonb_build_object(
    'dispatch_id', rd.dispatch_id,
    'machine_id', rd.machine_id,
    'action', rd.action,
    'quantity', rd.quantity,
    'expiry_date', rd.expiry_date,
    'packed', rd.packed,
    'picked_up', rd.picked_up,
    'dispatched', rd.dispatched,
    'returned', rd.returned
  ) AS payload
FROM public.refill_dispatching rd
WHERE rd.from_wh_inventory_id IS NOT NULL

UNION ALL

SELECT
  wi.wh_inventory_id,
  'po_provenance'::text AS event_class,
  po.received_date::timestamptz AS event_time,
  NULL::uuid AS actor,
  format('PO line %s: ordered %s @ %s AED, received %s on %s',
    left(po.po_line_id::text, 8),
    COALESCE(po.ordered_qty::text, '?'),
    COALESCE(po.price_per_unit_aed::text, '?'),
    COALESCE(po.received_qty::text, '?'),
    COALESCE(po.received_date::text, '?')) AS summary,
  jsonb_build_object(
    'po_line_id', po.po_line_id,
    'ordered_qty', po.ordered_qty,
    'received_qty', po.received_qty,
    'received_date', po.received_date,
    'price_per_unit_aed', po.price_per_unit_aed,
    'expiry_date', po.expiry_date,
    'purchase_outcome', po.purchase_outcome
  ) AS payload
FROM public.warehouse_inventory wi
JOIN public.purchase_orders po
  ON wi.batch_id IS NOT NULL
 AND wi.batch_id LIKE '%-' || left(po.po_line_id::text, 8) || '-B%'
WHERE po.received_date IS NOT NULL

UNION ALL

SELECT
  ica.wh_inventory_id,
  'control_attempt'::text AS event_class,
  ica.attempted_at AS event_time,
  ica.attempted_by AS actor,
  format('attempt_%s via %s (result=%s) - %s',
    COALESCE(ica.field_changed, '?'),
    COALESCE(ica.rpc_called, '?'),
    COALESCE(ica.result, '?'),
    COALESCE(ica.reason, 'no reason')) AS summary,
  jsonb_build_object(
    'field_changed', ica.field_changed,
    'old_value', ica.old_value,
    'new_value', ica.new_value,
    'rpc_called', ica.rpc_called,
    'result', ica.result,
    'reason', ica.reason
  ) AS payload
FROM public.inventory_control_attempt ica
WHERE ica.wh_inventory_id IS NOT NULL;

GRANT SELECT ON public.v_wh_inventory_movement_trail TO authenticated;
