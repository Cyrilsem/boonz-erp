# PRD-079: Availability gate truth + held-state surfacing

Status: DRAFT 2026-07-07. PRIOR ART SHIPPED — PRD-045 (wh-availability-commitment, 2026-06-21), PRD-036 (pickable-stock + FEFO bind, 2026-07-01), PRD-017 (closed). This PRD does NOT re-implement availability; scope = (a) VERIFY the shipped behaviour under the PRD-076/077 referee, (b) add a **held-state breakdown** so packing shows "held: verify returns" instead of a false zero, (c) unify the pickable predicate into one canonical function reused by engine + packing + PRD-077. Wave 0 / 0b.1.
Owner: CS. Mode: AUTO with hard gates. Dara designs, Cody reviews, Stax wires FE.

## Why

`v_wh_pickable` counts `warehouse_stock > 0 AND NOT quarantined` only. `quarantined` is a generated column (`provenance_reason` NULL / `unknown_pre_migration` / `dispatch_return_unverified`). So real stock (e.g. 38 SF Pancake units all `dispatch_return_unverified`, or consumer-moved units) reads as **0** and packing shows "no stock available." PRD-045/036 committed availability to the plan; the residual is that _held_ stock is invisible rather than labelled. This closes that.

## Design (Dara designs, Cody reviews, Stax wires)

1. **Canonical predicate** `wh_is_pickable(wi, machine_id, today)` = current live rule (status Active, not quarantined, not expired, stock>0, reserved null-or-self). Rewrite `v_wh_pickable` on top of it; point `engine_add_pod.wh_avail` and PRD-077 at the same fn (kill the divergent inline copies).
2. **`v_wh_stock_state`** — per batch expose `pickable_units` + `held_units` by class `{quarantined, pinned_other_machine, inactive, expired, consumer_moved}` (consumer_moved = warehouse_stock=0 AND consumer_stock>0). Reuse `pack_dispatch_line`'s existing bind-fail classes.
3. **Packing availability read** returns `pickable` + `held{by class}` so FE renders "0 pickable · 38 held (verify returns)" (FE render is a Stax follow-up; this PRD ships the data).

## Gates

- **Pickable SET is unchanged** — this is additive representation only. PROOF: PRD-076 `diff_vs_golden` = identical plan output; `engine_add_pod.wh_avail` equals pre-change values on golden inputs. If plan output moves, STOP and park (latent divergence between the two old predicates).
- Engines md5 byte-identical except the `wh_avail` subquery refactor (which must be output-identical). Cody signs. Behind flag `wh_gate_v2`.

## T-tests

- T1 SF Pancake (`fad6df6d-...`) ⇒ 0 pickable, 38 `held.quarantined`.
- T2 pinned-elsewhere batch ⇒ `held.pinned_other_machine`, not pickable.
- T3 consumer-moved ⇒ `held.consumer_moved`, not "no stock".
- T4 `diff_vs_golden` identical (pickable set unchanged).
- T5 conservation gate (PRD-077) green.
- T6 `engine_add_pod.wh_avail` == old values on golden inputs (divergence guard).

## CLOSE

CHANGELOG + RPC/registry; PRD-079 SHIPPED + EXECUTION-LOG; commit + push. Rollback = restore captured view defs + flag off.
