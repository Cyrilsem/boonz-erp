# PRD-039 — Refill v4 Swap: Value-Model Candidate Sourcing, Capacity Fit, and Slot Assignment

Status: Closed 2026-07-02 (PRD-071 sweep). Reason: Phase 0+1 shipped 2026-06-20 (engine_swap_pod v13 + capacity matrix + affinity helper); P2 parked indefinitely, swaps_enabled false. Reopen by deleting this line.
**Owner:** CS (cyrilsem@gmail.com)
**Created:** 2026-06-20
**Depends on:** PRD-037 (engine_swap_pod v12, coexistence_rules, boonz_products.brand_owner, WS-1 helpers \_coexistence_blocks / \_travel_scope_blocks). engine_add_pod v18 stays FROZEN.
**Related guardrail spec (source of truth):** engines/refill/guardrails/coexistence.md, portfolio_strategy.md, layout.md, travel-scope.md.

## 0. Why this PRD exists

PRD-037 v12 Pass-3 implements the value model V(P,S,M) = margin(P) x min(velocity(P,M) x D, cap(S)) and picks by argmax. The 2026-06-20 faithful replay on ADDMIND-1007 (A08 Activia, A14 Perrier, A15 Dubai Popcorn) proved it is guardrail-correct (every pick coexistence-clean, A14 replacement non-TCCC) but exposed three structural limits, all confirmed against live data:

1. **Candidate sourcing is too narrow.** Pass-3 only scores what `find_substitutes_for_shelf` returns, which is a Pearson-affinity / category shortlist. A product that fits and sells well but is not an affinity neighbour never receives a V_cand. This contradicts the PRD-037 WS-1 intent (the candidate universe is every WH-pickable, on-machine-absent, coexistence-clean product) and it double-uses affinity: once as a gate and again as the w3 term in V.

