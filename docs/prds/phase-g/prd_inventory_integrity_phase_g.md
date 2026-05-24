# PRD: Inventory Integrity Initiative (Phase G)

**Owner:** CS
**Started:** 2026-05-24
**Status:** Draft, awaiting Cody + Dara review
**Supabase project:** eizcexopcuoycuosittm
**Related artifacts:**

- /Users/cyrilsemaan/Documents/Boonz Script and Data/BOONZ BRAIN/inventory_control_2026-05-23_discrepancy_report.md
- /Users/cyrilsemaan/Documents/Boonz Script and Data/BOONZ BRAIN/inventory_control_2026-05-23_per_product_table.csv
- /Users/cyrilsemaan/Documents/Boonz Script and Data/BOONZ BRAIN/null_wh_source_decision_sheet_2026-05-18.csv
- /Users/cyrilsemaan/Documents/Boonz Script and Data/BOONZ BRAIN/pepsi_regular_inventory_snapshot_2026-05-04_to_2026-05-18.csv

## 1. Context

The Saturday 2026-05-23 inventory control session at WH_MCC exposed three failure modes that, together, are why Boonz inventory drifts away from physical reality:

1. The Inventory UI does not call the canonical `apply_inventory_correction` RPC when WH manager edits a cell. Every Saturday save attempt produced only a `confirm_warehouse_status_proposal` event (`old_wh = new_wh`). Zero rows appeared in `inventory_audit_log` for the entire session. Quantity edits and status toggles both reverted on re-read.

2. Three structural backend leaks let units escape system accounting between PO receipt and physical truth:
   - Pack with `from_wh_inventory_id IS NULL` does not decrement `warehouse_stock` (the same family that produced the 68 stuck rows cleaned on 2026-05-18).
   - `consumer_stock` phantoms accumulate when pack and receive do not reconcile against the pinned WH row (BUG-006 family, approximately 830 units system wide).
   - PO receipt creates a `warehouse_inventory` row at full `ordered_qty` before physical confirmation. If the pallet arrives short, damaged, or partly diverted, the row stays at the optimistic number forever.

3. There is no inventory control session concept. Each edit is a one-off RPC call with no session id, no batch context, and no rollback story. When something goes wrong, there is no log of the attempt, only of successful writes.

The Saturday sample of 23 products showed system overstating physical by approximately 220 units (Al Ain Water +124, Snickers +83, Vitamin Well Reload +13, smaller drift across the rest) and understating by approximately 24 units (Oreo Cookie, Mars, Extra Gum). Only Popit Original Cola matched perfectly.

CS confirmation 2026-05-24: the three large PO batches did physically land at WH (Al Ain Water 120 from Amazon, Snickers 96 from Jaleel split 24/72 across two expiries, Vitamin Well Reload 36 from Champions). The 220 unit overstatement is therefore "units physically left WH but books did not move," not "PO booked but never received." This sharpens the cause toward the NULL from_wh pack family.

## 2. Goals

**G1.** Apply the 23 product corrections from Saturday's session, with full audit trail, via canonical RPC.

**G2.** Stand up an Inventory Control Mode that captures every attempted change (success or failure) so future discrepancies can be reverse engineered, not guessed at.

**G3.** Close the three structural leaks so units stop disappearing between PO receipt, pack, dispatch, and physical truth.

**G4.** Rebuild the Inventory UI page so WH manager can save quantity changes and status toggles without blockers, with errors surfaced clearly.

## 3. Non goals

- No schema migration of `warehouse_inventory` core columns. The fix is adding gates, not replacing the table.
- No change to the canonical RPC architecture. RPCs remain the only path; the fix is wiring the FE to them.
- No change to the procurement order workflow other than adding a `physical_received_qty` confirmation step.
- No automated stock writes outside CS approved RPCs. The "no destructive changes without per row approval" rule stands.

## 4. Workstream 1: Inventory Control Mode with deep logging

**Owner:** Dara (schema), Cody (constitutional review), Stax (FE wiring)

