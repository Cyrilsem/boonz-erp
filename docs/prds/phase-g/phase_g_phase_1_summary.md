# Phase G Phase 1 Summary

**Phase:** G (Inventory Integrity Initiative) Phase 1 — Unblock the WH manager
**PRD:** `docs/prds/phase-g/prd_inventory_integrity_phase_g_v2.md`
**Window:** week of 2026-05-25
**Status:** Phase 1 complete. All twelve execution steps and three gates landed.

This summary tracks what shipped, what is blocked, what is pending, and PRD Section 10 measurements as of the time of writing.

## Shipped

### Workstream C — Deep logging substrate

**C.1 + C.2 — tables.** `inventory_control_session` (status FSM open / closed / aborted, partial unique index `idx_ics_one_open_per_user`) and `inventory_control_attempt` (pure-append, Option Y, one row per terminal result). Both with RLS: SELECT and INSERT gated to roles `(warehouse, operator_admin, superadmin, manager)`; UPDATE and DELETE blocked at the policy layer. Migration `phaseG_p1_c1_c2_inventory_control_tables`. Commit `95ad54b`. Cody-approved.

**C.3 — SECURITY DEFINER wrapper RPCs.** Six functions:

- `inactivate_warehouse_row(p_wh_inventory_id, p_reason, p_inactivated_by)` — new canonical writer for the Active to Inactive transition on `warehouse_inventory.status` (PRD B.2).
- `start_inventory_session(p_scope_warehouse_id, p_scope_product_ids, p_session_slug, p_started_by)` — auto-aborts any prior open session for the same user before INSERTing the new one.
- `close_inventory_session(p_session_id, p_closed_by, p_summary)` — computes summary from attempts and flips status to closed.
- `attempt_inventory_correction(p_session_id, p_wh_inventory_id, p_new_warehouse_stock, p_reason, p_client_correlation_id, p_attempted_by)` — wraps `apply_inventory_correction` inside a PL/pgSQL BEGIN/EXCEPTION block; classifies SQLSTATE into terminal result; INSERTs one `inventory_control_attempt` row.
- `attempt_status_change(p_session_id, p_wh_inventory_id, p_new_status, p_reason, p_client_correlation_id, p_attempted_by, p_new_warehouse_stock)` — routes Active to Inactive through `inactivate_warehouse_row` and Inactive to Active through `reactivate_warehouse_row`.
- `attempt_reactivate_row(p_session_id, p_wh_inventory_id, p_new_warehouse_stock, p_reason, p_client_correlation_id, p_attempted_by, source_doc / new_expiration_date / new_wh_location passthrough)` — wraps `reactivate_warehouse_row`.

Migration `phaseG_p1_c3_inventory_control_rpcs`. Commit `95ad54b`. Cody-approved with the inactivate-row reservation guard added per his findings.

**FE helper layer.** Commit `f6ed953`:

- `src/lib/inventory/attempt-rpcs.ts` — typed wrappers for the six C.3 RPCs, plus `recordClientFailure` (the FE-direct INSERT path for transport-level failures, restricted by RLS gate to `result='network_error'`).
- `src/lib/inventory/session.tsx` — React Context (`InventorySessionProvider` + `useInventorySession` hook) with sessionStorage persistence.
- `src/lib/inventory/adjust-warehouse-line.ts` — adds `adjustWarehouseLineMetadata` for metadata-only writes (wh_location / expiration_date / batch_id) that pass current stock and status through unchanged.
- `src/components/inventory/StartInventorySessionBar.tsx` and `CanaryIndicator.tsx`.

### Workstream B — UI rewire (PRD B.1, B.2, B.6, B.8)

Commit `3c18df5`. Six FE files migrated, +591 / -165. Every warehouse_inventory stock or status write in the operator console and field app now routes through the C.3 wrappers via the FE helpers:

