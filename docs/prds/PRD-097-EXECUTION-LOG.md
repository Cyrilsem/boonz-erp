# PRD-097 Execution Log — R7/R3/empty-shelf swap guards (PARKED)

Run 2026-07-09 overnight, AUTO. **Status: PARKED (rule F: spec drift). NOT shipped.**

## Why parked

Partial anchors only. `engine_finalize_pod` HAS `r7_machines_over_60pct` (a COUNT) + a
`suppressed`/empty-shelf notion, but the spec's other targets are ABSENT: no `churn`/`R7`
hard-block, no `R3`/`net_flow`/same-SKU combined-WH logic. Converting R7 count→hard-block,
adding R3 net-flow enforcement, and surfacing suppressed removals is largely **build-from-scratch**
on the 16KB finalize engine, not a bounded flag-gate — high risk without Dara design.

## Needed to un-park

Dara designs the R7 hard-block threshold + override tag, the R3 same-SKU net-flow rule, and the
suppressed-removal surfacing against current finalize internals; then build behind `swap_guards_v1`.

## Status: PARKED (rule F: R3/churn/net-flow anchors absent). Owner: Dara + CS.
