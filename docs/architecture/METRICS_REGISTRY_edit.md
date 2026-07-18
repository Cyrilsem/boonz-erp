# METRICS_REGISTRY.md — Article 16 rows to ADD (RC-08 / Batch 1)  — closes Cody B2

Append the three rows below to the Registry table in
`docs/architecture/METRICS_REGISTRY.md` (same PR/window as RC-08 Migration A). Each
new object **builds ON** the canonical base `v_wh_pickable` and **consumes — does not
duplicate —** `v_dispatch_availability`. This is the whole point of B1: one
availability definition, not a sixth fork.

| Metric | Canonical object | Status | Known illegal copies to retire |
| --- | --- | --- | --- |
| Route-scoped pickable WH stock (rows) for a machine | `wh_available(p_machine_id, p_plan_date)` (SECURITY INVOKER, STABLE; **builds ON `v_wh_pickable`** + machine primary/secondary WHscope + reservation-awareness + plan-date expiry — the shape `rank_slot_suitability` already proved) | ✅ LIVE (RC-08 Migration A, 2026-07-18, `20260718090001_rc08a_canonical_wh_availability`) | The inline forks that re-derive the pickable predicate: `engine_add_pod.wh_avail`, `find_substitutes_for_shelf.wh` (both drop to plan-date Dubai from `CURRENT_DATE` UTC when they cut over — PHASE 2). Does NOT duplicate `v_wh_pickable`; composes it. |
| Route-scoped pickable WH **quantity** (scalar) | `wh_available_qty(p_machine_id, p_boonz_product_id, p_plan_date)` (wraps `wh_available`; SUM by SKU) | ✅ LIVE (RC-08 Migration A, 2026-07-18) | Drop-in for `stitch_pod_to_boonz.wh_avail_variant` (the whole-fleet, reservation-blind pool — the P0 offender), `engine_add_pod.wh_avail`, `find_substitutes_for_shelf.wh_stock`. One definition, four callers. Cutover is PHASE-2/CS-gated (warn-only), NOT the atomic set. |
| Warehouse FEFO coverage for a dispatch line (the push pin binding) | `wh_fefo_for_line(p_machine_id, p_boonz_product_id, p_plan_date, p_qty_needed, p_warehouse_ids uuid[])` (SECURITY INVOKER, STABLE; **builds ON `v_wh_pickable`**; **CONSUMES `v_dispatch_availability`'s `reserved_by_earlier` commitment netting — same CASE predicate, does NOT re-derive it**; explicit `p_warehouse_ids` so cold lines route to WH_CENTRAL) | ✅ LIVE (RC-08 Migration A, 2026-07-18) | The inline pin query in `push_plan_to_dispatch` (`warehouse_stock>0`, `LIMIT 1`, no netting/quarantine/expiry guard) — retired by RC-01 (`20260718090002`). Sole binding for the plan→dispatch FEFO pin. Any future "can the route WH cover this line" read MUST use this object. |

## Article-16 notes for Cody

- **Builds ON `v_wh_pickable`:** all three compose the canonical base view (Active,
  not-quarantined, in-date, stock>0). None re-implements that predicate. `wh_available`
  adds only WHscope + reservation + plan-date expiry; `wh_fefo_for_line` adds the FEFO
  order + coverage/netting; `wh_available_qty` is a SUM wrapper.
- **Consumes, does not duplicate, `v_dispatch_availability`:** `wh_fefo_for_line`'s
  `committed_elsewhere` reuses `v_dispatch_availability.reserved_by_earlier` — byte-for-byte
  the same commitment CASE (WH-origin, `packed=false`, `picked_up=false`,
  `source_origin='warehouse'`, not cancelled/skipped, `pack_outcome<>'not_filled'`,
  `Refill`/`Add New`). For a not-yet-inserted pin the view's (all-machines − same-machine)
  net collapses to "SUM of OTHER machines' live claims for this product+date." No second
  netting formula is introduced.
- **Grain safety:** batch grain (one row per `wh_inventory_id`), so pod-level callers
  join `product_mapping` (DISTINCT pod↔boonz, machine-scoped-or-global) and SUM — identical
  to the dedupe every correct caller already performs.
- **RC-03 hook (Batch 5):** `wh_available` remains the single choke point for the VOX
  sentinel exclusion. When RC-03 lands, one predicate here corrects all callers. Until then,
  VOX-routed (WH_MCC/WH_MM) availability is sentinel-inflated; cold lines routing to
  WH_CENTRAL sidestep the sentinels (they live in the VOX staging WHs, not central).