### 4.1 New table: `inventory_control_session`

Columns: `session_id uuid pk`, `started_at timestamptz`, `started_by uuid (user_profiles.id)`, `scope_warehouse_id uuid`, `scope_product_ids uuid[] null` (null means all), `status enum('open','closed','aborted')`, `closed_at timestamptz null`, `summary jsonb null`.

### 4.2 New table: `inventory_control_attempt`

Captures every attempted change in a session, not just successful ones.

Columns:

- `attempt_id uuid pk`
- `session_id uuid` (FK)
- `attempted_at timestamptz`
- `attempted_by uuid`
- `wh_inventory_id uuid null` (null for create flows that resolve by product+wh+expiry)
- `target_path enum('by_id','by_product_warehouse_expiry')`
- `boonz_product_id uuid null`
- `warehouse_id uuid null`
- `expiration_date date null`
- `field_changed enum('warehouse_stock','consumer_stock','status','expiration_date','wh_location','batch_id','create')`
- `old_value jsonb`
- `new_value jsonb`
- `rpc_called text` (`apply_inventory_correction`, `reactivate_warehouse_row`, `confirm_warehouse_status_proposal`, etc.)
- `rpc_response jsonb` (full payload, including error)
- `result enum('success','blocked_rls','blocked_trigger','rpc_error','validation_error','network_error','other')`
- `error_message text null`
- `client_correlation_id uuid` (FE generates one per save click; multiple attempts can share it)

RLS: read by manager/superadmin/operator_admin; write by anyone (the session captures their own attempts).

### 4.3 New view: `v_inventory_control_session_summary`

Per session, count attempts by result, by product, by error class. Used by 3.4 (session viewer).

### 4.4 New view: `v_wh_inventory_movement_trail`

Per `wh_inventory_id`, union of:

- `inventory_audit_log` entries (quantity changes)
- `write_audit_log` entries filtered to this row (any column change)
- `refill_dispatching` rows with `from_wh_inventory_id` matching (pack and receive events)
- `purchase_orders` lines with the same `batch_id` (provenance)

Ordered by event time. This is the "why does this row show X" tool.

### 4.5 New RPC: `start_inventory_session(p_scope_warehouse_id, p_scope_product_ids null, p_started_by null)`

Returns `session_id`. Closes any open session by the same user first.

### 4.6 New RPC: `close_inventory_session(p_session_id, p_summary null)`

Sets `status='closed'`, computes summary from attempts.

### 4.7 Wrapper RPC: `attempt_inventory_correction(p_session_id, p_wh_inventory_id, p_new_warehouse_stock, p_reason, p_client_correlation_id)`

- Writes to `inventory_control_attempt` first with `result='pending'`.
- Calls `apply_inventory_correction(...)` inside a SAVEPOINT.
- On success: updates the attempt row to `result='success'` with the RPC response.
- On exception: rolls back the SAVEPOINT, updates the attempt row with `result='rpc_error'` or `'validation_error'`, captures `SQLERRM` and `SQLSTATE`. Does not propagate the exception so the FE always gets a structured response.

Equivalent wrappers for `attempt_status_change(...)` and `attempt_reactivate_row(...)`.

### 4.8 Apply Saturday's 23 corrections

After 4.5 to 4.7 deploy, open a session named `inventory_session_2026-05-23_makeup`, attribute to `warehouse@boonz.test`, and apply the corrections from `inventory_control_2026-05-23_per_product_table.csv` row by row via `attempt_inventory_correction`. For multi batch products (Al Ain Water, Pepsi Regular), only correct the specific batch CS counted; leave other batches for the next physical count.

Treat the +124 / +83 / +13 large overstatements separately: do not zero them via `apply_inventory_correction` yet. They are the symptom of the NULL from_wh leak; reverse engineer via `v_wh_inventory_movement_trail` first, then propose the right correction per row to CS.

## 5. Workstream 2: Pipe integrity (structural backend fixes)

**Owner:** Cody (constitutional review), Dara (any new columns), assistant (apply)

