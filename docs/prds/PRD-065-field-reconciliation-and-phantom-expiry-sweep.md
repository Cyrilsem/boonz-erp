# PRD-065: Field reconciliation completeness + phantom-expired sweep

Status: Shipped 2026-07-01 (8 prd065 migrations on main + prod; overnight chore 318afd4; working branch merged and deleted clean in PRD-071 WS-A).

Owner: CS
Date: 2026-06-29
Surface: New canonical RPCs, one view, one pg_cron sweep, plus FE/driver-app capture fixes. Touches protected entities (pod_inventory, warehouse_inventory, pod_inventory_edits, refill_dispatching) so every writer is Dara-designed and Cody-reviewed before apply.
Governance: canonical RPCs only (Article 1/3). SECURITY DEFINER writers need Cody sign-off. Forward-only. Idempotent. Reversible write-offs. Flag-gated rollout. No em dashes.

## Objective

Stop the data drift that forces manual SQL surgery every refill cycle. The 29 Jun 2026 reconciliation exposed that driver field actions (off-plan adds, returns, partial fills, expiry removals) do not reliably reach the database, so phantom inventory accumulates and expired counts stay wrong. This PRD closes the capture gaps (Pillar A) and adds a scheduled sweep so ghosts self-clear instead of piling up (Pillar B).

## Background: what 29 Jun exposed (evidence)

1. A `partial_sold` edit (JET Pepsi Black, edit 5d5ab4a7) was created with `quantity_update = NULL`, so `approve_pod_inventory_edit` threw "invalid quantity_update". The review queue had no way to set the qty and approve. Had to be patched by hand.
2. An off-plan field add (5 M&M Chocolate Nuts to OMDBB) had no driver-app path. Had to hand-build an `add_stock` edit.
3. A partial dispatch fill (NOVO Dubai Popcorn Salted: filled 2 of 6) left 4 units in limbo: not loaded, `returned = false`, no warehouse credit. The receive step was never closed.
4. 20 "Active + expired" phantom rows (12 zero-stock residuals fleet-wide plus 8 on the WH2/MCC machine for products never refilled there) sat inflating the expired counts. Cleared by hand via `backfill_archive_pod_inventory_row`.
5. The Al Ain defective write-off could not be done server-side because `adjust_warehouse_stock` is gated on `auth.uid()` (FE only). There is no server-callable warehouse expiry/defective write-off.

## Hard rules

1. CANONICAL RPCs ONLY. No direct INSERT/UPDATE/DELETE on pod_inventory / warehouse_inventory / refill_dispatching / pod_inventory_edits from cron, n8n, or the conductor. New writers are SECURITY DEFINER, accept an explicit caller id, and pass Cody.
2. IDEMPOTENT. Every sweep and every reconciliation step detects current state first and is a no-op if already applied. Never double-credit WH, never duplicate a pod row, never re-remove.
3. EXPIRED = WRITE-OFF, never a WH return. Expired removals are losses. Returns (good stock not loaded) credit WH; expired stock does not.
4. REVERSIBLE. Write-offs use the existing reversible pattern (status to Inactive, stock to 0, removal_reason set), not deletes.
5. FLAG-GATED. The sweep ships behind a params flag, default off, dry-run first.
6. FORWARD-ONLY. No backfill of history beyond what the sweep zeroes; no schema rewrites of existing writers without Cody.

## Pillar A: capture gaps (field actions reach the DB without manual SQL)

A1. No-NULL-quantity guard + inline repair.

- Guard: a `pod_inventory_edits` constraint/trigger so `sold`, `partial_sold`, `return_to_warehouse`, `add_stock`, `add_new_product` cannot be created with `quantity_update` NULL or <= 0 (`expired` is exempt, it ignores qty). The driver app must send the qty.
- Repair path: an operator action in the review queue to set the qty and approve in one step (what we did by hand for Pepsi). Wrap as `set_edit_quantity_and_approve(edit_id, qty, caller_id, note)` or expose qty-edit in the FE before approve.

