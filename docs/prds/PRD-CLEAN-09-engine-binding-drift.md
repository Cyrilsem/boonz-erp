# PRD-CLEAN-09 — Engine-side binding-drift fix

Status: DONE (2026-07-12) — pre-run assertion (v_slot_binding_drift count must be 0 or
the plan halts) live in BOTH engines + defense-in-depth hard-skip (clamp_reason
'binding_drift'; drifted shelves excluded from all 4 swap passes) + nightly 05:30 Dubai
alert cron. Positive/negative tests + full dry cycle passed in rolled-back txns.

## Spec (CS, 2026-07-12)
Modify engine_add_pod and engine_swap_pod: derive pod_product_id from
v_live_shelf_stock OR hard-skip any shelf where slot_lifecycle.pod_product_id <>
v_live_shelf_stock.pod_product_id with clamp_reason 'binding_drift'. Pre-run assertion:
COUNT(*) FROM v_slot_binding_drift must be 0 or the plan halts. Nightly check 05:30
Dubai alerting on non-empty v_slot_binding_drift. Save definitions to rollback/ first.
Join axis: regexp_replace(slot_name, '^([A-Z])(\d)$', '\10\2') = shelf_code, never
aisle_code.

## What shipped
- v_slot_binding_drift already existed with exactly the specified join axis (reused).
- engine_add_pod: assertion right after param validation (RAISE aborts the whole
  engine txn, so partial DELETEs roll back); drifted shelves -> qty 0 +
  clamp_reason='binding_drift' (visible row), excluded from dead-tagging, WH
  allocation pool and procurement gaps; new return field binding_drift_skipped.
- engine_swap_pod: same assertion; _binding_drift temp table excludes drifted shelves
  from strategic-tag, dead-resolution, driver-recommendation and value-model passes.
- cron_slot_binding_drift_alert() + cron.schedule('slot_binding_drift_nightly',
  '30 1 * * *') -> monitoring_alerts severity critical with full row payload.
- Chose HARD-SKIP over derive-from-vls: minimal diff to the live engines; the
  assertion makes wrong-product lines impossible, the skip is defense-in-depth if the
  assertion is ever relaxed.

## Rollback
- docs/prds/rollback/engine_add_pod_2026-07-12.sql
- docs/prds/rollback/engine_swap_pod_2026-07-12.sql
- SELECT cron.unschedule('slot_binding_drift_nightly');
  DROP FUNCTION public.cron_slot_binding_drift_alert();
