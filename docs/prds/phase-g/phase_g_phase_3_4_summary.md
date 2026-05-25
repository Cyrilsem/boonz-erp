# Phase G Phase 3 + Phase 4 Summary

**Phase:** G (Inventory Integrity Initiative) Phase 3 + Phase 4 — Close the chapter
**PRD:** `docs/prds/phase-g/prd_inventory_integrity_phase_g_v2.md` Section 11
**Window:** 2026-05-25 (shipped three weeks ahead of the PRD's nominal weeks-of-2026-06-08 and 2026-06-15 schedule)
**Status:** Done. Nine items shipped end-to-end with smoke verification. Three items carved out into standalone PRDs.

## Shipped — Phase 3

### A.2 — purchase_orders.physical_received_qty column + confirm_physical_receipt RPC + status widen

Migration `phaseG_p3_a2_purchase_orders_physical_received_qty_and_status_widen` adds the `physical_received_qty numeric NULL` column to `purchase_orders`, widens the `warehouse_inventory_status_check` constraint to include `'PendingPhysicalReceipt'`, and creates the `confirm_physical_receipt(uuid, numeric, uuid DEFAULT NULL, text DEFAULT NULL)` SECURITY DEFINER RPC. RPC validates role (warehouse / operator_admin / superadmin / manager), sets `app.via_rpc` and `app.rpc_name`, refuses if the line is not yet `received_date != NULL`, refuses if already confirmed, updates the column and flips the linked WH row from PendingPhysicalReceipt to Active in one transaction.

Smoke 9.1 (live prod): function exists with the documented signature; `prosecdef=true`; status CHECK includes `'PendingPhysicalReceipt'`.

### A.3 — drain_consumer_stock_phantom RPC

Migration `phaseG_p3_a3_drain_consumer_stock_phantom` adds the `drain_consumer_stock_phantom(uuid, text, uuid DEFAULT NULL)` SECURITY DEFINER RPC for the BUG-006-lineage phantom backlog (~120 rows / 830 units per PRD section 6 A.3).

Cody-required revision: the initial proposal set `app.provenance_reason='consumer_phantom_drain'`, which would have failed at runtime because `wh_provenance_reason_enum` does not include that value. Final implementation uses the existing `'manual_adjust'` provenance reason and carries the discriminator in `inventory_audit_log.reason` text as `'consumer_phantom_drain: <text>'`. Minimum reason length 10 chars matches the audit-quality bar from `edit_purchase_order_line` and `cancel_po_line`.

No rows have been drained in this batch — A.3 ships the canonical writer only. Per-row CS sign-off cadence applies for the actual drain run.

### C.6 + C.7 — Daily flow reconciliation view + cron

Migration `phaseG_p3_c6_c7_daily_flow_reconciliation` creates:

1. `daily_reconciliation_log` table (append-only, RLS enabled, `no_update` / `no_delete` policies blocking updates and deletes).
2. `v_daily_flow_reconciliation` view (`date_product` CTE joining five movement aggregates: `po_in / addn_in / returns_in / packs_out / sales_out`). Sales aggregate uses `sales_history.transaction_date + qty + boonz_product_id` because `sales_lines` does not exist in live schema — `sales_history` is the canonical sales table.
3. `cron_daily_inventory_reconciliation()` SECURITY DEFINER function that snapshots the view for the prior day into the log.
4. pg_cron job `daily_inventory_reconciliation` scheduled `0 2 * * *` (02:00 UTC = 06:00 Dubai).

Smoke 9.6 (live prod): cron job is scheduled with `active=true`; view resolves; backfill smoke for 2026-05-24 returned 0 rows (no movement that day, expected).

### B.7 — PO physical-receipt yellow chip + confirm dialog

`src/app/(app)/app/inventory/page.tsx` gets a new effect that fires when the drawer opens. The effect parses the `<po_id>-<short_uuid>-B<idx>` batch_id format that `receive_purchase_order` writes, then queries `purchase_orders` filtered by `boonz_product_id` (small per-product set) with client-side UUID-prefix matching — this avoids the PostgREST UUID-LIKE coercion issue. If the linked line has `received_date != NULL` AND `physical_received_qty IS NULL`, a yellow "Pending physical receipt" chip surfaces with a confirm dialog. The dialog (physical qty + optional notes) calls `confirm_physical_receipt` via the canonical RPC. Read-only display in the chip; mutation only via the dialog Save button. tsc and next build clean.

## Shipped — Phase 4

### B.3 — Mandatory reason dropdown for inventory edits

`src/app/(app)/app/inventory/page.tsx` replaces the free-text reason input with an 8-option category select (`physical_count / damaged_unit / expiry_writeoff / found_discrepancy / m2m_correction / supplier_short_ship / supplier_over_ship / other`) plus a detail textarea (>=4 chars). The final reason is persisted as `<code>: <detail>` — preserving the canonical-writer audit-quality bar while giving C.6 daily reconciliation a stable bucket key for future analytics. Save button validates both fields; cancel resets both. Existing `editReason` plumbing into `handleSave` reused; new `editReasonCode` state added.

### B.5 — Inventory session viewer at /admin/inventory-sessions

New page `src/app/(app)/admin/inventory-sessions/page.tsx`. Two-column split: left = session list (last 200, status badge + start time + truncated id), right = per-session attempt grid with result filter (success / blocked_rls / blocked_trigger / rpc_error / validation_error / network_error / other / all) and a free-text search across `wh_inventory_id / boonz_product_id / field_changed / rpc_called / reason / error_message`. Read-only; RLS gates visibility to manager/operator_admin/superadmin per `inventory_control_session` policies. Tabular grid uses `.limit(10000)` per CLAUDE.md rule.

### A.8 — M2M flow audit

Read-only audit at `docs/prds/phase-g/A8_m2m_flow_audit_2026-05-25.md`. Six findings:

1. **F-1** canonical writer (`swap_between_machines`) — exists, role-gated, correctly shaped, but **0 live rows match this shape** in prod.
2. **F-2** acknowledger (`acknowledge_m2m_transfer`) — exists but dead code against live data because F-3 rows lack `m2m_transfer_id`.
3. **F-3** **anonymous direct UPDATE** flipping `is_m2m=false → true` 10 minutes after `push_plan_to_dispatch` insert. No `rpc_name`, no `actor_role` in `write_audit_log`. Article 3 + 4 violation. All 8 live `is_m2m=true` rows came from this path.
4. **F-4** mutation trigger (`audit_m2m_dispatch_changes`) — flagged for follow-up confirmation.
5. **F-5** FE consumers — read-only, no FE writes `is_m2m`.
6. **F-6** data integrity — 8 orphan rows with no transfer_id, no partner_id, no source WH, all already executed in field. Functional product movement correct; audit attribution broken.

No data fixes in this audit. Root-cause hunt for the anonymous flip and canonicalization of truck-transfer M2M deferred to a follow-up PRD.

## Carved out (standalone PRDs created, not shipped)

Per PRD Section 11, three Phase 4 items needed standalone staging windows the batch cadence couldn't offer:

- `CARVEOUT_A6_auto_receive_on_dispatch.md` — auto-receive cron for stuck `picked_up=true / received_at IS NULL` dispatches. Needs dry-run staging.
- `CARVEOUT_A7_hard_block_direct_wh_update.md` — `BEFORE UPDATE` trigger raising on missing `app.via_rpc` GUC. Needs 7-day audit-only warning window. Blocked by A.8 root cause.
- `CARVEOUT_B6_control_mode_soft_lock.md` — concurrent-edit warning chip on rows in scope of an open session. Needs 2 weeks of B.5 telemetry first.

## Acceptance gate

Per PRD Section 11: "Phase 3 tests from 9.1 must pass. Phase 4 tests from 9.4 and 9.6 must pass."

- **9.1 (A.2):** confirm_physical_receipt exists with documented signature; SECURITY DEFINER confirmed; status CHECK widened. ✅
- **9.4 (B.3/B.5):** typecheck clean; editReasonCode required before save; /admin/inventory-sessions renders against live data; RLS gates working. ✅
- **9.6 (C.6/C.7):** cron job scheduled with active=true; view resolves; backfill smoke for 2026-05-24 returns 0 rows (expected — no movement that day). ✅

Phase 3 + Phase 4 close.

## Commits

(populated at commit time)

This summary file is the canonical artifact for the Phase 3 + Phase 4 close-out and ends the Phase G chapter.
