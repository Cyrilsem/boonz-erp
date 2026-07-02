---
id: PRD-UNIFY-CAL
title: Calibrate the unified decision dials (days_cover 10, KEEP floor 0.70, RAMPING 0.60)
status: Draft
owners: { design: Dara, review: Cody, implement: refill-brain + Stax }
protected_entities: [pod_refill_plan]
depends_on: [PRD-UNIFY (compute_refill_decision + engine delegation)]
---

# PRD-UNIFY-CAL — Lock the decision dials to the delta-validated values

## Why

PRD-UNIFY's `compute_refill_decision` shipped with illustrative dials (`days_cover=7`, KEEP floor
0.60, RAMPING floor 0.50). Applied against the live 2026-06-05 plan (129 REFILL/ADD rows) those dials
**cut total refill 375 → 227 units (−40%)**, dominated by **KEEP −92** and **RAMPING −25** — i.e. it
_under-refilled stable and ramping shelves_, the opposite of the documented operator under-refill
complaint (operators keep raising the engine's numbers). This PRD locks the dials to the values that
were measured to fix that, before the engine delegates sizing to the function (PRD-UNIFY Step 3).

## The change (the only thing this PRD does)

Three dial values change; everything else in `compute_refill_decision` (cover_mults, the other floors,
the final-score weights, the WIND DOWN/ROTATE/DEAD drain rule) stays identical.

| Knob                 | Was  | Now      | Why                                                                                       |
| -------------------- | ---- | -------- | ----------------------------------------------------------------------------------------- |
| `days_cover` default | 7    | **10**   | recency-blend velocity (`0.6·v7+0.4·v30`) is lower than v13's v30; 10 days restores cover |
| KEEP `floor_pct`     | 0.60 | **0.70** | KEEP was halved; 0.70 keeps stable sellers near v13                                       |
| RAMPING `floor_pct`  | 0.50 | **0.60** | give ramping products shelf presence without over-pour                                    |

## Evidence (delta vs v13, plan 2026-06-05, 129 REFILL/ADD rows)

| Stance        | v13 units | Untuned (7/0.60/0.50) | Tuned (10/0.70/0.60) |
| ------------- | --------- | --------------------- | -------------------- |
| KEEP          | 194       | 102 (**−92**)         | 168 (**−26**)        |
| RAMPING       | 58        | 33 (−25)              | 42 (−16)             |
| WIND DOWN     | 19        | 0 ✅                  | 0 ✅                 |
| DEAD / ROTATE | 3         | 0 ✅                  | 0 ✅                 |
| DOUBLE DOWN   | 74        | 63                    | 77 (+3)              |
| STAR          | 9         | 14                    | 14                   |
| **TOTAL**     | **375**   | **227 (−40%)**        | **~316 (−16%)**      |

Tuned profile = drains the dead/wind-down (intended), trims steady items slightly, grows the heroes.
That is the correct shape; the untuned −40% was a silent re-tune that would have starved KEEP.

## Dara — schema

None. Pure function-body constant change to `compute_refill_decision` (read-only) + the engine's
delegated call uses `days_cover := 10`.

## Cody — review

**Verdict:** ⚠️ Approve with revisions (Hard Rule 10 — engine touch needs CS green light).

- `compute_refill_decision` is read-only (Article 4 INVOKER) — re-CREATE with the three new constants
  is safe, no behavioral risk beyond the intended numbers.
- The engine (`engine_add_pod`) delegation (PRD-UNIFY Step 3) must pass `days_cover := 10` and is
  **DIFF-GATED vs live**; this is the calibration CS signs off on. After apply, re-run the delta query
  and confirm: WIND DOWN/DEAD still 0, KEEP within ~−15% of v13, total ≥ ~310.

## Acceptance

- A1: `compute_refill_decision(...)` with defaults yields the **Tuned** column above (re-run the
  by-stance delta on 2026-06-05; numbers match within rounding).
- A2: WIND DOWN / ROTATE OUT / DEAD still refill **0** (drain rule intact).
- A3: total refill on the 2026-06-05 plan is ≥ ~310 units (no −40% collapse).
- A4: only three constants changed vs the PRD-UNIFY Step-2 function (diff shows `days_cover` default,
  KEEP floor, RAMPING floor only).

## Open (future, learning loop)

These three values are the starting calibration. The learning loop (`GOAL_learning_loop.md`) will
**propose** refinements from operator-edit history — never auto-apply.
