# PRD v2: Inventory Integrity Initiative (Phase G)

**Owner:** CS
**Version:** 2 (no open questions, decisions baked in)
**Started:** 2026-05-24
**Status:** Ready for Cody review then execution by Claude Code CLI
**Supabase project:** eizcexopcuoycuosittm

## 1. The two outcomes

**Outcome A: Product flow integrity.** Every unit moves cleanly through every stage (Procurement, Warehouse, Staging, Pod, Sale, Return to WH, M2M transfer to other machine). At every step, the count of units booked equals the count of units physically present, with daily reconciliation. No silent loss between stages.

**Outcome B: Flawless Inventory UI for the WH manager.** Edit any cell, see the change saved without errors, status toggle works both ways (Active to Inactive, Inactive to Active), session-based inventory control with full audit, no value reverts, no silent blocks.

Everything else in this PRD serves those two outcomes.

## 2. Context (one paragraph)

The Saturday 2026-05-23 inventory control session at WH_MCC produced zero stock-value writes despite the WH manager attempting many. Forensics found the FE Inventory UI calls only `confirm_warehouse_status_proposal` (status flip only, no quantity change), never the canonical `apply_inventory_correction`. On top of that, three structural backend leaks (NULL `from_wh_inventory_id` packs, `consumer_stock` phantoms, PO booked at `ordered_qty` before physical confirmation) explain the +220 unit overstatement and 24 unit understatement across the 23 sampled products. CS and Simran confirmed the three large PO receipts (Al Ain Water 120, Snickers 96, Vitamin Well Reload 36) did physically arrive, so the overstatement is real shrinkage: units that left WH without the books moving.

## 3. Goals (measurable)

**G1.** After Phase 1 deploy, WH manager can edit any cell on the Inventory page and the change persists. Status toggle works both directions. Zero silent reverts. Every attempt logged.

**G2.** After Phase 2 deploy, zero new packs with `from_wh_inventory_id IS NULL` for at least 14 consecutive days.

**G3.** After Phase 3 deploy, daily reconciliation report (Procurement vs WH vs Staging vs Pod vs Sales) closes within plus or minus 2 units per product per day, system-wide.

**G4.** After Phase 4 deploy, all direct UPDATE attempts on `warehouse_inventory` outside canonical RPCs are blocked by the trigger. Zero `monitoring_alerts` rows of class `bug001_silent_reactivation` per week.

**G5.** Within 30 days of Phase 1 deploy, the `consumer_stock` phantom backlog is reduced to zero through per-row CS-approved drains.

## 4. Non goals

- No schema migration of `warehouse_inventory` core columns. The fix is adding gates, not replacing the table.
- No change to the canonical RPC architecture. RPCs remain the only write path.
- No changes to `sales_lines`, Adyen reconciliation, refill engine logic, driver app payload format, or VOX or partner sourcing logic.
- No changes to the procurement order workflow beyond adding the `physical_received_qty` gate.

## 5. Baked decisions (replace previous open questions)

**D1.** For the 220 unit overstatement (Al Ain Water +124, Snickers +83, Vitamin Well Reload +13) and the 24 unit understatement (Oreo Cookie minus 8, Mars minus 4, Extra Gum minus 12): apply Saturday's physical counts now via `apply_inventory_correction` (in Workstream A.4) AND emit the forensic trail per row via `v_wh_inventory_movement_trail` (in Workstream C) so we understand the historical leak. Books snap to physical reality immediately. Trail informs future prevention.

**D2.** For the silent direct UPDATE hard block: audit-first. Step 1 list every caller (n8n nodes, edge functions, scheduled tasks, manual scripts) that writes directly to `warehouse_inventory`. Step 2 migrate each to the canonical RPC. Step 3 flip the trigger from `alert` to `RAISE EXCEPTION`. No flip until step 2 verified at zero direct callers for 7 days.

**D3.** For the PO physical receipt gate: applies retroactively. Every existing `warehouse_inventory` row that originated from a PO receipt and has `warehouse_stock > 0` gets backfilled to `physical_received_qty = warehouse_stock` (treats current state as confirmed) only if WH manager has signed off via a one-time backfill flow. Until signed off per row, status stays `Active` but the row carries a `needs_physical_confirmation = true` flag visible in the Inventory UI as a yellow chip.

