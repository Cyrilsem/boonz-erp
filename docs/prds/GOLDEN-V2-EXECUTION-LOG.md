# golden_v2 fixture + Wave-1 REAL re-preview — Execution Log

Run 2026-07-09 overnight, AUTO. Phase 0 (build golden_v2) + Phase 1 (Wave-1 real deltas).

## Phase 0 — golden_v2 (built, additive; golden_v1 untouched)
- **Method:** frozen read-only snapshot of the committed engine-dense plan for **2026-07-01**
  (146 active/stitched rows, 9 machines in-snapshot; 17 machines on a full re-run). Chosen because
  re-running a historical date via build_draft would supersede its plan + churn slot_lifecycle
  (unsafe); freezing the committed plan is safe. `label='golden_v2'`, conservation verdict stored.
- **Composition:** actions ADD_NEW:18 / REFILL:113 / REMOVE:15 (exercises ADD **and** swap/rotate
  activity). Conservation baseline: orphan_removal 24 (retrospective past-plan-vs-current-stock
  artifact — same class as PRD-077), phantom 0, oversub 0.
- **Delta method (drift-free):** a rollback re-run of 07-01 reproduces the plan richly (235 rows,
  17 machines) and is **largely deterministic** (146/146 golden rows reproduced, 11 action drift).
  So per-flag deltas use **baseline(all-off) vs candidate(flag-on) in ONE rollback** on 07-01 —
  same inputs, same instant → isolated flag effect. (`diff_vs_golden('golden_v2')` alone would
  show ~11 rows of engine drift, not flag effect; baseline-vs-candidate removes it.)

## Phase 1 — Wave-1 REAL deltas vs golden_v2 (rich fixture; NO enable)
| PRD | Flag | REAL delta (07-01, 17 machines) | Finding |
|---|---|---|---|
| 089 abs-floor + min-facing | add_abs_floor_v1 | **0** (base_stock AND legacy) | Floors don't bind: the 10 qty=1 shelves are DEAD (v7=0,v30=0), which 089 *correctly* excludes; velocity>0 shelves are already sized ≥2. Band-fraction is base_stock-bypassed. |
| 090 niche fill | add_niche_fill_v1 | **0** | 10 niche pods present, but their best-location facings already meet/exceed the 0.8×cap floor; the floor doesn't raise any row. |
| 091 expiry input | (parked) | **0** (not built) | parked (representation + conservation) |
| 092 no-WH action | (parked) | **0** (not built) | parked |
| 093 consignment | consignment_v1 | **0** (Part B not built) | columns inert; engine gating parked |

**Corrected conclusion (supersedes the earlier "fixture artifact" note):** on a RICH, real,
engine-dense 17-machine plan, 089 and 090 still move **zero** rows — not because the fixture is
blind, but because **their trigger conditions do not occur on current data**: the engine already
sizes velocity>0 shelves at or above the min-facing/niche floors, and the only under-faced shelves
are dead (correctly excluded). **For CS:** 089/090 are correctly implemented but currently inert;
enabling them changes nothing today. If the intent is to lift specific shelves, the thresholds
(min_facing_floor, abs_velocity_floor, niche_facing_target) likely need tuning to a binding range,
or the target scenario (legacy band-3 throttling) needs to actually occur. No enable warranted yet.