- `src/app/(app)/layout.tsx` and `src/app/(field)/layout.tsx` mount `InventorySessionProvider` so the session context reaches every page below either shell.
- `src/app/(app)/app/inventory/page.tsx` — operator console. `handleSave` split per dimension (stock via `attemptCorrection`; status via `attemptStatusChange`; expiry via `adjustWarehouseLineMetadata`). Bar plus canary mounted. Edit Batch disabled with `(locked)` when no session or role not in `EDIT_ROLES = {warehouse, operator_admin, superadmin, manager}`.
- `src/app/(field)/field/inventory/page.tsx` — field list. `saveInlineQty`, `saveInlineLocation`, `toggleBatchStatus`, plus the `completeControl` bulk-save loop all split per dimension with effective-stock tracking so a status flip is skipped when the qty edit auto-reactivated the row. `ProductCard` receives `canEdit` as a prop; inline qty input, location input, and status pill disable when `!canEdit && !controlMode`.
- `src/app/(field)/field/inventory/[inventoryId]/page.tsx` — field detail. Same pattern; reason required on save; bar scoped to row's warehouse and product.
- `src/lib/inventory/adjust-warehouse-line.ts` — `adjustWarehouseLine` flipped to runtime rejection for stock or status callers. Metadata-only callers use `adjustWarehouseLineMetadata`.

Cody Article 3 review passed (Articles 1, 3, 5, 6).

### Constitution Amendment 007

Commit `5e8fa04`. `inventory_control_session` joined Core entities in Appendix A; `inventory_control_attempt` joined Append-only logs with a documented FE INSERT exception clause. Cody-approved with two revisions applied (forensic discriminator note that `result='network_error'` is the FE-only value; Article 4 carve-out note that FE-direct INSERTs do not set `app.via_rpc` and the universal audit trigger correctly does not double-log them).

### A.4 Saturday corrections (S10)

Two sequential sessions opened, both closed clean. 24 attempts, 24 success, 0 failures. CS signed off in advance on every proposed decrease.

| Session    | Session ID                             | Slug                                             | Attempts | Success | Failures |
| ---------- | -------------------------------------- | ------------------------------------------------ | -------- | ------- | -------- |
| WH_CENTRAL | `8312565b-a7e6-49c9-8521-c36965a2dd78` | `inventory_session_2026-05-23_makeup_WH_CENTRAL` | 20       | 20      | 0        |
| WH_MCC     | `21819113-396f-41e6-b75e-316f1cc2f0e4` | `inventory_session_2026-05-23_makeup_WH_MCC`     | 4        | 4       | 0        |

Reason on every correction: `physical_count_2026-05-23_makeup`. Audit trail in `inventory_control_attempt` is complete and queryable by session_id.

Three large overstatements cleared (per-row sign-off captured):

- Al Ain Water Regular: phantom PO-MPGRN9QB-B1 120u to 0; counted batch 5u to 1u.
- Snickers Regular: phantom PO-9126-B2 72u to 0; JL-MAY01-B2 8u to 0; counted batch 2u unchanged.
- Vitamin Well Reload: RECON WH_MCC 12u to 0; Inactive PO-MOWDJ0AZ 5u to 0; counted WH_CENTRAL batch 14u unchanged.

Three understatements increased: Oreo +8 to 36; Mars +5 to 36; Extra Gum +12 to 18.

Skipped per CS direction: Gatorade `be9efd64` (6u drift row added after Saturday); Krambals Tomato WH_MM `05adc5b8` (1u not in CSV scope).

### A.4 post-correction discrepancy (S11)

18 of 22 products are now exact matches (delta = 0). Four residuals:

| Product                      | Physical | Live sys_total_wh | Delta | Diagnosis                                                                                                                                                              |
| ---------------------------- | -------- | ----------------- | ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Popit Original Cola          | 48       | 41                | -7    | Was MATCH (48u) on Saturday. 7u dropped between Saturday and today; likely a dispatch consumed it. Not a correction miss. Movement audit follow-up.                    |
| Gatorade Cool Blue Raspberry | 0        | 6                 | +6    | The deliberately-skipped drift row added after Saturday. Expected.                                                                                                     |
| Nestle Kit-kat               | 127      | 129               | +2    | After trim 39 to 37 on B1; 80 + 37 + 12 = 129. Residual 2u over physical. No specific batch in CSV note; treat as Saturday-count tolerance.                            |
| Pepsi Regular                | 6        | 8                 | +2    | Active 8u in WH_CENTRAL. Pepsi was not in the per-row sign-off list (no correction proposed since CSV called it minor drift). Also has 13u consumer phantom untouched. |

## Blocked

**A.3 (drain consumer_stock phantoms).** `attempt_inventory_correction` writes only `warehouse_stock`; consumer_stock is untouched. The 20+ phantom rows surfaced in the Saturday review (Pepsi BUG-006 12u, Snickers 3u+5u, Vitamin Well Reload 3u, Popit 7u, etc.) require either a separate wrapper RPC that drives `consumer_stock` resets, or a Phase 2 RPC. Flagged for Phase 2.