A2. First-class off-plan field add.

- `create_field_add_edit(machine_id, pod_product_id_or_shelf, boonz_product_id, qty, expiry, caller_id, reason)`: resolves the destination shelf from the `product_mapping` for the pod_product (e.g. M&M Chocolate Nuts under "Chocolate Bar"), inserts a pending `add_stock` edit, returns edit_id. Driver app calls this for "refill but not in list". Approval still flows through `approve_pod_inventory_edit`. No manual INSERT.

A3. Lossless partial-fill / not-loaded capture at dispatch close.

- At pack/receive close (`confirm_machine_packed` / `receive_dispatch_line`), any dispatched unit with `filled_quantity < quantity` and not already returned must be auto-marked returned for the remainder and credited to WH via `return_dispatch_line`. Result: no unit sits in limbo (the NOVO salt-4 case), and the warehouse credit is complete and idempotent.

## Pillar B: phantom-expired sweep (ghosts self-clear)

B1. `v_expired_inventory` (Dara): one view unifying pod_inventory and warehouse_inventory rows that are Active and past expiry, with columns: location (machine vs warehouse), product, shelf, units, expiry, age_days, and bucket = `zero_stock_residual` (units = 0) vs `stock_bearing` (units > 0). This is the single source for the dashboard's expired tiles.

B2. `sweep_expired_inventory(p_dry_run boolean, p_caller_id uuid)` (Cody):

- `zero_stock_residual` rows: auto write-off to Inactive (pod via `backfill_archive_pod_inventory_row`; warehouse via the new `warehouse_expire_writeoff`, see B4). These are the 12 + 8 we cleared by hand.
- `stock_bearing` rows: do NOT auto-clear. Push to the existing "To validate" driver queue (the dashboard already shows "Past expiry, stock = 0, driver to verify"; extend the queue to stock > 0 = "driver to confirm removal").
- Idempotent, returns a summary (cleared, queued). Scheduled via pg_cron once enabled.

B3. Driver-confirm closeout: when the driver confirms a queued stock-bearing expired row as physically removed, write it off (Inactive, 0, no WH credit, expired = loss). Idempotent.

B4. `warehouse_expire_writeoff(wh_inventory_id, reason, caller_id)` (Dara design, Cody review): a server-callable warehouse expiry/defective write-off (sets stock to 0, status Inactive, writes inventory_audit_log), because `adjust_warehouse_stock` is `auth.uid()`-gated and has no server path. This also unblocks the Al Ain defective case.

## Detection / idempotency (per action)

- A1 guard: reject at insert; repair path checks edit is still pending.
- A2: already_done if a pending/approved add_stock edit or an Active pod row for that machine+shelf+product+expiry already exists.
- A3: already_done if the dispatch row is already fully received or returned.
- B2/B3: already_done if the row is already Inactive / 0 / queued.

## Rollout

1. Dara designs `v_expired_inventory`, `warehouse_expire_writeoff`, the edits guard. Cody reviews all writers.
2. Ship A1 guard + A2 + A3 first (capture side), so new drift stops.
3. Ship B1 view, then B2 sweep in dry-run (report only). Eyeball one cycle. Then enable the flag and the cron.
4. Reversible: every write-off can be flipped back.

## Out of scope

- POS flavor capture (separate, PRD-064 assortment area).
- M2M transfer reconciliation.
- Picker / refill-engine changes.
- Historical backfill beyond what the sweep zeroes.

## Appendix: 29 Jun manual actions this PRD would have automated

- Set qty + approve Pepsi partial_sold (A1).
- Hand-built add_stock for 5 M&M to OMDBB Chocolate Bar (A2).
- NOVO Dubai Popcorn Salted 4 units left in limbo (A3).
- 20 Active+expired phantom rows cleared via backfill (B2).
- Al Ain defective could not be written off server-side (B4).