**D4.** For Inventory Control Mode session locking: SOFT lock. While a session is open, the Inventory UI blocks other manual editors from saving (read-only banner). Backend automated flows (`pack_dispatch_line`, `receive_dispatch_line`, `return_dispatch_line`, M2M transfer RPCs, WEIMI sale ingestion) continue normally. On session close, the manager sees a delta summary of any backend movement during the session window and can reconcile.

## 6. Workstream A: Product flow integrity (the pipes)

**Owner:** Cody (constitutional review of every RPC change), Dara (any schema), assistant (execute).

### A.1 Refuse pack when `from_wh_inventory_id IS NULL`

Modify `pack_dispatch_line` to raise an exception if any pick is missing `from_wh_inventory_id`. FE pack page must select a WH source before pack. Migration is small (in-function check). Unit tests in Section 9.

### A.2 PO physical receipt gate

Add column `physical_received_qty numeric null` to `purchase_orders`. Add status value `PendingPhysicalReceipt` to `warehouse_inventory.status`. New RPC `confirm_physical_receipt(p_po_line_id, p_physical_qty, p_received_by, p_notes)` creates or updates the WH row and links back to the PO line. Backfill existing rows per D3.

### A.3 Drain `consumer_stock` phantoms

Build full backlog CSV (approximately 120 rows / 830 units per memory `bug_consumer_stock_drain_asymmetry`). CS reviews per row. New RPC `drain_consumer_stock_phantom(p_wh_inventory_id, p_reason, p_drained_by)` sets `consumer_stock = 0` with explicit audit. No row drained without per-row CS sign-off.

### A.4 Apply Saturday's 23 corrections

Inside a logged inventory control session (Workstream C), call `apply_inventory_correction` for each of the 23 products with the physical count from `inventory_control_2026-05-23_per_product_table.csv`. For multi-batch products (Al Ain Water, Pepsi Regular), correct only the batch CS counted. Reason field per row: `physical_count_2026-05-23_makeup`.

### A.5 EOD `eod_auto_release_unpicked` fix for REMOVE actions

Fix the cron function so REMOVE rows do not credit WH when auto-released. Units stay in machine if not picked up. Then re-enable cron job 9.

### A.6 Auto-receive on dispatch

Refill, Add New, Remove flows: when driver marks `picked_up = true`, the system auto-calls `receive_dispatch_line`. No manual Receive step. Consumer stock only for genuinely in-transit returns (the 24 to 48 hour window between driver hand-back at WH and WH staff scanning back in). Needs Dara plus Cody review.

### A.7 Hard block silent direct UPDATE on `warehouse_inventory`

Per D2, audit then flip. Trigger raises exception if `app.via_rpc != 'true'` and the change touches `warehouse_stock` or `consumer_stock`. INSERTs and stock increases via canonical RPCs remain allowed.

### A.8 M2M transfer flow integrity

Audit `receive_dispatch_line` M2M branch and the matching `return_dispatch_line` M2M branch. Confirm pod_inventory at source decrements and pod_inventory at destination increments by exact same quantity. Add unit test in Section 9 for the round trip.

## 7. Workstream B: Inventory UI rebuild (the experience)

**Owner:** Stax (implementation), Cody (constitutional review).

### B.1 Rewire edit-count cell

Replace whatever the cell calls today with `attempt_inventory_correction(session_id, wh_inventory_id, new_value, reason, correlation_id)` (defined in Workstream C). Behavior:

- No optimistic update. Cell shows spinner while RPC in flight.
- On `result='success'`: cell updates to new value, green flash, no reload needed.
- On any non-success: cell reverts to original, red toast with the actual error message, attempt visible in session log.

### B.2 Rewire status toggle (Active ↔ Inactive both directions)

Replace whatever the toggle calls today with `attempt_status_change(session_id, wh_inventory_id, new_status, reason, correlation_id)`. Same UX rules as B.1.

For `Inactive → Active` with positive stock, the wrapper routes to `attempt_reactivate_row` so the canonical reactivation path runs. For `Active → Inactive` with zero stock, the wrapper routes to `attempt_inactivate_row` (new, calls a future `inactivate_warehouse_row` RPC).

### B.3 Mandatory reason dropdown per change

Options: `physical_count`, `transit_adjustment`, `damaged`, `expired`, `swap_in`, `swap_out`, `manual_correction`, `other`. Free text input appears when `other` selected. Persists in `inventory_control_attempt.reason` and on the underlying RPC call.

