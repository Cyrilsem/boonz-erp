# PRD-089: ADD absolute velocity floor + min-facing (kill relative-band starvation)

Status: SHIPPED DARK 2026-07-08 (add_abs_floor_v1=off; flag-OFF diff_vs_golden IDENTICAL; Cody PASS; other-3 Family A unchanged). NOT enabled. See EXECUTION-LOG.
Owner: CS. Mode: AUTO with hard gates. Dara designs, Cody reviews, Stax wires FE params.

## Why

`engine_add_pod` sizes with a per-machine `ntile(3)` relative band (band 1 ×1.0, band 2 ×0.60, band 3 ×0.30). Because it is relative, EVERY machine always has a "bottom third" throttled to 30% — even a machine where all shelves sell well. A genuinely healthy shelf gets starved purely for ranking last on its own machine. Add an ABSOLUTE floor so real performers are never throttled, plus a minimum-facing floor so no active selling shelf is under-faced.

## Design (Dara designs, Cody reviews, Stax wires)

1. `refill_policy_params`: add `abs_velocity_floor` (units/day, e.g. 0.5), `min_facing_floor` (units, e.g. 2).
2. In `engine_add_pod`, after `band_fraction` is computed: if `v30/30 >= abs_velocity_floor OR v7 >= abs_velocity_floor` then force `band_fraction := 1.0` (absolute performer, ignore relative band). Ensure `cover_units := GREATEST(cover_units, min_facing_floor)` for shelves with velocity>0, still clamped to `max_stock - current_stock` and `wh_avail`.
3. Gate the whole change on flag `add_abs_floor_v1`; when `off`, code path is byte-equivalent to today (no behavioural change).

## Gates

- **Flag OFF ⇒ `diff_vs_golden` IDENTICAL** (proves inertness) — this is the overnight ship gate.
- Flag ON ⇒ capture plan-delta vs golden via rollback; delta is EXPECTED (band-3 performers rise). Report top changed shelves; conservation green; never exceeds `wh_avail` (no oversubscription). Other Family-A engines md5 byte-identical. Cody signs.

## T-tests

- T1 flag off ⇒ golden identical.
- T2 flag on ⇒ a band-3 shelf with `v30/30 ≥ abs_velocity_floor` gets full cover (delta shows increase, not 0.3×).
- T3 flag on ⇒ every velocity>0 shelf ≥ `min_facing_floor` (clamped to cap/WH).
- T4 conservation green; T5 no shelf exceeds `wh_avail`.

## CLOSE

CHANGELOG + registry; PRD-089 SHIPPED DARK + EXECUTION-LOG with the on-delta report for CS review; commit + push. Enable = CS flips `add_abs_floor_v1=on` after reviewing the delta. Rollback = flag off.