### 5.1 Refuse pack with NULL `from_wh_inventory_id`

Modify `pack_dispatch_line` to raise an exception if any pick is missing `from_wh_inventory_id`. Add a pre flight check in the FE pack page that surfaces the missing source field before pack. No more silent NULL pinned packs.

Migration: small. Add the check inside `pack_dispatch_line`. Add unit test.

### 5.2 Audit and drain consumer_stock phantoms

Build the full backlog CSV (approximately 830 units across approximately 120 rows per memory `bug_consumer_stock_drain_asymmetry`). CS reviews per row. For each approved row, set `consumer_stock=0` via a new `drain_consumer_stock_phantom(p_wh_inventory_id, p_reason)` RPC that writes to both `inventory_audit_log` and `write_audit_log` with explicit reason.

Migration: medium. New RPC, no schema change.

### 5.3 PO physical receipt gate

Add column `physical_received_qty numeric null` to `purchase_orders` (or to a sibling table if Cody objects to widening `purchase_orders`). PO receipt no longer sets `warehouse_stock = ordered_qty` directly. Instead, the new `confirm_physical_receipt(p_po_line_id, p_physical_qty, p_received_by, p_notes)` RPC creates the `warehouse_inventory` row at `physical_received_qty` and links back to the PO line.

Until physical confirmation lands, the WH inventory row exists with `warehouse_stock = 0` and `status = 'PendingPhysicalReceipt'` (new status value). Refill engine treats this status as zero.

Migration: medium. New column, new status value, new RPC, FE field receipt page update.

### 5.4 Fix EOD `eod_auto_release_unpicked` for REMOVE actions

When re enabled, the cron must not credit WH for REMOVE auto releases. Units stay in machine if not picked up. Fix is in the function body: skip REMOVE rows in the release loop.

Currently paused (we paused job 9 on 2026-05-18). Do not re enable until this fix lands.

### 5.5 Auto receive on dispatch (carry over from memory `feedback_auto_receive_on_dispatch`)

Dispatch with `picked_up=true` should auto trigger `receive_dispatch_line` for Refill / Add New / Remove. No manual Receive step. Consumer stock only for genuinely in transit returns.

Needs Dara + Cody review before deploy. Lower priority than 5.1, 5.2, 5.3.

### 5.6 Block silent direct UPDATE on `warehouse_inventory`

The existing `trg_detect_silent_warehouse_write` only alerts. Promote it to raise an exception when:

- `via_rpc != 'true'`, AND
- the change touches `warehouse_stock` or `consumer_stock`, AND
- the new value is lower than the old value (the destructive case).

Inserts and increases stay allowed (PO ingestion path). Cody review required; this changes a soft alert into a hard block.

## 6. Workstream 3: Inventory UI rebuild

**Owner:** Stax (implementation), Cody (constitutional review for any new write paths)

### 6.1 Rewire edit count cell

Replace whatever the cell currently calls with `attempt_inventory_correction(session_id, wh_inventory_id, new_value, reason, correlation_id)`.

Behavior:

- Optimistic update disabled. Cell shows a spinner while RPC is in flight.
- On `result='success'`: cell updates to new value, green flash.
- On any non success: cell reverts, red banner with error message, attempt is visible in the session log.

### 6.2 Rewire status toggle

Replace whatever the toggle currently calls with `attempt_status_change(session_id, wh_inventory_id, new_status, reason, correlation_id)`. Same UX rules as 6.1.

For Inactive to Active flows with a positive stock value, the wrapper calls `attempt_reactivate_row` instead so the canonical reactivation path runs.

### 6.3 Mandatory reason field per change

Drop down: `physical_count`, `transit_adjustment`, `damaged`, `expired`, `swap_in`, `swap_out`, `manual_correction`, `other`. Free text allowed when `other`. Persists to `inventory_control_attempt.payload`.

### 6.4 Per row movement trail drawer

Click a row to expand a panel that renders `v_wh_inventory_movement_trail` for that `wh_inventory_id`. This is the reverse engineering tool.