### B.4 Per-row movement trail drawer

Expand any row in the Inventory page to render `v_wh_inventory_movement_trail` (defined in Workstream C) for that `wh_inventory_id`. Shows the full lifecycle: PO line, snapshot date, every audit event, every pack, every receive, every return. This is the reverse-engineering tool.

### B.5 Inventory session viewer at `/admin/inventory-sessions`

Table of sessions ordered by start time. Click into a session to see filterable list of attempts (success and failure), grouped by product, with error messages inline. Filters: result, product, user, error class.

### B.6 Inventory Control Mode (with soft lock per D4)

Top of inventory page has a "Start Inventory Control" button. Once started:

- All cells in this page are attributed to the session.
- A blue banner shows "Inventory control session in progress by X (started Y minutes ago)".
- Other users opening the same page see read-only mode with a yellow banner "Inventory control session active by X; your edits are temporarily disabled".
- Backend flows (pack, receive, return, M2M, WEIMI sale) continue normally.
- Session-close action surfaces a delta panel: "Backend movement during your session: N units in, M units out, K rows changed status." Manager confirms reconciliation before close.

### B.7 PO physical-confirmation surface

Rows with `needs_physical_confirmation = true` (from D3) show a yellow chip "Pending physical receipt". Click to open a small confirm dialog: "Physically counted: **_ units. Notes: _**". Confirms via `confirm_physical_receipt` and clears the chip.

### B.8 Always-visible canary

Top-right status indicator that shows the result of a heartbeat call to `apply_inventory_correction(p_wh_inventory_id := '<canary_row>', p_new_warehouse_stock := <unchanged>, p_reason := 'heartbeat', p_corrected_by := auth.uid())` every 60 seconds. Green if the canonical RPC path is working, red with error if not. Catches RLS, network, or RPC drift in real time.

## 8. Workstream C: Deep logging and reverse-engineering

**Owner:** Dara (schema), Cody (constitutional review), assistant (execute).

### C.1 New table `inventory_control_session`

Columns: `session_id uuid pk`, `started_at timestamptz`, `started_by uuid`, `scope_warehouse_id uuid`, `scope_product_ids uuid[] null`, `status enum('open','closed','aborted')`, `closed_at timestamptz null`, `summary jsonb null`.

### C.2 New table `inventory_control_attempt`

Captures every attempted change (success or failure). Columns: `attempt_id uuid pk`, `session_id uuid fk`, `attempted_at timestamptz`, `attempted_by uuid`, `wh_inventory_id uuid null`, `target_path enum('by_id','by_product_warehouse_expiry')`, `boonz_product_id uuid null`, `warehouse_id uuid null`, `expiration_date date null`, `field_changed enum('warehouse_stock','consumer_stock','status','expiration_date','wh_location','batch_id','create')`, `old_value jsonb`, `new_value jsonb`, `rpc_called text`, `rpc_response jsonb`, `result enum('success','blocked_rls','blocked_trigger','rpc_error','validation_error','network_error','other')`, `error_message text null`, `client_correlation_id uuid`, `reason text`.

RLS: read by manager/superadmin/operator_admin; write open (any session captures its own attempts).

### C.3 New RPCs

- `start_inventory_session(p_scope_warehouse_id, p_scope_product_ids null, p_started_by null)` returns `session_id`. Auto-closes any open session by the same user first.
- `close_inventory_session(p_session_id, p_summary null)` sets `status='closed'`, computes summary from attempts (counts by result, by product, by error class).
- `attempt_inventory_correction(p_session_id, p_wh_inventory_id, p_new_warehouse_stock, p_reason, p_client_correlation_id)`: writes to `inventory_control_attempt` first with `result='pending'`, calls `apply_inventory_correction` in a SAVEPOINT, updates attempt row with outcome. Never propagates the exception; FE always gets a structured response.
- `attempt_status_change(p_session_id, p_wh_inventory_id, p_new_status, p_reason, p_client_correlation_id)`: same pattern, routes to `reactivate_warehouse_row` or `inactivate_warehouse_row` based on current and new status.
- `attempt_reactivate_row(p_session_id, p_wh_inventory_id, p_new_warehouse_stock, p_reason, p_client_correlation_id)`: same pattern, calls `reactivate_warehouse_row`.

### C.4 New view `v_inventory_control_session_summary`

