---
id: PRD-005
title: Swap engine picks wrong shelf when a better-stocked alternative exists
status: Blocked
severity: P2
reported: 2026-05-21
source: Refill update 21-05-2026 — OMDCW-1021 Hunter / Plaay swap
routing: [refill-brain]
protected_entities: [refill_plan_output]
blocked_reason: |
  Fix lives in engine_swap_pod / propose_swap_plan body (in live DB). Per
  RPC_REGISTRY, swap selection uses Pearson via get_similar_products + category
  fallback; shelf selection is implicit from pod_inventory.shelf_id of the
  decommission target. The "ignores better-stocked alternative" symptom suggests
  the substitute scorer isn't weighting destination shelf stock state — a
  scoring-tweak inside the RPC body. Needs RPC source + live data to validate fix.
---

# PRD-005 — Swap engine picks wrong shelf when a better-stocked alternative exists

## Problem

On 2026-05-21 at OMDCW-1021, ENGINE SWAP recommended replacing the product on shelf A12 with Plaay, swapping out Hunter. But Hunter availability on shelf A13 was higher than on A12 — A13 was the better candidate for the swap-out (or for redistribution). The driver corrected on the ground and returned 1 unit.

The swap engine appears to evaluate one shelf at a time without considering whether the same boonz_product appears on multiple shelves at the same machine, and picking the optimal slot to act on.

## Observed behaviour

- Machine: OMDCW-1021
- Engine instruction: swap Hunter (on A12) for Plaay
- Reality: A13 had more Hunter — should have been the swap-out target
- Driver outcome: only 1 unit returned instead of full swap; engine intent partially defeated

## Expected behaviour

When ENGINE SWAP decides "swap product X for product Y at machine M," and X exists on multiple shelves at M, the engine must pick the shelf that produces the best post-swap configuration. Heuristic candidates:

- Pick the shelf with the **highest current stock of X** (greater swap impact)
- OR pick the shelf with the **lowest velocity** for X (least cost to retire from)
- OR pick the shelf that places Y next to its category neighbours

The current behaviour suggests the engine grabs the first matching shelf row by ordering — likely by slot_code ASC, hence A12 before A13.

## Hypothesis on root cause

ENGINE SWAP (Stage 2b — Pass 1 strategic, Pass 2 autonomous Pearson per refill-brain skill) selects the swap-out slot deterministically by slot ordering rather than by a scoring function. A scoring function on (current_qty, velocity, neighbour fit) would naturally prefer A13.

This is purely logic in the refill brain — no schema or RLS implications.

## Scope

In scope:

- `engine_swap_pod` Pass 2 (autonomous Pearson) slot selection logic
- Optional: same scoring applied to Pass 1 (strategic_machine_tags) — needs CS decision

Out of scope:

- Adding new placement heuristics beyond the three named above
- Restructuring the swap pipeline architecture

## Protected entities touched

`refill_plan_output` (write target). No schema changes expected. Cody review still required for any RPC edit.

## Acceptance criteria

- [ ] Synthetic test: machine M has product X on slots S1 (qty 2) and S2 (qty 8) — swap decision picks S2 for swap-out
- [ ] Decision-trace log row written so the swap reasoning is auditable per shelf
- [ ] OMDCW-1021 case: re-run brain produces the A13 selection
- [ ] No regression on existing swap test scenarios

## Edge cases (all must verify before marking Done)

- **Product X on only one shelf:** skip scorer, use that shelf, log "single-shelf swap".
- **Two shelves tied on primary blended score (within 10%):** Pearson neighbour-fit tiebreaker invoked per Decisions.
- **All shelves below Pearson threshold-10:** fall back to retire-cost only, log "no correlation signal".
- **Velocity = 0 for X everywhere:** treat as max retire incentive (X is dead — every shelf is a good retire candidate).
- **Family has one variant:** family-aggregate path degenerates to single-SKU path cleanly (no NaN, no crash).
- **Strategic_machine_tags (Pass 1) covers the swap:** Pass 1 wins per existing refill-brain rules; this PRD's scoring applies only to Pass 2 autonomous Pearson.
- **Swap with self (X == Y):** rejected at engine level (guardrail already exists in refill-brain — confirm not regressed).

## Verification

- [ ] `npx tsc --noEmit`, `npm run build`, `npm run lint`
- [ ] Unit test on `engine_swap_pod` slot scorer
- [ ] Replay against the last 7 days of refill plans — diff old vs new shelf selection per swap; review with CS
- [ ] Cody review

## Decisions

- **Canonical heuristic:** WEIGHTED BLEND. 60% weight on "highest current stock of X" (maximises swap impact — retiring from the fullest shelf clears the most underperformer inventory), 40% weight on "lowest velocity of X at that shelf" (retire from where it's hurting most). Both are normalized 0–1 against the machine's own range, then summed. This balances impact and risk in a way pure-rank heuristics don't.
- **Multi-variant retirement:** FAMILY AGGREGATE for the shelf decision, VARIANT level for the execution. Pick the shelf with the highest aggregate Hunter stock to act on, then within that shelf retire the variant with the highest qty × lowest velocity. Mirrors how a retail planner actually decides.
- **Pearson neighbour fit on introduction side:** YES, but as a TIEBREAKER ONLY. If the primary score (retire-cost) yields two or more shelves within 10% of each other, pick the shelf where introducing Y has the highest Pearson correlation with adjacent products. Avoids overweighting Pearson on noisy SKUs (consistent with the calibrated threshold-10 logic in refill-brain).

## Linked PRDs

- [[PRD-004-engine-fills-full-shelf]] — sibling engine accuracy issue at the same machine
