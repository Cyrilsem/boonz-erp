# PRD-108 — Volume-Driven Size-Up (replace percentile with absolute demand tests)

**Status:** DRAFT — needs calibration pass, then Dara design + Cody review
**Author:** CS via assistant session, 2026-07-29 evening
**Builds on:** PRD-106b (size-up requires DOUBLE DOWN facing, shipped 2026-07-29)

## Problem

The TRUE-HERO size-up gate in `rank_slot_suitability` uses `proven_machine_pctile >= 0.80` — a percentile RELATIVE to the machine. On a zombie machine (15u/week total), the "top 20%" product sells 2-3/week; the gate can propose concentrating shelf space on a product with no real volume, when the zombie's actual problem is footfall/assortment and the right move is exploration with NEW products. Meanwhile the coverage test (full shelf ÷ velocity < trip) is passable by artifact when the existing facing is small (cap 6 at 2.5/wk "can't cover the trip"). Neither test asks the economic question: is a second facing worth more than the best NEW candidate for that shelf?

CS rule (dictated 2026-07-29): size-up must be VOLUME-driven. Star machine with a small shelf churning 40-50/wk → increase capacity, definitively. Zombie machine's local "top seller" at 2-3/wk → never.

## The three absolute tests (replace pctile >= 0.80; keep coverage, blended-bar, and DD flag)

T1. **Absolute velocity floor:** candidate's on-machine velocity >= `sizeup_min_vel_per_day` (proposed 1.0/day ≈ 7/wk). Kills the zombie case outright — volume can only exist where traffic exists, so no explicit machine-tier gate is needed.

T2. **Demonstrated overflow with margin:** demand over the trip interval > full-shelf units × `sizeup_overflow_factor` (proposed 1.25). Upgrade path: measure actual sell-out days (shelf at 0 before refill in trailing 30-60d) × velocity = literal lost sales; use when sell-out telemetry is reliable, fall back to velocity × trip vs capacity.

T3. **Opportunity-cost vs best newcomer:** projected incremental units from the second facing >= `sizeup_vs_alternative_factor` (proposed 1.3) × expected velocity of the rank-1 NON-present candidate for that shelf (its exp_vel = GREATEST(proven, lookalike, global)). A second facing must beat trying something new; on stars it will, on zombies even a weak newcomer wins → exploration happens where it should.

Keep unchanged: `is_present`, coverage test (as T2's fallback form), `NOT is_blended`, **`is_dd` (PRD-106b)** as the human authorization on top. Thresholds live in `refill_policy_params` (new columns), not hardcoded.

## Weekly DD proposal loop (phase 2, optional)

boonz-pico-upstream weekly session: auto-propose DOUBLE DOWN flags for shelves passing T1-T3, CS approves in batch. Engine proposes volume math nightly; human concentrates weekly. Nightly autonomy unchanged (DD still required).

## Calibration pass (MUST run before implementation is specced)

Read-only query over trailing 90d, fleet-wide, machine × pod grain:

- vel_day (on-machine), full_shelf_units (all facings), trip_interval, exp_vel of best non-present size-fit candidate per shelf, sell-out-day count where derivable.
- Emit: which (machine, product) pairs pass T1/T2/T3 at proposed thresholds (1.0/day, 1.25, 1.3) + sensitivity at ±25% on each threshold.
- CS reviews the pass-list against gut feel (expected: OMDCW Al Ain Zero class passes; zombie "heroes" all fail) and fixes thresholds before Dara specs the migration.

## Acceptance

- Zombie replay: machine <=30u/wk total → zero size-up proposals at any shelf, regardless of local percentile or DD flag presence.
- Star replay: small shelf >=40u/wk with overflow → size-up proposed when a DD flag exists, and it outranks the best newcomer in the rationale.
- Rationale jsonb exposes T1/T2/T3 inputs + thresholds used (auditable per decision).
- Thresholds tunable via refill_policy_params without migration.
- pgTAP: T1 floor boundary, T2 margin boundary, T3 comparison incl. missing-lookalike fallback, DD still required.
- Cody review before apply (touches rank_slot_suitability; engine_swap_pod untouched — PRD-094/095 freeze unaffected).
