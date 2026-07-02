# PRD-033: Operator flexibility - remove the roadblocks that blocked a live manual rotation

Status: Shipped (A-E migrations + VOX perf on main/prod per PRD-071 proof; weimi API archived unwired on archive/weimi-api-2026-06, PRD-072 WS-C). Closed out 2026-07-03.

Owner: CS
Date: 2026-06-17
Surface: Backend (RPCs, views, generated columns), refill pipeline, procurement skill. Cody review required (touches protected entities: warehouse_inventory, pod_refill_plan, refill_dispatching).
Governance: Dara designs schema/view changes, Cody reviews constitutional impact, Stax wires FE/RPC. Forward-only. No em dashes.

## Objective

Make the refill + warehouse pipeline support a real, in-the-moment operator workflow: hand-build a multi-machine rotation (remove X, add new product Y, set my own quantities), release good stock that the system has wrongly held, and re-resolve the plan against fresh stock, WITHOUT the system either silently dropping the new products or forcing a full re-derive that wipes the manual work.

## Why

On 2026-06-17 we ran a manual stock rotation across 6 machines (AMZ-3001, AMZ-3003, AMZ-2401, AMZ-2403, HUAWEI, MC): refill plus forced product placements (Starbucks, M&M, Keen Health, Coco Max) with operator-chosen shelves and quantities. The intent was simple. Executing it took dozens of round-trips and several workarounds because the pipeline assumes the engine builds the plan and nothing changes after stitch. Every assumption that is fine for the nightly cron became a wall for a human doing a deliberate, legitimate edit.

Net outcome: it got done, but only by (a) a guarded direct write to a protected table to release good inventory, and (b) bypassing the stitch entirely with direct dispatch-row writes. Both are off the sanctioned path. We need the sanctioned path to support this.

## Roadblocks (all verified live 2026-06-17)

### R1. The capacity clamp ignores planned removals (highest impact)

- Symptom: placing a new product on an occupied shelf is capped to the current free space, even when a paired REMOVE empties that shelf in the same visit. Nutella was 12/12, so Keen on that shelf clamped to 0. Coco Max wanted 10, clamped to 6. Keen on Smart Gourmet wanted 6, clamped to 3.
- Root cause: `v_shelf_capacity.headroom = max_stock - current_stock`, where `current_stock` comes purely from live WEIMI (`v_live_shelf_stock`). It does not net any planned REMOVE/M2W rows on the same shelf for the same plan_date. Both `add_pod_refill_row` and `edit_pod_refill_row` hard-clamp REFILL/ADD_NEW to that headroom.
- Impact: a true product swap is impossible to express in one cycle. The operator is forced into multi-cycle conversions or under-filled shelves.
- Proposed fix: make `v_shelf_capacity` (or the clamp logic in add/edit) subtract same-plan REMOVE + M2W quantities for the shelf, so headroom reflects post-removal capacity. Alternatively add a `p_allow_overfill_after_removal` path that trusts a paired REMOVE.

### R2. No way to re-stitch a manually built, already-stitched plan

- Symptom: after committing, we released stock and needed to re-resolve only the affected shelves. There was no supported way.
- Root cause: pod_refill_plan status is one-way (draft -> approved -> stitched). The re-stitch tools each fail this case:
  - `approve_pod_refill_plan` only flips draft -> approved.
  - `restitch_after_edits` requires status = 'approved' AND edited_at > last_stitch (ours were 'stitched').
  - `reset_and_restitch` supersedes everything then calls `engine_finalize_pod`, which re-derives ONLY from engine staging (`pod_refills` / `pod_swaps`). Manual rows added via `add_pod_refill_row` / `swap_pod_refill_row` live only in `pod_refill_plan`, so a reset WIPES the entire manual rotation.
  - `reset_approved_undispatched` does not reopen pod rows and refuses when any dispatch row is WH-bound.
  - There is no void/supersede RPC for a single stitched pod row (`restore_pod_refill_row` only acts on already-'superseded' rows).
  - Hard Rule 9 forbids a raw UPDATE to flip status.
- Impact: once a hand-built plan is stitched, it is effectively frozen. Any post-stitch change (stock arrives, quarantine released, qty fix) has no clean path.
- Proposed fix: a `reopen_stitched_rows(plan_date, machine_ids[], shelf_ids[])` RPC that flips selected stitched rows back to 'approved' (preserving the row, not re-deriving), so a targeted re-stitch can run. And/or make `restitch_after_edits` accept 'stitched' rows whose pod data changed since last stitch.

### R3. Quarantine has no release RPC and silently blocks dispatch

- Symptom: Starbucks (18u), M&M (6u) and Coco Max (15u) were all in WH_CENTRAL, Active, in-date, but dispatched 0. Stitch only emitted a soft `resolved_no_wh_stock_warning`.
- Root cause: `v_wh_pickable` excludes `quarantined = true`. `quarantined` is a GENERATED column: `provenance_reason IS NULL OR provenance_reason IN ('unknown_pre_migration','dispatch_return_unverified')`. The held stock was benign (April migration artifacts and one unverified return). There is NO canonical RPC to release quarantine; `reactivate_warehouse_row` only flips `status`, not provenance/quarantine. We had to set `provenance_reason='manual_adjust'` via a guarded direct UPDATE on a protected table.
- Impact: good stock is invisible to the picker with no operator-facing way to release it, and the only "release" is an off-path raw write.
- Proposed fix: a `release_wh_quarantine(wh_inventory_id, reason, verified_by)` RPC that sets a verified provenance (or a dedicated `quarantine_cleared_at` column) with full audit, role-gated to warehouse/operator_admin. Surface quarantined-but-good stock in the FE with a one-click "verify and release".

