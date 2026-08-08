# PRD-113 — In-Machine Moves Are Not Returns + Expired Stock Never Auto-Consumed

**Status:** APPROVED by CS 2026-08-08 · **Owner:** Stax-class unit, executable by Claude Code
**Repo:** boonz-erp. Backend + /refill FE. Cody review REQUIRED (touches return flow + the
refresh pipeline, both protected territory).

## Problem 1 — In-machine swap legs masquerade as warehouse returns

Live incident (MC-2004, plan 2026-08-07, reported by warehouse manager): a swap that MOVES
product between shelves of the SAME machine produced (a) an "Add New" label in dispatching that
confused the driver ("Move with Machine" intent lost), and (b) the Remove legs landed in the
**Inventory Approval** queue as pending warehouse returns. Approving them would credit the
warehouse for units that are physically inside the machine — phantom stock. The manager caught
it this time; the previous occurrence was silently mishandled. Root cause: the return-approval
queue is `refill_dispatching` rows with action Remove/M2W and `wh_approved_at IS NULL`, with no
concept of "these units moved to another shelf, they are not coming back."

Already hand-fixed (2026-08-08): the three MC-2004 legs (Pepsi Black 1+1, Coke Zero 3) were
cleared via direct `wh_approved_at` stamp with reason "INTERNAL MOVE... zero credit" — this
neutralization pattern is the interim workaround the PRD makes obsolete.

### Fix

1. **Schema:** add boolean `is_internal_move` (default false) to `refill_dispatching`
   (additive, no backfill needed beyond step 4).
2. **Writers:** wherever a swap/move pair is created for the SAME machine (stitch same-shelf
   swap legs, push_plan_to_dispatch paired legs, add_dispatch_row with
   source_kind='m2m' AND source_machine_id = machine_id, and any "Move with Machine" path),
   set `is_internal_move = true` on the Remove leg. Detection rule for stitch: Remove leg whose
   shelf's Add New counterpart exists on the SAME machine in the same plan, or whose comment
   carries the move convention.
3. **Return queue:** the Inventory Approval query (FE + any RPC behind approve receipt) excludes
   `is_internal_move = true`. Approving a return RPC called on such a row refuses with a clear
   message ("internal move - nothing to credit").
4. **FE labels:** dispatch detail + driver views show internal-move legs as **"Move within
   machine"** (distinct chip), never "Remove/Return", and the paired Add New shows "Moved from
   shelf X". Backfill display-only: rows whose comment matches the existing move conventions
   render the same way.
5. **Golden fixture:** encode the MC-2004 incident — same-machine swap → Remove leg flagged →
   return queue EMPTY for it → warehouse stock unchanged; a genuine M2W on the same plan still
   queues normally (the 10-unit Freakin 3P return is the positive control).

## Problem 2 — "Refresh Data" pipeline FIFO-consumes EXPIRED pod stock

The Refresh Data pipeline on `/refill` (Stock Snapshot tab) runs a "FIFO decrement" step that
applies sales against pod batches oldest-first — INCLUDING expired batches. Expired units are
thereby recorded as sold and vanish from the system while physically still sitting in the
machine. This violates the standing CS iron rule (also v3 LAW 7 / golden fixture 20): **expired
stock never exits by assumption — only by explicit manual write-off.** CS decision: keep
expired handling fully manual.

### Fix

1. Locate the FIFO decrement implementation invoked by Refresh Data (edge function / RPC named
   in the pipeline log: "FIFO decrement... N processed"). Modify the batch-selection predicate
   to **skip batches with `expiration_date < current Dubai date`** — sales consume only
   non-expired batches (still oldest-first among the non-expired). If sales exceed non-expired
   stock, decrement to zero on non-expired and log the overflow (do NOT touch expired).
2. Expired batches remain visible with their quantities until a human write-off (existing
   manual flow, unchanged).
3. **Repair report, not auto-repair:** produce a one-off report (CSV or table output in the
   PRD-113 report file) of pod batches where the decrementer consumed expired units in the last
   30 days (machine, shelf, product, batch expiry, units consumed) so CS can decide restorations
   manually. No automatic restoration.
4. Cron parity: if any scheduled job runs the same decrement, it gets the identical predicate —
   one shared implementation, not two copies.

## Problem 3 — Remove the dead "Review All" button

The purple "🤖 Review All" button on `/refill` Stock Snapshot does not work. Delete the button
and its dead handler/imports. No replacement in this PRD.

## Constraints

- Cody reviews: the schema addition, every writer change, the return-queue predicate, and the
  decrementer change (pod_inventory is protected; LAW 7 is constitutional here).
- Genuine M2W / driver returns flow is byte-identical except for the new exclusion.
- No engine (v19) logic changes; no v3 shadow changes. v3 already implements both rules
  natively — this aligns v1 with them.
- All migrations additive; PRD-110 loop files untouched; own migration files only.

## Acceptance

1. Fixture: same-machine swap plan → Remove leg `is_internal_move=true` → absent from approval
   queue → WH stock unchanged; genuine M2W same plan → present in queue → approve credits once.
2. Refresh Data run over a machine with an expired batch + sales: expired batch quantity
   unchanged; non-expired decremented; overflow logged. Fixture on synthetic 2030 data.
3. 30-day repair report generated and saved to docs/prds/PRD-113-expired-consumption-report.md.
4. "Review All" button gone; page builds and renders.
5. golden.run_all green; build green; merge to main; production verified.

## Execution notes for Claude Code

Single-session task, branch `prd-113-internal-moves-expired-guard`. RUN AFTER the PRD-112 relay
exits (shared /refill surfaces). Backend first, Cody paragraph in the report, then FE. Append
progress to docs/prds/PRD-113-REPORT.md; final line `## PRD-113 DONE` (or `## PRD-113 BLOCKED`
with the Cody verdict). Live smoke limited to read paths + one synthetic-date fixture run.