Per session: counts by result, by product, by error class. Feeds B.5.

### C.5 New view `v_wh_inventory_movement_trail`

Per `wh_inventory_id`, union of:

- `inventory_audit_log` entries (quantity deltas with reason)
- `write_audit_log` entries for this row (any column change)
- `refill_dispatching` rows with `from_wh_inventory_id` matching (pack and receive)
- `purchase_orders` lines with the same `batch_id` (provenance)
- `inventory_control_attempt` rows touching this `wh_inventory_id`

Ordered by event time, with synthetic `event_class` column.

### C.6 Daily reconciliation report `v_daily_flow_reconciliation`

Per day, per product:

- `procurement_in`: SUM(received_qty) from `purchase_orders` plus SUM(qty) from `po_additions`
- `wh_in_from_returns`: SUM(quantity) from `refill_dispatching` where `action='Remove'` and `returned=true` and `dispatched=true`
- `wh_out_to_packs`: SUM(quantity) from `refill_dispatching` where `action IN ('Refill','Add New')` and `packed=true`
- `wh_end_of_day`: SUM(warehouse_stock + consumer_stock) at EOD (reconstruct via audit log cumulative)
- `pod_in`: SUM via `pod_inventory` snapshots
- `sales_out`: SUM(qty) from `sales_lines`

Identity check per day per product: `wh_start + procurement_in + wh_in_from_returns - wh_out_to_packs = wh_end_of_day`. Discrepancies flagged in red.

### C.7 Daily reconciliation cron `cron_daily_inventory_reconciliation`

6:00 AM Dubai daily. Generates `v_daily_flow_reconciliation` for the prior day, writes to `daily_reconciliation_log` table. Flags products with absolute discrepancy greater than 2 units. Surfaces to Boonz Master morning briefing.

## 9. Edge case test matrix (must pass before deploy)

Every Phase deploy is gated by these test cases. Each must produce the expected outcome (success or refusal) and a clean audit trail.

### 9.1 Procurement → WH

| Case                 | Setup                                                | Expected                                                                              |
| -------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Happy path           | PO line ordered 24, physical 24                      | After `confirm_physical_receipt(24)`: WH row at 24, status Active, audit entry        |
| Partial pallet       | PO line ordered 24, physical 22                      | After confirm: WH row at 22, audit entry with note "2 short"                          |
| Damaged units        | PO line ordered 24, physical 24 minus 3 damaged      | Confirm path: 21 to Active, 3 to Inactive with `disposal_reason='damaged_in_transit'` |
| Expiry mismatch      | PO expiry 2027-04-10, physical pallet exp 2027-04-08 | Two separate WH rows (one per expiry), each with own confirmation                     |
| Duplicate PO receipt | Same PO received twice in 1 hour                     | Second receipt fails with "PO already received" error, no duplicate row               |
| Backfill flag        | Existing WH row from old PO                          | Yellow chip in UI until WH manager confirms via dialog                                |

### 9.2 WH → Staging

| Case                         | Setup                                             | Expected                                                                     |
| ---------------------------- | ------------------------------------------------- | ---------------------------------------------------------------------------- |
| Standard transfer            | 10 units WH location D08 to STAGING D08           | `transfer_warehouse_stock` decrements source, increments dest, audit on both |
| Transfer of expired batch    | Source batch exp 2025-12-01 (past)                | Refused with "cannot transfer expired stock", audit of attempt               |
| Wrong wh_location            | Source has 10 units in D08, transfer requests D09 | Refused, error surfaces in UI                                                |
| Status drift during transfer | Source flips to Inactive mid-transfer             | Transaction rolls back, no partial state                                     |

### 9.3 Staging → Pod (pack)

| Case             | Setup                                               | Expected                                                                     |
| ---------------- | --------------------------------------------------- | ---------------------------------------------------------------------------- |
| Happy path       | Pack 5 units with `from_wh_inventory_id` pinned     | WH row decremented by 5, audit entry, dispatch flagged `packed=true`         |
| NULL from_wh     | Pack 5 units with `from_wh_inventory_id IS NULL`    | A.1 refuses, returns error to FE pack page                                   |
| Depleted batch   | Pack 5 units but pinned WH row has 3                | Refused with "insufficient stock", no partial pack                           |
| Multi-batch pack | 12 units, 6 from batch A, 6 from batch B            | Two child dispatch rows created, each with own pin, both decrement correctly |
| FEFO violation   | Pin to batch exp 2027 when batch exp 2026 has stock | Allowed (operator override) but logged with `fefo_override=true`             |

