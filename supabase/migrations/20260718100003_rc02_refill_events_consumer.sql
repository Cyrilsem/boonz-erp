-- ============================================================================
-- BATCH 2 / M3 — rc02_refill_events_consumer.sql
-- RC-02 backend: give refill_events/refill_event_lines their first consumer.
--
-- DEPENDS ON: M2 (rc02_record_actual_refill_fix.sql) — the view exposes the
-- discrepancy/wh_moves columns M2 adds. Apply M2 first.
--
-- Closes:
--   a) refill_events / refill_event_lines had ZERO consumers (verified
--      2026-07-18: no view/matview in schema public depends on either table).
--      v_refill_events_recent is the read surface for FE / skills / reporting:
--      events joined to lines with machine, product, shelf, warehouse and
--      partner-machine names resolved, last 90 days.
--
--   b) VISIT CLOCKS — VERIFIED NO CHANGE NEEDED (deliberate no-op):
--      v_machine_priority sources days_since_visit from
--      v_machine_health_signals, which computes it as
--        GREATEST(lv.last_visit_date, mrv.last_manual_refill_date)
--      where the manual_refill_visit CTE reads pod_inventory_audit_log rows
--      with reference_id LIKE 'manual-refill-%' OR 'adjust-%'.
--      record_actual_refill applies every machine-facing line through
--      adjust_pod_inventory, which writes pod_inventory_audit_log with
--      reference_id = format('adjust-%s-%s-%s', machine, shelf, date).
--      => every APPLIED (non-dry-run) record_actual_refill event with at
--      least one pod-affecting line ALREADY ticks the visit clock via the
--      existing 'adjust-%' pattern. Wiring refill_events directly into
--      v_machine_health_signals would double-count those visits and would
--      mean rebuilding an 11.5k-char canonical health view — rejected as
--      risk without benefit. (WH-only events — wh_receive/wh_return with no
--      pod line — do not tick the clock; correct, they are not machine
--      visits.) Verification query in APPLY_NOTES.md.
-- ============================================================================

BEGIN;

CREATE OR REPLACE VIEW public.v_refill_events_recent AS
SELECT
  e.event_id,
  e.plan_date,
  e.captured_at,
  e.status            AS event_status,
  e.source,
  e.reason            AS event_reason,
  e.applied_at,
  e.error_text,
  e.captured_by,
  e.machine_id,
  m.official_name     AS machine_name,
  m.venue_group,
  l.line_id,
  l.action,
  l.boonz_product_id,
  bp.boonz_product_name,
  sc.shelf_code,
  l.qty,
  l.set_mode,
  l.expiration_date,
  l.warehouse_id,
  w.name              AS warehouse_name,
  l.partner_machine_id,
  pm.official_name    AS partner_machine_name,
  l.result_pod_inventory_id,
  l.applied,
  l.notes,
  l.discrepancy,
  l.wh_moves
FROM public.refill_events e
JOIN public.machines m               ON m.machine_id = e.machine_id
LEFT JOIN public.refill_event_lines l ON l.event_id = e.event_id
LEFT JOIN public.boonz_products bp    ON bp.product_id = l.boonz_product_id
LEFT JOIN public.shelf_configurations sc ON sc.shelf_id = l.shelf_id
LEFT JOIN public.warehouses w         ON w.warehouse_id = l.warehouse_id
LEFT JOIN public.machines pm          ON pm.machine_id = l.partner_machine_id
WHERE e.captured_at >= now() - interval '90 days';

COMMENT ON VIEW public.v_refill_events_recent IS
  'RC-02 read surface for record_actual_refill events (last 90 days), one row per event line (events with no lines appear once with NULL line columns). Includes discrepancy + wh_moves lineage. Consumers: FE, boonz-manual-refill skill, reporting.';

GRANT SELECT ON public.v_refill_events_recent TO authenticated, service_role;

COMMIT;
