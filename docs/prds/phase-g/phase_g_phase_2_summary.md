# Phase G Phase 2 Summary

**Phase:** G (Inventory Integrity Initiative) Phase 2 — Close the biggest leak
**PRD:** `docs/prds/phase-g/prd_inventory_integrity_phase_g_v2.md` Section 11
**Window:** 2026-05-25 (shipped one week ahead of the PRD's nominal week-of-2026-06-01 schedule)
**Status:** Done. All four scoped items shipped with smoke verification.

## Shipped

### A.1 — pack_dispatch_line refuses NULL from_wh_inventory_id

Migration `phaseG_p2_a1_pack_dispatch_line_refuse_null_from_wh` adds a guard at the top of the pick loop, before the `::uuid` cast that previously masked the error with a misleading "WH row <NULL> not found" message. Same 3-arg signature with the `p_packed_by uuid DEFAULT NULL` preserved.

Smoke 9.3 (live prod): direct call with `{"qty":1,"wh_inventory_id":null}` raised `pack_dispatch_line: every pick must include from_wh_inventory_id (BUG-006 prevention). Dispatch <id>, pick payload: ...`. Refusal confirmed at the RPC layer.

### A.5 — eod_auto_release_unpicked sweep narrowed + cron re-enabled

Migration `phaseG_p2_a5_eod_auto_release_action_narrow_then_reenable_cron` narrows the EOD sweep from any-action to the case-sensitive set `IN ('Refill','Add New','Add')` matching the `pack_dispatch_line` short-circuit contract.

Cody flagged that an "inclusive" allow-list like `('REFILL','ADD NEW',...)` would have recreated the bug because uppercase variants short-circuit pack with no WH decrement, so sweeping them via `return_dispatch_line` would credit phantom WH. The narrow list is the right contract.

The migration re-enabled cron job 9 atomically in the same transaction via `cron.alter_job(job_id := 9::bigint, active := true)`.

Smoke 9.5 (live prod): over all 16 live action variants in `refill_dispatching`, only `Refill / Add New / Add` get swept; everything else (`Remove`, `REMOVE`, `Machine To Warehouse`, `MOVE`, `REFILL` upper, `ADD NEW` upper, `Backup`, `Calibrate`, `Keep`, `Replace`, `Transfer`, NULL) is excluded.

### C.5 — v_wh_inventory_movement_trail view

Migration `phaseG_p2_c5_v_wh_inventory_movement_trail` creates the SECURITY INVOKER view that unions five event streams keyed on `wh_inventory_id`:

1. `inventory_audit_log` — quantity deltas with reason.
2. `write_audit_log` filtered to `table_name='warehouse_inventory'` with regex-validated UUID `row_pk`.
3. `refill_dispatching` rows with `from_wh_inventory_id` matching (pack and receive).
4. `purchase_orders` reached via `batch_id LIKE '%-<short_po_line_id>-B%'` provenance match (the format `receive_purchase_order` uses for batch_id strings).
5. `inventory_control_attempt` rows touching this wh_inventory_id.

Each row carries `wh_inventory_id, event_class, event_time, actor, summary, payload`. RLS inherits from underlying tables (the view is SECURITY INVOKER by default). `GRANT SELECT TO authenticated`.

Quick check on prod: 5 sample rows returned 5 inventory_audit + 5 write_audit + 3 po_provenance events.

### B.4 — Movement trail drawer on /app/inventory

New `src/components/inventory/MovementTrail.tsx` renders the trail lazily (loads on expand) per row. Wired into the operator inventory drawer in `/app/inventory/page.tsx` after the existing Field rows in read mode. tsc and next build both clean.

Field-side surface deferred: `/field/inventory/[id]/page.tsx` would benefit from the same trail; not in Phase 2 scope per PRD Section 11 (the PRD only lists B.4 once, no mention of dual-page rollout). Flag for a follow-up if mobile WH manager needs it.

## Out of scope (still deferred per Section 11)

- **Phase 3 (week of 2026-06-08):** A.2 (PO physical receipt gate), A.3 (consumer_stock phantom drain), B.7 (PO confirm chip), C.6/C.7 (daily reconciliation view + cron). Tests from 9.1 must pass.
- **Phase 4 (week of 2026-06-15):** A.6 (auto-receive on dispatch), A.7 (audit then hard-block direct WH UPDATE), A.8 (M2M flow audit), B.3 (reason dropdown), B.5 (session viewer), B.6 (control mode soft lock). Tests from 9.4 and 9.6 must pass.

## Acceptance gate

Per PRD Section 11: "Tests from 9.3 and 9.5 must pass." Both verified live on prod. Phase 2 closes.

## Commits

- `a967cdb` feat(phase-g-p2): close the biggest leak (A.1 + A.5 + C.5 + B.4)

This summary file is the canonical artifact for the Phase 2 close-out.
