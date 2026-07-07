# PRD-080 Execution Log — fefo + reservation *

Run 2026-07-07, AUTO. **Status: PARKED** (referee not candidate-capable + protected sign-off).
Flag `fefo_reserve_v1` — NOT enabled (ship-dark not reached). Engines byte-identical `c22b57e6` (no engine change made).

## Safe independent sub-step done (read-only VERIFY)

VERIFIED live: FEFO live-rebind present in pack_dispatch_line via ORDER BY expiration_date ASC (PRD-072; the 'FEFO' literal grep is false because the code orders by expiry, not a named token). NET-NEW to add: wh_reservation table + v_wh_pickable subtracts active reserved units.

## Why parked (not forced)

- **Rule B precondition:** the referee (076+077+078) is reference-ready but NOT candidate-capable — validating this change at output level (`diff_vs_golden` a candidate, HARD GATE) requires running the engine on a Supabase preview branch, and this project's branches carry no prod data (see MASTER-PARKING-LOT 076/078). So "referee GREEN" cannot be met via the branch path.
- **Rule E protected:** touches a protected entity / SECURITY DEFINER — requires Cody verdict + CS sign-off before ANY prod apply. NOT self-approved.

## To un-park

Resolve the branch-data program decision (MASTER-PARKING-LOT) so candidates can be captured + Cody+CS sign-off. Reconciliation: prior art is live (above), so this is likely VERIFY/close-residual, not re-implementation.
