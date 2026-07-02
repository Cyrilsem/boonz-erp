# PRD-068: Refill-log integrity - post-confirm conservation + not-filled reconcile + test-row purge

Status: Shipped 2026-07-01 (e1b9368 on main; durable conservation guards VERIFIED LIVE in prod 2026-07-02: trg_conserve_split_qty, trg_reassert_conservation, trg_credit_dispatch_remainder). PRD-071 sweep.

Owner: CS. Date: 2026-06-30. Surface: backend reconciliation + a re-assert hook. Touches refill_dispatching, pod_inventory, warehouse_inventory, stitch_leakage (Articles 1,3,12,16). Cody review mandatory. Idempotent, no em dashes.

## Why (verified live 2026-06-30)

The refill logs ARE being written - stitch_leakage telemetry, needs_review queue and driver_confirmed all populate. But the divergences they record are not being reconciled, so pod / WH / dispatch do not fully agree. Evidence:

- `check_pod_conservation('2026-06-30')` = 5 REMOVE instructions where dispatch children exceed the pod-plan parent (e.g. plan 6, dispatched 8; plan 7, dispatched 13). Live, today.
- `stitch_leakage` is firing heavily on recent plans: 174 rows / 916 units on 06-30, 30 rows on 06-28, 46 on 06-26. Divergence between the pod REMOVE plan and the dispatched REMOVE children is large and ongoing.
- 40 dispatch rows in the last 2 weeks have `driver_confirmed_qty <> quantity` (the "qty 4 to 2 after confirm" complaint, WPP 23/06). The conservation gate runs at PUBLISH but nothing re-asserts after the driver/field edit, so the post-confirm state drifts.
- 8 rows have `pack_outcome='not_filled'` but `filled_quantity > 0` (the 19/06 AMZ-1029 Snickers "Not Filled still shows qty in Dispatch" class) - a data-level contradiction, not just a display bug.
- 9 stale TEST rows dated 2099-12 ("[S1] refill full-fill test", "[S4] BUG-012 cascade live test") are still `dispatched=true` and skew every unbounded aggregate (MAX(dispatch_date)=2099).

(The 38% of refill lines with no warehouse batch bound at pickup - `from_wh_inventory_id IS NULL`, 647 of 1719 - is the separate "pickup qty 0 despite WH stock" issue; that is PRD-036's FEFO-bind-at-pickup and is referenced, not duplicated here.)

## Fixes

1. **Post-confirm conservation re-assert.** After a driver confirmation or field edit changes a REMOVE/M2W line, re-run the conservation check for that instruction and reconcile pod + WH to the driver-confirmed truth (driver_confirmed_qty is the physical reality; update the pod-plan parent and the pod/WH ledger to match, or flag needs_review if it cannot be reconciled). Today's 5 live violations are reconciled by this. Add the re-assert as a hook on the confirm/edit RPCs, not only at publish.
2. **Not-filled reconcile.** When `pack_outcome='not_filled'`, force `filled_quantity=0` and ensure no pod/WH credit was taken for the unfilled qty; when it was actually partial, reclassify to `partial` with the real filled_quantity. Fix the 8 existing rows + guard going forward.
3. **Test-row purge.** Archive/delete the 9 rows with `dispatch_date >= '2099-01-01'`. They are 2026-05-14 test fixtures. Idempotent.
4. **Standing monitor (Article 16).** A daily job runs `check_pod_conservation(today)` and emails the non-conserving rows + the stitch_leakage day-total so divergence is caught the morning it happens, not weeks later.

## Rules

- Canonical RPCs only; the re-assert reconciles to driver-confirmed reality and never silently changes the books without a log line.
- Idempotent: already-reconciled instructions, already-zeroed not_filled rows, already-purged test rows all no-op.
- CONSERVATION: after reconcile, `check_pod_conservation(date)` returns zero rows for the processed dates; total pod+WH for each touched product is unchanged except the explicit driver-confirmed correction (logged).
- Cody verdict required.

## Acceptance

- `check_pod_conservation` returns zero rows for 2026-06-24..30 after the run.
- Zero rows with `pack_outcome='not_filled' AND filled_quantity>0`.
- Zero rows with `dispatch_date >= '2099-01-01'`.
- The re-assert hook is wired so a future post-confirm edit cannot leave an unreconciled REMOVE divergence.
- The daily conservation monitor is scheduled and its first run is logged.
