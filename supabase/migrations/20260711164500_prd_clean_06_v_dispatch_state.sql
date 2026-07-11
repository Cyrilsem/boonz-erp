-- PRD-CLEAN-06: one canonical dispatch state view. Read-only; no writes changed.
-- Precedence grounded in the 2026-07-11 combination census (DECISIONS.md):
-- returned outranks cancelled/skipped (7 rows are cancelled/skipped AND returned -
-- recovery returns of packed lines are legal physical events per PRD-028; the
-- return credit is the operational truth). driver_outcome is not yet populated
-- anywhere (all NULL) but is kept in the precedence for forward compatibility.
CREATE OR REPLACE VIEW public.v_dispatch_state AS
SELECT
  rd.dispatch_id,
  rd.machine_id,
  rd.shelf_id,
  rd.pod_product_id,
  rd.boonz_product_id,
  rd.dispatch_date,
  rd.action,
  rd.expiry_date,
  CASE
    WHEN COALESCE(rd.returned, false) THEN 'returned'
    WHEN COALESCE(rd.cancelled, false) THEN 'cancelled'
    WHEN COALESCE(rd.skipped, false) THEN 'skipped'
    WHEN rd.driver_outcome IS NOT NULL OR COALESCE(rd.dispatched, false) THEN 'completed'
    WHEN COALESCE(rd.picked_up, false) THEN 'in_field'
    WHEN COALESCE(rd.packed, false) THEN 'packed'
    WHEN COALESCE(rd.needs_review, false) AND rd.review_status IS DISTINCT FROM 'resolved' THEN 'review'
    ELSE 'pending'
  END AS status,
  COALESCE(rd.driver_outcome_qty::numeric, rd.driver_confirmed_qty, rd.filled_quantity, rd.quantity) AS effective_qty,
  rd.quantity AS planned_qty,
  rd.original_quantity AS original_qty,
  CASE
    WHEN COALESCE(rd.is_m2m, false)
      OR COALESCE(rd.source_origin::text, 'warehouse') = 'internal_transfer'
      OR rd.from_machine_id IS NOT NULL THEN 'machine_transfer'
    WHEN COALESCE(rd.source_origin::text, 'warehouse') = 'warehouse' THEN 'warehouse'
    ELSE rd.source_origin::text
  END AS source
FROM public.refill_dispatching rd;

COMMENT ON VIEW public.v_dispatch_state IS
'PRD-CLEAN-06: canonical per-dispatch-row state. status precedence: returned > cancelled > skipped > completed (driver_outcome set OR dispatched) > in_field (picked_up) > packed > review (needs_review, unresolved) > pending. effective_qty = COALESCE(driver_outcome_qty, driver_confirmed_qty, filled_quantity, quantity). Read-only convenience - writers keep using the base columns.';