2. **Capacity is the incumbent's, not the candidate's.** Pass-3 reads `cap` from `v_shelf_max_stock` (the slot's observed max under whatever is currently stocked). When it scores a candidate of a different physical size, it caps the value at the incumbent's count. Concrete failure: Be-kind Bar evaluated for A15 (Dubai Popcorn, observed max 6) is capped at 6, although far more thin bars physically fit; a bulky product in a 21-slot is over-credited. There is **no physical_type x shelf_size capacity matrix in the database today** (verified 2026-06-20: `slot_capacity_max` is a per-aisle manual override table of shape `(id, machine_id, aisle_code, override_max_stock, reason)`, not the matrix PRD-037 §2 assumed). So this must be built.

3. **Per-slot argmax plus greedy dedup can be globally suboptimal.** Two slots on one machine both argmax the same product (A08 and A15 both -> Be-kind Bar). The PRD-037 interim fix was a one-line worst-first greedy dedup; the principled solution is top-N per slot then a unique assignment that maximises total machine value.

A fourth concern follows from point 1: a pure value-max over the whole catalogue tends to converge the fleet onto a handful of high-margin SKUs (homogenisation). CS decision 2026-06-20: broaden the universe but add a homogenisation guard.

## 1. What changes / what stays

| Component                                     | Action                                                                             |
| --------------------------------------------- | ---------------------------------------------------------------------------------- |
| `engine_add_pod` v18                          | FROZEN. Byte-identical (regression T12).                                           |
| `engine_swap_pod` Pass-3                      | REWRITTEN per this PRD (candidate universe, capacity, assignment, homogenisation). |
| `engine_swap_pod` Pass 1 / dead-tag / Pass 2b | unchanged.                                                                         |
| `_coexistence_blocks`, `_travel_scope_blocks` | reused unchanged (PRD-037).                                                        |
| coexistence_rules, brand_owner                | reused unchanged (PRD-037 Phase 0).                                                |
| The v12 one-line Pass-3 dedup guard           | superseded by WS-C (kept harmless until this lands).                               |
| `refill_settings.swaps_enabled`               | stays `false`.                                                                     |

## 2. Data prerequisites (Dara designs, Cody verdicts)

| Need                                                       | Status                   | Note                                                                                                                                                                                                                                                                                                                                                    |
| ---------------------------------------------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| capacity matrix `(physical_type, shelf_size) -> max_units` | MISSING, build it        | New reference table (e.g. `product_slot_capacity`). Seed from layout.md §4, or derive from observed max-per (physical_type, shelf_size) across live planograms, whichever CS prefers. x0.85 fill factor applied in-engine.                                                                                                                              |
| candidate-specific cap resolution                          | derive                   | cap(S, candidate) = floor(matrix[candidate.physical_type][shelf.shelf_size] x 0.85), overridden by `slot_capacity_max.override_max_stock` when a row exists for the machine/aisle, fallback to `shelf_configurations.max_capacity`.                                                                                                                     |
| reusable affinity score                                    | MISSING, build it        | Today Pearson lives only inside `find_substitutes_for_shelf`. Build a scoring-only affinity helper (function or view) that returns a co-purchase / Pearson score for an arbitrary candidate vs a machine basket, so the broad universe can carry the w3 term. Alternative: refactor `find_substitutes_for_shelf` to expose a no-shortlist scoring mode. |
| broad universe source                                      | EXISTS                   | `v_wh_pickable` (columns: wh_inventory_id, boonz_product_id, warehouse_id, warehouse_stock, expiration_date, reserved_for_machine_id, snapshot_date). Filter stock>0, expiry ok, reservation null-or-this-machine.                                                                                                                                      |
| physical_type                                              | EXISTS on boonz_products | 14 values today: bag_large, bag_snack, bar_standard, bottle_330, bottle_500, bottle_large, box_biscuit, cake_wrapped, can_250, can_330, cup_yogurt, date_ball, other, pack_gum.                                                                                                                                                                         |
| product_family_id                                          | NULL fleet-wide (0/307)  | Rule 2 (max-1-per-family) stays brand-proxied via coexistence_rules until backfilled. Out of scope here.                                                                                                                                                                                                                                                |

## 3. Workstreams

**WS-A Broad candidate universe (replaces the find_substitutes gate).** A candidate is any boonz product that is: in `v_wh_pickable` with warehouse_stock above a seed minimum and not expired and reservation-clean; NOT already on machine M; coexistence-clean vs every on-machine product via `_coexistence_blocks`; not travel-scope-locked via `_travel_scope_blocks`; not in the 30-day introduction cooldown; not a suppressed swap-in (3x rejected). Pearson affinity becomes the w3 term only (via the new affinity helper), never a gate. WS-2 projected velocity is unchanged: `w_sister*sister_velocity + w_global*global_velocity + w_pearson*pearson*global_velocity`, weights 0.5 / 0.3 / 0.2.

**WS-B Candidate-specific capacity.** `cap(S, candidate) = floor(capacity_matrix[candidate.physical_type][shelf.shelf_size] x 0.85)`, with `slot_capacity_max.override_max_stock` taking precedence when present and `shelf_configurations.max_capacity` as the final fallback. V uses this candidate-specific cap in `min(velocity x D, cap)`. The incumbent KEEP value uses the incumbent's own cap by the same rule.

**WS-C Top-N plus unique assignment.** For each machine, for every Pass-3-eligible slot (band 3, dead/rotate worst-first as today), compute the top-N candidates by V. Then assign products to slots to maximise total machine V with each boonz product used at most once per machine per cycle. Start with greedy-by-marginal-value (assign the single highest V(slot, product) pair, remove both, repeat); upgrade to a Hungarian-style optimum only if the replay shows greedy leaves value on the table. Respect the existing rate limits (<= p_max_swaps_per_machine, 14-day slot cooldown). Supersedes the v12 one-line dedup.

**WS-D Homogenisation guard.** A single boonz product may be newly introduced into at most K machines per cycle (seed K, tune in replay) and at most one slot per machine. Enforced at the assignment / fleet-cap stage alongside the existing fleet `<= 10` swap cap. Prevents value-max from converging the fleet onto a few high-margin SKUs.

## 4. Conditional tests (acceptance, all in BEGIN..ROLLBACK with swaps_enabled forced true)

| #   | Test                           | Expected                                                                                                                                                              |
| --- | ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| U1  | Broad universe reachability    | a high-V product that is NOT in `find_substitutes_for_shelf` output for the slot is reachable and can win the slot.                                                   |
| U2  | Affinity is a term, not a gate | a high-V product with low/zero Pearson is NOT excluded; Pearson only shifts ranking where co-purchase signal exists. No double-count.                                 |
| C1  | Capacity fit                   | candidate cap uses its own physical_type x shelf_size; Be-kind Bar in the A15 popcorn slot is not capped at 6; a bulky product in a 21-slot is capped to its own fit. |
| C2  | Cap override respected         | when `slot_capacity_max.override_max_stock` exists for the machine/aisle, it wins over the matrix.                                                                    |
| A1  | Uniqueness                     | no boonz product proposed into two slots on one machine in a cycle.                                                                                                   |
| A2  | Assignment optimality          | top-N + assignment total machine V >= greedy-worst-first total V on the ADDMIND-1007 fixture (A08/A14/A15).                                                           |
| H1  | Homogenisation                 | one product cannot be newly introduced into more than K machines in one cycle; fleet cap <= 10 still holds.                                                           |
| R1  | PRD-037 regression             | T1-T7, T10-T13 (re-scoped) still pass; T7 kill switch yields 0; T12 ADD output byte-identical.                                                                        |

## 5. Phasing

- **P0 (Dara + Cody):** build the capacity matrix table + the affinity helper. Migrations author-only.
- **P1 (engine):** rewrite Pass-3 with WS-A/B/C/D. Replay U1, U2, C1, C2, A1, A2, H1 + the PRD-037 regression R1. `swaps_enabled` stays false.
- **P2 (enable, later):** flip `swaps_enabled` true only after N supervised cycles of clean proposals on `/refill`. Same gate as PRD-037 Phase 3.

## 6. Guardrail-to-code map

| Logic                                           | Lives in                        | Wired by                      |
| ----------------------------------------------- | ------------------------------- | ----------------------------- |
| Capacity by physical_type x size, 0.85 fill     | layout.md §4                    | WS-B (new capacity matrix)    |
| TCCC exclusion, coexistence matrix, travel lock | coexistence.md, travel-scope.md | WS-A (reuses PRD-037 helpers) |
| Rate limits, fleet cap, homogenisation          | portfolio_strategy.md §9        | WS-C, WS-D                    |

## 7. Open follow-ups

1. Backfill `product_family_id` so Rule 2 becomes family-keyed instead of brand-proxied.
2. True gross-profit margin (PRD-037 follow-up) once cost coverage is complete.
3. 70/30 core/flex enforcement = PRD-038.
4. `swaps_enabled` stays OFF until P2 sign-off.