### 9.4 Pod → Exit (sale)

| Case                         | Setup                                         | Expected                                                                               |
| ---------------------------- | --------------------------------------------- | -------------------------------------------------------------------------------------- |
| Standard WEIMI sale          | Sale of 1 unit at shelf X                     | `pod_inventory.current_stock` decrements by 1 via canonical decrement RPC, audit entry |
| Fan-out (v_live_shelf_stock) | Shelf X has duplicates from BUG fix           | View shows DISTINCT per (device, slot); decrement applies once                         |
| Sale of zero-stock shelf     | Sale at shelf where `current_stock=0` already | Logged as anomaly to `sales_anomaly_log`; pod_inventory not pushed negative            |
| Sale of expired batch        | Shelf still has batch past expiry             | Sale still records; flagged in `daily_expired_sales_log` for review                    |

### 9.5 Pod → Return to WH

| Case                     | Setup                                                  | Expected                                                                         |
| ------------------------ | ------------------------------------------------------ | -------------------------------------------------------------------------------- |
| Standard return          | Driver returns 3 units exp 2026-12-23                  | `return_dispatch_line` increments matching batch WH row by 3, audit entry        |
| Multi-batch return       | 13 units, 7 from one expiry, 6 from another            | `p_batch_breakdown` jsonb passed, each batch credited separately per BUG-007 fix |
| NULL expiry return       | Return with no expiry data                             | Refused with "expiry required" error; driver must provide                        |
| Return to Inactive batch | Returning to a batch that flipped Inactive             | Auto-reactivates via canonical reactivation, audit captures the flip             |
| Auto-release REMOVE      | EOD cron fires on REMOVE action with `picked_up=false` | A.5 fixed: NO WH credit, units stay in machine, audit reflects no movement       |

### 9.6 Pod → Other machine (M2M)

| Case                       | Setup                                               | Expected                                                                                                                   |
| -------------------------- | --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Standard M2M               | 5 units from machine A shelf X to machine B shelf Y | Source pod_inventory decrements by 5; dest pod_inventory increments by 5; no WH movement; audit on both pod_inventory rows |
| Partial M2M                | Planned 5, driver delivered 3                       | Source -3, dest +3, 2 units "lost in transit" logged to anomaly                                                            |
| M2M to deactivated machine | Dest machine status=Inactive                        | Refused with "destination machine inactive"                                                                                |

### 9.7 Inventory UI edit flows

| Case                                | Setup                                            | Expected                                                                           |
| ----------------------------------- | ------------------------------------------------ | ---------------------------------------------------------------------------------- |
| Edit cell on Active row             | Change warehouse_stock from 27 to 14             | RPC succeeds, cell flashes green, reload shows 14, audit captured                  |
| Edit cell on Inactive row           | Row inactive, change warehouse_stock from 0 to 5 | RPC routes via `reactivate_warehouse_row`, row flips to Active, cell shows 5       |
| Status toggle Active → Inactive     | Active row with 0 stock                          | Toggle confirms, row flips Inactive                                                |
| Status toggle Inactive → Active     | Inactive row with 0 stock                        | Refused with "no stock to reactivate" error                                        |
| Concurrent edit                     | Two users edit same row                          | Second save fails with "row changed since you loaded", banner asks user to refresh |
| Stale ETag / version                | UI has cached value, DB has newer                | Save refused with version mismatch error, refresh prompt                           |
| Validation error (negative qty)     | Try to save -5                                   | Refused with "stock cannot be negative"                                            |
| Session lock                        | User B opens page while User A has session       | User B sees read-only banner, edit cells disabled                                  |
| Session close with backend movement | Backend pack happened mid-session                | Close dialog shows delta panel; manager acknowledges before close                  |
| Canary failure                      | apply_inventory_correction RPC errors            | Top-right indicator turns red with the actual error                                |

## 10. Success criteria

