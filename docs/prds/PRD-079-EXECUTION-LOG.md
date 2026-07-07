# PRD-079 Execution Log — Availability + held-state

Run 2026-07-07 overnight, AUTO. **Status: SHIPPED (Part A held-state layer); Part B engine
unification PARKED.** Family A md5 `8587be9a` UNCHANGED. Additive read-only → cody fast-path.

## Shipped (Part A — additive, safe)
- `wh_is_pickable(wh_inventory_id, machine_id?, today?)` — canonical WH pickability predicate
  (Active + not-quarantined + in-date + stock>0 + reservation NULL-or-mine). **0-mismatch
  parity** with `v_wh_pickable` membership across the fleet.
- `v_wh_stock_state` — per-batch `pickable_units` + `held_class`
  (quarantined/inactive/expired/pinned_other_machine/consumer_moved). Current fleet:
  quarantined 844 / inactive 454 / consumer_moved 3 / available 203.

## Parked (Part B — engine unification, wh_gate_v2)
Refactoring `v_wh_pickable` + `engine_add_pod.wh_avail` onto `wh_is_pickable` is NOT shipped.
`engine_add_pod` computes `wh_avail` via its own inline CTE (a divergent copy). The pre-seeded
Dara+CS guidance is explicit: engine_add_pod.wh_avail may shift when the predicate is unified
(T6) → do NOT ship; investigate the historical divergence first. The goal's own rule: "ANY
shift → PARK the unification (keep held-view shipped)." Blind Family-A surgery against
investigate-first guidance would be forcing. PARKED for Dara.

## Envelope (Part A)
Additive, reversible (drop fn/view), Family A byte-identical, `v_wh_pickable` untouched,
read-only (no protected write). Article 16 canonicalization.

## Status: SHIPPED (Part A). Part B (engine_add_pod/v_wh_pickable unification) parked → Dara.
