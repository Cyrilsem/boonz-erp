# PRD-080: FEFO + reservation at approve (residual closure)

Status: PARKED 2026-07-07 (prior art verified live; blocked on referee candidate-capture / branch-data + Cody+CS sign-off — see EXECUTION-LOG).
Owner: CS. Mode: AUTO with hard gates. Dara designs, Cody reviews, Stax wires.

## Why

FEFO batch bind and pickqty→plan are shipped (PRD-036/050). The remaining gap (audit §3-C, field bug 5): binding is not contention-aware / reserved, so under concurrency two dispatch lines can bind the same earliest-expiry batch that only covers one → phantom "no stock" at pack. PRD-072 tracks the residue. This formalizes the reservation.

## Design (Dara designs, Cody reviews, Stax wires)

1. **Verify** current bind: confirm `from_wh_inventory_id` is stamped FEFO at approve (PRD-036) and `pack_dispatch_line` live-rebinds on stale batch. Document actual behaviour in the log (no change if already correct).
2. **`wh_reservation(reservation_id, wh_inventory_id, dispatch_id, units, plan_date, expires_at, created_at)`** — soft reservation. `wh_is_pickable`/`v_wh_pickable` (PRD-079) subtracts active reserved units.
3. **`bind_fefo_reserved(plan_date, machine_ids[])`** — contention-aware FEFO with a per-batch running tally (no oversubscription); writes reservations; called inside `approve_pod_refill_plan`/stitch. `FOR UPDATE` by `wh_inventory_id`.
4. **Release** on pack complete / void / reschedule / TTL (fold into `release_stale_wh_pins`). Retire the manual FEFO SQL patch from the runbook.

## Gates

- Plan ROWS unchanged (only binding metadata + reservations added): PRD-076 diff = plan rows identical. Conservation (PRD-077) green. No batch oversubscribed. Consignment SKUs skipped. Cody signs. Flag `fefo_reserve_v1`.

## T-tests

- T1 two lines share a 1-unit batch ⇒ distinct bindings; second gets next FEFO or `procurement_gap`.
- T2 expire bound batch ⇒ pack rebinds, no failure.
- T3 re-approve ⇒ no leaked reservations (count stable).
- T4 concurrent approve ⇒ no oversubscription (locking).
- T5 diff = plan rows unchanged; T6 conservation green.

## CLOSE

Update PRD-072 residue status; CHANGELOG + registry; PRD-080 SHIPPED + EXECUTION-LOG; commit + push. Rollback = flag off + drop `wh_reservation`.
