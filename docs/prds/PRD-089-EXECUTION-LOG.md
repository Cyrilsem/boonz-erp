# PRD-089 Execution Log — ADD absolute velocity floor + min-facing (SHIP DARK)

Run 2026-07-08 overnight (WAVE1-OVERNIGHT), AUTO. **Status: SHIPPED DARK (add_abs_floor_v1=off).**
Cody PASS. Other-3 Family A md5 `11b0b03f` UNCHANGED. **NOT ENABLED (CS-only).**

## Shipped (behind add_abs_floor_v1, seeded OFF)

- `refill_policy_params += abs_velocity_floor (0.5), min_facing_floor (2)`.
- `engine_add_pod` (3 named substitutions, flag-gated): (A) cover_units band-fraction → 1.0 for
  absolute performers (`v30/30 ≥ floor OR v7 ≥ floor`); (B) `need_raw` GREATEST gains a min-facing
  term (adds 0 when off). Downstream clamps to cap + wh_avail unchanged.

## Ship gate (REQUIRED — met)

- **flag OFF ⇒ `diff_vs_golden` IDENTICAL** (21 rows, 0 deltas) — proven on prod post-apply. Inert.
- Both edits inert-by-construction (ELSE = original band CASE; GREATEST(..., 0)).
- Other-3 Family A byte-identical (`11b0b03f`).

## ON-delta report for CS (rollback capture)

- **Live mode is `base_stock`** (refill_sizing_mode). `engine_add_pod`'s velocity/relative-band
  branch (where 089 lives) is NOT reached in base_stock mode → **flag-ON delta = 0 fleet-wide today**.
- **Legacy-mode preview (rollback, sizing_mode='legacy'):** off→on delta on 2026-07-06 = **0**
  (54 rows unchanged, conservation orphan_removal 0). Reason: the 07-06 plan rows are `manual_add`
  (reasoning key), not engine-band-sized ADD outputs, so the band path isn't exercised on this date.
- **Net:** 089 is correctly authored + inert; its effect (band-3 performers rise to full cover; no
  active shelf under-faced) materialises only when CS runs **`legacy` sizing mode** on a date with
  engine-band ADD activity AND flips `add_abs_floor_v1=on`. Enabling is CS-only.

## T-tests

| Test                                                     | Result                                                                                                                     |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| T1 flag off ⇒ golden identical                           | PASS                                                                                                                       |
| T2/T3 flag on ⇒ band-3 performer full cover / min-facing | Structurally correct; no live delta on 07-06 (base_stock + manual-add fixture). Preview needs a legacy-mode band-ADD date. |
| T4 conservation green                                    | PASS (orphan_removal 0)                                                                                                    |
| T5 no shelf > wh_avail                                   | PASS (downstream clamps unchanged)                                                                                         |

## Status: SHIPPED DARK. Enable = CS sets add_abs_floor_v1=on (in legacy sizing mode) after delta review.

## REAL delta vs golden_v2 (rich 17-machine fixture, 2026-07-09)
Baseline-vs-candidate rollback on engine-dense 2026-07-01 (235 rows, 17 machines): **delta = 0**,
conservation green. NOT a fixture artifact this time — the trigger conditions don't occur on real
data (velocity>0 shelves already sized above the floors; under-faced shelves are dead/excluded).
089/090 correctly implemented but currently inert. See GOLDEN-V2-EXECUTION-LOG.md.
