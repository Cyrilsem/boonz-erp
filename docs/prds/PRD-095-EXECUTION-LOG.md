# PRD-095 Execution Log — Expiry-risk swap trigger (PARKED)

Run 2026-07-09 overnight, AUTO. **Status: PARKED. NOT shipped.**

## Why parked

Depends on **parked** work: (1) the incoming swap is "sized by PRD-094 product-anchored cap" —
PRD-094 is parked (spec drift). (2) reads the PRD-091 `expiry_risk` signal — PRD-091 is parked
(representation undecided). The direct-read fallback (`v_pod_inventory_latest` expiry) still
requires editing the rewritten 30KB `engine_swap_pod` candidate-set logic, same drift as 094.

## Needed to un-park

PRD-094 (product-anchored cap) + a resolved expiry signal (091 or a direct-read design), then
build the expiry-risk candidate extension behind `swap_expiry_v1` against the current engine.

## Status: PARKED (depends on parked 094 + 091; engine_swap_pod drift). Owner: Dara + CS.