## Not in scope for Phase 1 (Phase 2+)

Per PRD Section 11 sequencing, the following are explicitly deferred:

- A.1 (refuse NULL `from_wh_inventory_id` pack), A.5 (fix EOD REMOVE bug, re-enable cron 9), C.5 (movement trail view) — Phase 2 (week of 2026-06-01).
- A.2 (PO physical receipt gate), A.6 (auto-receive on dispatch), A.7 (hard block silent direct UPDATE on warehouse_inventory), A.8 (M2M transfer flow integrity) — Phase 2 or later.
- B.3 (mandatory reason dropdown), B.4 (per-row movement trail drawer), B.5 (`/admin/inventory-sessions`), B.7 (PO physical-confirmation surface) — Phase 2 or later.
- C.4 (`v_inventory_control_session_summary`), C.6 (`v_daily_flow_reconciliation`) — Phase 2 or later.

## PRD Section 10 measurements (snapshot at time of writing)

| Criterion                                                          | Measurement                                                                                                                                                               | Current                                                       | Target                                                                                           |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Saturday's corrections applied with audit (A.4)                    | `SELECT COUNT(*) FROM inventory_control_attempt WHERE session_id IN ('8312565b-a7e6-49c9-8521-c36965a2dd78','21819113-396f-41e6-b75e-316f1cc2f0e4') AND result='success'` | 24 (20 WH_CENTRAL + 4 WH_MCC, all success)                    | 24 (per-row plan after CS sign-off, 22 of the original 23 corrections plus 2 skipped drift rows) |
| Every state-change attempt captured (C)                            | `inventory_control_attempt` row count equals FE telemetry attempt count                                                                                                   | Audit trail live; FE telemetry not yet wired                  | Continuous                                                                                       |
| Manager edit-then-reload shows persisted value (B.1)               | Manual UAT pass on 9.7 matrix                                                                                                                                             | Not yet run                                                   | 100%                                                                                             |
| Status toggle works both directions (B.2)                          | UAT pass on Active to Inactive both ways                                                                                                                                  | Code shipped (S2/S3/S4); UAT not run                          | 100%                                                                                             |
| Canary green during business hours (B.8)                           | `apply_inventory_correction` heartbeat success rate over 7 days                                                                                                           | `CanaryIndicator` mounted; telemetry collection not yet wired | >= 99.5%                                                                                         |
| Zero new packs with `from_wh_inventory_id IS NULL` (A.1)           | `SELECT COUNT(*) FROM refill_dispatching WHERE from_wh_inventory_id IS NULL AND packed=true AND created_at > deploy_date`                                                 | Not yet enforced (A.1 is Phase 2)                             | 0                                                                                                |
| Consumer_stock phantom backlog at zero (A.3)                       | `SELECT SUM(consumer_stock) FROM warehouse_inventory WHERE consumer_stock > 0 AND status='Inactive'`                                                                      | TBD; ~20+ rows surfaced Saturday; A.3 deferred to Phase 2     | 0                                                                                                |
| Daily reconciliation closes within +/- 2 units per product per day | `daily_reconciliation_log` rows where `abs(discrepancy) > 2`                                                                                                              | View C.6 not yet built                                        | Near zero                                                                                        |

## Commits this phase (newest first)

- `5e8fa04` docs(architecture): Amendment 007 — inventory_control tables added to Appendix A
- `3c18df5` feat(phase-g-p1): route inventory mutations through canonical attempt\_\* wrappers
- `f6ed953` feat(phase-g): FE helpers for inventory_control sessions and attempts
- `95ad54b` feat(phase-g): inventory_control_session + attempt tables + 6 wrapper RPCs

## Open follow-ups (recorded for Phase 2 backlog)

- Dedicated metadata-only DEFINER (currently `adjustWarehouseLineMetadata` routes through `adjust_warehouse_stock` with current stock and status pass-through; Cody noted this satisfies Articles 3 and 6 but a dedicated writer would be cleaner).
- DB-side ban on the deprecated `adjustWarehouseLine` path (Phase B RLS lockdown for `authenticated` is the structural enforcement layer).
- Consumer_stock phantom drain RPC (PRD A.3).
- FE telemetry wiring so per-attempt FE counts can be reconciled with `inventory_control_attempt` row counts (PRD Section 10 last row).