| Outcome         | Criterion                                                              | Measurement                                                                                                                              |
| --------------- | ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| A: Product flow | Daily reconciliation report closes within ±2 units per product per day | `daily_reconciliation_log` row count where `abs(discrepancy) > 2` should be near zero                                                    |
| A: Product flow | Zero new packs with `from_wh_inventory_id IS NULL`                     | `SELECT COUNT(*) FROM refill_dispatching WHERE from_wh_inventory_id IS NULL AND packed=true AND created_at > deploy_date`                |
| A: Product flow | Consumer_stock phantom backlog at zero                                 | `SELECT SUM(consumer_stock) FROM warehouse_inventory WHERE consumer_stock > 0 AND status='Inactive'`                                     |
| A: Product flow | Saturday's 23 corrections applied with audit                           | `SELECT COUNT(*) FROM inventory_control_attempt WHERE session_id = 'inventory_session_2026-05-23_makeup' AND result='success'` equals 23 |
| B: UI           | Manager edit-then-reload shows persisted value 100% of the time        | Manual UAT pass on every row in test matrix 9.7                                                                                          |
| B: UI           | Status toggle works both directions                                    | UAT pass on Active↔Inactive flows in 9.7                                                                                                 |
| B: UI           | Every attempt visible in session log                                   | `inventory_control_attempt` row count equals user-side action count for any session                                                      |
| B: UI           | Canary green during business hours                                     | `apply_inventory_correction` heartbeat success rate ≥ 99.5% over 7 days                                                                  |
| C: Logging      | Every state-change attempt captured                                    | `inventory_control_attempt` row count equals attempt count from FE telemetry                                                             |

## 11. Sequencing

**Phase 1: Unblock the WH manager (week of 2026-05-25)**

- C.1, C.2 (tables): Dara design, Cody review, apply migration.
- C.3 (RPCs): the three `attempt_*` wrappers.
- B.1, B.2 (FE rewire edit cell and status toggle): Stax implements.
- A.4 (apply Saturday's 23 corrections in a logged session).
- B.8 (canary indicator).
- Tests from 9.7 must pass.

**Phase 2: Close the biggest leak (week of 2026-06-01)**

- A.1 (refuse NULL from_wh pack).
- A.5 (fix EOD REMOVE bug, re-enable cron 9).
- C.5 (movement trail view).
- B.4 (movement trail drawer in UI).
- Tests from 9.3 and 9.5 must pass.

**Phase 3: Make books match physical reality (week of 2026-06-08)**

- A.2 (PO physical receipt gate) and backfill flag per D3.
- A.3 (consumer_stock phantom drain with per-row CS sign-off).
- B.7 (PO confirm chip in UI).
- C.6, C.7 (daily reconciliation view and cron).
- Tests from 9.1 must pass.

**Phase 4: Lock the door (week of 2026-06-15)**

- A.6 (auto-receive on dispatch, after Dara plus Cody review).
- A.7 (audit callers per D2, migrate, then flip trigger to hard-block).
- A.8 (M2M flow audit).
- B.3, B.5, B.6 (UI reason field, session viewer, control mode with soft lock).
- Tests from 9.4 and 9.6 must pass.

## 12. Safety constitution (non-negotiable)

- All `warehouse_inventory` writes via canonical RPC only. Direct UPDATE is forbidden outside RPCs.
- No DELETE on any table without explicit per-row CS approval.
- No silent stock reductions. Show the row diff before commit. CS sign-off required per row for any decrease.
- Plan Write Protocol for every correction: pre-flight validation, write via RPC, verify by reading back, report.
- No em dashes in any code, commit message, file header, RPC docstring, or chat reply. Use commas, colons, periods, or parentheses.
- Every migration reviewed by Cody (CONSTITUTIONAL verdict required).
- Every backend RPC change tested against Section 9 cases before deploy.
- Skill `boonz-master-3` loaded before any operational action.

## 13. Out of scope

- `sales_lines`, Adyen reconciliation, settlement flow.
- Refill engine logic, pod swap engine, machine picker.
- Driver app payload format or auth flow.
- VOX or partner sourcing logic.
- Any changes to `machines`, `slots`, `shelf_configurations`, `planogram`.
- Reporting beyond `daily_reconciliation_log` and session viewer.

## 14. Reference artifacts

- Saturday discrepancy report: `inventory_control_2026-05-23_discrepancy_report.md`
- Per product CSV: `inventory_control_2026-05-23_per_product_table.csv`
- Yesterday 68 stuck row decision sheet: `null_wh_source_decision_sheet_2026-05-18.csv`
- Pepsi 14 day deep dive: `pepsi_regular_inventory_snapshot_2026-05-04_to_2026-05-18.csv`
