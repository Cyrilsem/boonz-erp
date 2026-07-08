# PRD-097: SWAP guards — R7 hard block, R3 multi-variant, empty-shelf visibility

Status: PARKED 2026-07-09 (rule F: Wave-2 spec drift vs rewritten engine / dependencies; + concurrent engine modification mid-run). NOT shipped. See EXECUTION-LOG.
Owner: CS. Mode: AUTO with hard gates. Dara designs, Cody reviews.

## Why

Three known SWAP-finalize gaps: (S8) the 60% shelf-churn cap **R7** is only _counted_ (`r7_machines_over_60pct`), not blocked — contrary to the docs; (S2) **R3** multi-variant (same SKU on multiple shelves) is not net-flow enforced; (S7) the empty-shelf-after-removal auto-suppress is silent (operator can't see a removal was cancelled).

## Design (Dara designs, Cody reviews)

1. In `engine_finalize_pod` (behind `swap_guards_v1`):
   a. **R7 hard block**: if a machine's swap churn > 60% of slots, block the excess swaps (or require an explicit override tag), not just count.
   b. **R3**: enforce a net-flow check across shelves of the same SKU so combined allocation can't exceed combined WH.
   c. **Empty-shelf visibility**: surface each auto-suppressed removal in the draft output (a `suppressed_removal` list), not silent.
2. Flag off ⇒ R7 counts-only, R3 unenforced, suppression silent (identical).

## Gates

- Flag OFF ⇒ `diff_vs_golden`(golden_v2) IDENTICAL. Flag ON ⇒ capture delta; a >60% machine is blocked/flagged; same-SKU shelves can't exceed combined WH; suppressed removals are surfaced; conservation green. Other Family-A engines byte-identical. Cody signs.

## T-tests

- T1 flag off ⇒ golden_v2 identical.
- T2 flag on ⇒ a machine over 60% churn is blocked or requires override.
- T3 flag on ⇒ same-SKU multi-shelf allocation ≤ combined WH.
- T4 flag on ⇒ suppressed removals appear in the draft output.
- T5 conservation green.

## CLOSE

CHANGELOG + registry; PRD-097 SHIPPED DARK + EXECUTION-LOG (on-delta for CS); commit+push. Rollback = flag off.
