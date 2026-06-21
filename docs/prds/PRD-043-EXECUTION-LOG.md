# PRD-043 Execution Log — Picker v10 → v11: VOX Wed/Fri calendar gate

**Date:** 2026-06-20 (AUTO MODE) · **Supabase:** eizcexopcuoycuosittm · **Outcome:** P0 + P1 APPLIED to prod.
**NOT flag-gated:** this changes the live pick (the intended fix). Applied because every runnable test passed.
**Invariants held:** `swaps_enabled=false`; `engine_add_pod` byte-identical; no git push.

## Applied objects

| Object                                                              | Migration                                | Applied       |
| ------------------------------------------------------------------- | ---------------------------------------- | ------------- |
| `days_until_next_vox_day(date)` IMMUTABLE helper                    | `prd043_p0_days_until_next_vox_day`      | ✅ 2026-06-20 |
| `pick_machines_for_refill` v10 → **v11** (VOX gate + emergency tag) | `prd043_p1_pick_machines_for_refill_v11` | ✅ 2026-06-20 |

## Decision used: Option B (runway-only emergency override)

VOX excluded from the normal-day primary pick EXCEPT a VOX machine with `runway_days < days_until_next_vox_day(p_plan_date)`, tagged `vox_emergency_offday`, counted vs cap-8. Predicate is runway-only (does not also admit empty_shelves/expired). Two anchored edits: venue gate on `ranked_primary`, tag in the `ordered` CTE. `sibling_ranked`, the VOX-day sweep, and the Saturday guard (PRD-035 WS-E) are unchanged.

## Test results (replay BEGIN..ROLLBACK, both calendar cases)

| #   | Test               | Expected                                                          | Actual                                                                                                                                                                          | Result     |
| --- | ------------------ | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| V1  | non-VOX day strict | no VOX unless emergency-tagged                                    | Sun 21 Jun: vox_total=0, vox_nonemergency_leak=0                                                                                                                                | ✅ PASS    |
| V2  | cap reclaimed      | freed slots → next main-track P1                                  | v10 picked 3 VOX → v11 0 VOX; **3 new main machines** took the cap                                                                                                              | ✅ PASS    |
| V3  | VOX day unchanged  | Wed 24 + Fri 26 byte-identical to v10                             | symmetric diff = **0** both days (11/11 picked)                                                                                                                                 | ✅ PASS    |
| V4  | emergency override | low-runway VOX picked+tagged; ample not                           | **negative PASS** (all 4 VOX runway ≥3.6, none picked). **positive: logic-verified** (predicate 2.0<3=true, 5.0<3=false; tag injected) but NOT live-reproduced — see INCOMPLETE | ⚠️ PARTIAL |
| V5  | cap + siblings     | total ≤8; siblings exclude VOX; siblings ≤ cap                    | total=8; vox_siblings_leak=0; siblings=1                                                                                                                                        | ✅ PASS    |
| V6  | Saturday guard     | 0 pick on Saturday                                                | Sat 27 Jun: 0 picks                                                                                                                                                             | ✅ PASS    |
| R1  | regression         | VOX-day byte-identical; non-VOX main ordering otherwise unchanged | wed/fri diff 0; non-VOX changed only by VOX removal + main backfill                                                                                                             | ✅ PASS    |

## INCOMPLETE for this PRD

- **V4 positive case not live-reproduced (data gap, non-blocking).** No live VOX machine is below its next-vox-day runway threshold (min VOX runway = 3.6d; max usable `days_until_next_vox_day` on a pickable day = 3, Sunday). The override predicate and the `vox_emergency_offday` tag are both verified (synthetic eval: runway 2.0 < 3 → qualifies, 5.0 → not; tag confirmed present in the live function), and V4-negative passes live, so a sub-threshold VOX would be picked + tagged by construction. Applied on that basis. CS may confirm with a real critical-VOX event when one occurs.

## Stale version note (fixed)

Picker live version was v10 (skill/memory said v8/v9). Bumped to **v11**. The live v11 is detectable by `pg_get_functiondef LIKE '%days_until_next_vox_day(p_plan_date)%'` (gate) and `%vox_emergency_offday%` (tag).