### 6.5 Inventory session viewer at `/admin/inventory-sessions`

Lists sessions. Click into one shows the `v_inventory_control_session_summary` plus filterable list of `inventory_control_attempt` rows. Failed attempts surface in red with error message.

### 6.6 New page state: "Inventory Control Mode"

Top of inventory page has a "Start Inventory Control" button. Once started, every change in the page is attributed to that session. Closing the session generates a summary email or notification with the counts. CS or operator_admin can review the summary before signing off.

## 7. Success criteria

| Workstream | Criterion                                                                                                                          |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| 1          | Saturday's 23 product corrections applied, every row visible in `inventory_control_attempt` with `result='success'`.               |
| 1          | New inventory control session captures 100 percent of attempts (success and failure) for any WH manager activity.                  |
| 2          | After 5.1 deploy, no new packs with `from_wh_inventory_id IS NULL` for at least 7 days.                                            |
| 2          | Consumer_stock phantom backlog reduced to 0 after 5.2.                                                                             |
| 2          | After 5.3 deploy, no new `warehouse_inventory` rows with `warehouse_stock > 0` created by PO receipt before physical confirmation. |
| 3          | WH manager can edit any cell or toggle status, see real time success or failure, reload and confirm persistence.                   |
| 3          | Next physical count for the same 23 products shows delta within plus or minus 2 units per product (drift from in flight ops only). |

## 8. Sequencing

**Phase 1 (this week, 2026-05-25 to 2026-05-31):**

- 4.1, 4.2 (new tables, Cody review)
- 4.5, 4.6, 4.7 (RPCs)
- 6.1, 6.2 (FE rewire, the unblocker)
- 4.8 (apply Saturday corrections)

**Phase 2 (next week, 2026-06-01 to 2026-06-07):**

- 5.1 (NULL from_wh pack refusal)
- 5.4 (EOD REMOVE fix)
- 4.4 (movement trail view)
- 6.4 (UI drawer)

**Phase 3 (week of 2026-06-08):**

- 5.2 (consumer_stock phantom drain with CS sign off)
- 5.3 (PO physical receipt gate)
- 6.3, 6.5, 6.6 (rest of UI)

**Phase 4:**

- 5.5 (auto receive on dispatch, after Dara + Cody review)
- 5.6 (promote silent write detection to hard block)

## 9. Safety / Constitution

Non negotiable across all phases:

- All `warehouse_inventory` writes via canonical RPC only. Direct UPDATE is forbidden outside RPCs.
- No DELETE on any table without explicit per row CS approval.
- No silent stock reductions. Show CS the row diff before commit. CS sign off required per row for any decrease.
- Plan Write Protocol for all corrections: pre flight validation, write via RPC, verify by reading back, report to CS.
- No em dashes in code, commits, file headers, or chat. Use commas, colons, periods, or parentheses.
- All migrations reviewed by Cody before apply.
- Skill `boonz-master-3` must be loaded before any operational action per `feedback_must_load_skills_before_ops`.

## 10. Open questions for CS

1. The +124 Al Ain Water, +83 Snickers, +13 Vitamin Well Reload overstatements: do you want a forensic movement trail per row before any correction, or is the +124 / +83 / +13 a known shrinkage that you accept and want zeroed via correction now?
2. For 5.6 (hard block on silent direct UPDATE), are you OK with potentially breaking any legacy n8n flow that still writes directly? Or should we audit n8n callers first?
3. For 5.3 PO physical receipt gate: should existing PO rows with `warehouse_stock > 0` be retroactively flagged as "needs physical confirmation," or do we only apply the gate to new PO receipts going forward?
4. For 6.6 Inventory Control Mode: do you want the session to lock the page (no edits outside a session), or is a session optional?

## 11. Out of scope

- Anything touching `sales_lines` or Adyen reconciliation.
- Refill engine logic changes.
- Driver app changes other than what 5.4 implies.
- VOX or partner specific sourcing logic.
