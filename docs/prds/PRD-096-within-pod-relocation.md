# PRD-096: Within-pod relocation (turn the capacity-mismatch warning into an action)

Status: PARKED 2026-07-09 (rule F: Wave-2 spec drift vs rewritten engine / dependencies; + concurrent engine modification mid-run). NOT shipped. See EXECUTION-LOG.
Owner: CS. Mode: AUTO with hard gates. Dara designs, Cody reviews.

## Why

`engine_finalize_pod` already **detects** the mismatch — a high-velocity item capped on a small shelf while a slow item sits on a big shelf — and emits a `capacity_mismatch_warnings` entry. But it never acts. Turn that warning into an approvable **relocation proposal** so the operator can move the high-velocity product to the bigger shelf.

## Design (Dara designs, Cody reviews)

1. In `engine_finalize_pod` (behind `pod_reloc_v1`): for each `capacity_mismatch` pair, emit a `RELOCATE` proposal row (`swap_shelf_pod` shape: move `hv_product` from `hv_shelf` to `lv_shelf`) into `pod_refill_plan`/proposals, tagged `within_pod_relocation`. Proposal only — no execution.
2. Flag off ⇒ warnings stay warnings (identical).

## Gates

- Flag OFF ⇒ `diff_vs_golden`(golden_v2) IDENTICAL. Flag ON ⇒ capture delta; each capacity_mismatch pair yields an approvable relocation proposal; conservation green (relocation is unit-neutral); no oversubscription. Other Family-A engines byte-identical. Cody signs.

## T-tests

- T1 flag off ⇒ golden_v2 identical.
- T2 flag on ⇒ a hv-on-small / lv-on-big pair emits a `within_pod_relocation` proposal.
- T3 proposal is operator-approvable, not auto-executed.
- T4 conservation green (unit-neutral); T5 no oversubscription.

## CLOSE

CHANGELOG + registry; PRD-096 SHIPPED DARK + EXECUTION-LOG (on-delta for CS); commit+push. Rollback = flag off.