### R4. No hard gate when a commit removes a product but cannot restock it

- Symptom: the committed plan dispatched REMOVE lines for incumbents but zero ADD lines for the new products (stock was quarantined). Drivers would have emptied shelves with nothing to load.
- Root cause: stitch treats "resolved to 0 units, no WH" as a non-blocking warning and commits anyway. No invariant checks "shelf has a REMOVE/M2W but its paired ADD_NEW resolved to 0".
- Impact: silent shelf-emptying. Lost sales, confused drivers.
- Proposed fix: a pre-commit invariant that flags (and optionally blocks) any shelf where an incumbent is being removed but the replacement resolves to 0 dispatchable units. Either block the commit or auto-hold the REMOVE until the ADD can be filled.

### R5. REMOVE quantity is bound to tracked pod_inventory, not the physical shelf

- Symptom: Removes dispatched below the visible shelf count (Smart Gourmet 2 vs ~5, Barebells 7 vs 11, Sun Blast 2 vs 4). CS flagged this as "weird".
- Root cause: REMOVE resolves against `pod_inventory` tracked stock, which diverges from WEIMI live.
- Impact: under-removal and operator confusion; the number on the picking screen does not match the shelf.
- Proposed fix: reconcile pod_inventory to WEIMI before REMOVE resolution, or let REMOVE resolve against live shelf stock with a clear "tracked vs live" indicator, and allow the driver to confirm the actual pulled qty.

### R6. swap_pod_refill_row does not model a real product swap

- Symptom: the "swap" stops the old REFILL and adds the new product into headroom only; it does not create a REMOVE for the incumbent physical units, and it leaves the incumbent counted against capacity (feeds R1).
- Root cause: swap_pod_refill_row = edit(old -> 0) + add(new, carry old qty). No REMOVE/M2W of the incumbent's physical stock.
- Impact: we had to hand-build REMOVE + ADD_NEW pairs per shelf, and still hit the R1 clamp.
- Proposed fix: a first-class `convert_shelf(plan_date, machine, shelf, old_pod, new_pod, new_qty, return_mode)` that atomically writes REMOVE(old, physical) + ADD_NEW(new, target) and frees capacity for the add.

### R7. Generated columns and hidden constraints produce cryptic dead-ends

- Symptom: `UPDATE ... SET quarantined=false` failed with "can only be updated to DEFAULT"; `is_global_default` same. The fix required reading the generation expression and two CHECK constraints to discover that `provenance_reason='manual_adjust'` was the only valid release value.
- Impact: time lost reverse-engineering; not discoverable by an operator.
- Proposed fix: where a column is operator-relevant but generated/derived, expose a setter RPC (see R3) rather than leaving operators to infer the source column and its enum.

### R8. Stale skill guardrails block valid actions

- Symptom: the weekly-procurement skill still lists Ritz Cracker as permanently decommissioned, though it was revived on 2026-06-12 (intent abandoned, WH batch + supplier_products restored, PO block cleared). The standing rule would have blocked a legitimate Ritz order.
- Impact: false blocks; operator has to know the skill is wrong.
- Proposed fix: drive decommission guardrails from live `strategic_intents` state, not hard-coded skill text. Skills should read the current decommission list, not embed it.

### R9. Sequencing assumption: stock must be pickable BEFORE stitch, with no late-binding

- Symptom: because quarantine was discovered only after commit, and there is no re-stitch (R2), we could not bind the freed stock to the already-committed plan.
- Proposed fix: covered by R2 + R3; call out explicitly that the pipeline needs a late-binding step (stock arrives or is released -> re-resolve pending dispatch lines).

## Priority

1. R1 (capacity clamp nets planned removals) - unblocks all product swaps.
2. R2 (reopen/re-stitch a stitched manual plan) - unblocks any post-commit change.
3. R3 (quarantine release RPC + FE) - stops good stock being silently unpickable.
4. R4 (remove-without-replace gate) - safety, prevents emptied shelves.
5. R6 (first-class convert_shelf) - collapses the manual REMOVE+ADD_NEW dance.
6. R5, R7, R8, R9 - ergonomics and correctness follow-ups.

## Acceptance checks (must confirm on apply, report pass/fail per item)

- A. Phase A scope is `status IN ('draft','approved')` (not `NOT IN (superseded,voided)`). After applying, re-run A3 and confirm `planned_removed <= current_stock` on every shelf (the 192/144/117 were historical stitched removes and must be gone).
- B. Phase B re-stitch is IDEMPOTENT on a reopened plan: reopening rows then re-stitching produces NO duplicate `refill_plan_output` or `refill_dispatching` lines for shelves already dispatched. Verify with a rolled-back battery (reopen -> stitch -> count lines before/after must match for unchanged shelves).
- C. Phase C `release_wh_quarantine` is a NO-OP plus an explicit report when the target row is not quarantined (does not touch stock, status, or provenance; returns a "not quarantined, nothing to do" result).
- D. Phase D defaults to BLOCK and returns the offending shelves in `flagged[]` (non-silent); pure removals with no paired ADD_NEW are not flagged.

## What we had to do today as workarounds (for context, do not bake these in)

- Released benign quarantine via a guarded direct UPDATE to `warehouse_inventory.provenance_reason` (no RPC exists).
- Bypassed the frozen stitch by writing dispatch lines directly with `add_dispatch_row` at SKU level, hand-splitting variants and hand-allocating WH.

## Out of scope

The nightly cron engine flow (it works). This PRD is specifically about the human-in-the-loop edit path layered on top of it.
