---
id: PRD-013-refill-pipeline
program: PROGRAM-2026-05-25
title: Engine FEFO — investigate why Inactive product was planned
status: Blocked
blocked_summary: |
  V3 original hypothesis falsified — engine already has the
  status='Active' AND warehouse_stock>=1 filter. Real bug is the same
  NULL-bind class from V1 (push_plan_to_dispatch emits dispatch rows
  without pinning a wh_inventory_id when no variant candidate exists).
  Phase 1 needs CS-supervised instrumentation queries before any fix
  ships. Linked to PRD-011 root cause; close together.
severity: P0
reported: 2026-05-25
source: PROGRAM-2026-05-25 Phase 1 P0 #2 (semantic name PRD-004-refill-pipeline)
routing: [Cody]
---

## V3 finding nuance (verified live 2026-05-25)

Original V3 hypothesis: "Engine FEFO filter is not applying
`status='Active' AND warehouse_stock>0`."

Verified false. The engine `auto_generate_refill_plan` already filters:

```sql
WHERE wi.status='Active' AND wi.warehouse_id=v_machine.primary_warehouse_id
  AND wi.warehouse_stock>=1
  AND (wi.expiration_date IS NULL OR wi.expiration_date>v_plan_date+7)
```

Same predicate is present in both the swap-candidate and the
REFILL variant-assignment loops. So why did Vitamin Well Care get planned?

## Live state observed

- All 6 `warehouse_inventory` rows for Vitamin Well Care at WH_CENTRAL are
  `status='Inactive'`, `warehouse_stock=0`.
- 14 `refill_dispatching` rows for Vitamin Well Care in 2026-05-20..25
  range — of these, ~5 are engine-generated (`item_added=false`) and the
  rest are manual driver/operator additions (`item_added=true`).
- Engine-generated rows all have `from_wh_inventory_id=NULL` AND
  `expiry_date=NULL` — the same stitch-v12 NULL-bind pattern from V1.

## Hypotheses to investigate

1. **Snapshot/timing race:** WH state at plan-generation time was Active,
   then became Inactive after the plan was published. Check
   `inventory_audit_log` for status flips on these wh_inventory_ids in the
   plan-publish window.
2. **NULL-bind bypass:** The engine's variant-assignment loop reads from
   `warehouse_inventory` directly with the right filter, BUT `push_plan_to_dispatch`
   inserts rows without pinning to a specific `wh_inventory_id` — only
   `from_warehouse_id`. So even though the engine found "0 viable
   variants" (no_stock alert), the dispatch row got created anyway
   somewhere else.
3. **Manual add then engine merge:** The dispatching FE allows manual
   additions; if a manual Vitamin Well Care row exists for a machine, the
   engine might be detecting it via `v_live_shelf_stock` and trying to
   refill it.

## Proposed instrumentation (Phase 1)

Before any migration, run these audits and report back:

```sql
-- Was Vitamin Well Care ever Active at WH_CENTRAL in last 30 days?
SELECT audit_id, wh_inventory_id, old_status, new_status, occurred_at,
       rpc_name, actor_role
FROM warehouse_inventory_status_history -- or audit table that tracks status
WHERE wh_inventory_id IN (
  'bd8d6efd-9dbb-4f34-8e75-890ddd1c032d','bc9949f0-e9e1-4a07-83f1-ca6b665a218c',
  'a360e19e-e3ad-4ff5-b0a7-d2db1bd945e6','a121fb5b-5cc1-4090-84ab-2c6176db2a16',
  '49056649-5592-410b-bf03-577dad6a7bca','feb87f4d-fa8e-4e37-9b78-141274ffefc7'
)
ORDER BY occurred_at DESC;
```

## Proposed fix (Phase 2 — pending Phase 1 result)

- If hypothesis 1: harden the engine to re-validate stock at
  `push_plan_to_dispatch` time, refusing to push rows whose variant no
  longer has Active stock.
- If hypothesis 2: hard-block `push_plan_to_dispatch` from emitting rows
  with NULL `from_wh_inventory_id` for Refill/Add New actions — require
  the FEFO pin at push time (the V1 fix from PRD-011).
- If hypothesis 3: tighten `v_live_shelf_stock` to exclude manual-add rows
  that have no corresponding WH stock.

## Why this PRD is "Needs-investigation" not "Ready-to-ship"

V3 was assumed to be a missing filter. The filter is present. The bug is
real but the root cause is elsewhere. Phase 1 instrumentation must run
first — under CS supervision because the audit query touches large tables.

## Linked

- [[PRD-011-refill-pipeline]] — packing FE NULL-bind fix; shares root
  cause hypothesis 2.
- [[project_engine_v10_stitch_v12_decouple]] — the WH-decouple work whose
  side effects are felt here.
