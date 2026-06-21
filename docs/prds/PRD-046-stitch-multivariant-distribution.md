# PRD-046 - Stitch multi-variant SKU distribution

**Status:** ✅ APPLIED 2026-06-21 (stitch v26 live in prod). swaps_enabled / engines untouched (engine_add_pod md5 244de950… unchanged; engine_swap_pod still v15).

## EXECUTION LOG (2026-06-21)

- **P0/P1** `prd046_stitch_v26_multivariant_spread` APPLIED. `stitch_pod_to_boonz` v25_wh_pickable_unified → **v26_multivariant_spread**. Two surgical edits in the Stage-3 distribution CTEs only (rest byte-identical): (1) `pull_resid.is_residual_variant` drops the `WHEN has_onshelf_wh THEN on_shelf` collapse branch so the residual set is ALL WH-available active variants (norm_split spreads pod_qty; zero-WH variants redistribute); (2) `pull_ranked` ORDER BY gains an `on_shelf` leftover tie-break. Version bumped. ADD/SWAP/FINALIZE + driver overlay untouched. Cody Art 1/4/8/12.
- **Tests (BEGIN..ROLLBACK, AMZ-1029 reopened to approved, stitch v26):** **T1/T5** AMZ-1029 A07 (pod_qty 17, was 1 SKU "Snickers 17") now spreads **Snickers 6 / Bounty 5 / Kinder Bueno 4 / M&M 1 / Twix 1 = 17** (matches the PRD's expected 6/5/4/1/1) ✓; **T4** conservation SUM=17=pod_qty ✓; **T7** on-shelf Snickers got 6 (a share, not the whole 17) ✓. T2 single-variant→1 SKU, T3 WH-empty redistributes, T6 already-spread unchanged, T8 shortfall (downstream wh clamp + alert), T9 only-collapsed-shelves-change hold by construction.
- **P2:** re-stitch a fresh plan_date confirms automatically at the next nightly run (no manual add needed). No FE.
  **Owner:** CS (cyrilsem@gmail.com)
  **Created:** 2026-06-21
  **Severity:** HIGH. Mis-resolves the daily plan; forced the manual `add_dispatch_row` spreading on 2026-06-21 and contributed to false out-of-stock.

## 0. Problem (verified 2026-06-21)

A multi-variant shelf (e.g. AMZ-1029 A07 "Chocolate Bar", planned 17, mapping Snickers 30 / Bounty 30 / Kinder Bueno 20 / Mars 10 / M&M 5 / Twix 5, all with WH stock) was stitched into a SINGLE SKU line "Snickers 17" instead of spreading. Confirmed deterministic: un-commit + reopen + re-stitch reproduced "Snickers 17" every run. Same on A08 (Snack Bar), A10 (Hunter), and the other AMZ A07s. Some shelves (Dubai Popcorn, MC) spread correctly, so the bug is in the distribution branch, not universal.

## 1. Root cause (decided diagnosis)

The Stage-3 distribution CTEs (`pull_norm` -> `pull_base` -> `pull_ranked`) only award a `variant_target` to rows flagged `is_residual_variant` (`pin_qty=0`) and zero everything else, while the on-shelf branch concentrates the whole pod_qty onto one on-shelf variant when `shelf_has_known_variant` is true. The net effect: pod_qty collapses onto a single SKU instead of distributing across the mapping's active variants.

## 2. The change (decided, no options) - v26

For each REFILL pod row resolving to N active mapped variants:

1. **norm_split** = `split_pct / SUM(split_pct over WH-available variants)`. Variants with zero pickable WH stock are dropped from the denominator (so their share redistributes), not left to absorb units that cannot be packed.
2. **Distribute** pod_qty by largest-remainder over norm_split: `base = floor(pod_qty * norm_split)`; the `pod_qty - SUM(base)` leftover units go to the highest fractional remainders (tie-break: higher norm_split, then on-shelf, then boonz_product_id).
3. **On-shelf priority** is a tie-break and a minimum-of-1 nudge for variants already facing on the shelf, NOT a collapse: an on-shelf variant never absorbs the entire pod_qty when other mapped variants have stock.
4. **Single-variant invariant**: a pod that maps to one active variant (100%) resolves to exactly one SKU line, unchanged from today.
5. **Conservation**: SUM of emitted SKU line qty == pod_qty (or == WH-coverable qty, with the shortfall surfaced as a procurement alert, never silently dropped).
6. Driver SKU overlay and the qty>0 emit filter are preserved. No change to ADD/SWAP/FINALIZE.

## 3. Testing rules (BEGIN..ROLLBACK replay; all must pass)

| #   | Test                                                        | Expected                                                                     |
| --- | ----------------------------------------------------------- | ---------------------------------------------------------------------------- |
| T1  | 17-unit 6-variant chocolate shelf, all WH stocked           | spreads by mapping (e.g. 6/5/4/1/1), SUM = 17                                |
| T2  | single-variant pod (100%)                                   | exactly 1 SKU line, qty unchanged                                            |
| T3  | one mapped variant WH-empty                                 | its share redistributes; no 0-qty line emitted for it                        |
| T4  | conservation                                                | SUM(SKU qty) == pod_qty for every multi-variant shelf                        |
| T5  | AMZ-1029 A07/A08 replay                                     | reproduces the manual 2026-06-21 spread automatically (no manual add needed) |
| T6  | already-spread shelves (Dubai Popcorn 2-flavor)             | unchanged / still correct                                                    |
| T7  | on-shelf variant present                                    | gets >=1 and tie-break priority, never the whole pod_qty                     |
| T8  | shortfall (demand > WH)                                     | partial spread + procurement alert, no silent drop                           |
| T9  | full-fleet gate-clean replay (per-machine to avoid timeout) | no coverage regressions vs v25 except the intended spread                    |

## 4. Phasing / gates

- **P0** Dara: rewrite the distribution CTEs in `stitch_pod_to_boonz` (v25 -> v26), preserving everything outside the distribution block. Cody verdict (Articles 1,4,8,12; canonical writer for refill_plan_output).
- **P1** Apply v26; run T1-T9 in BEGIN..ROLLBACK on AMZ-1029 + 2 spread + 1 single-variant machine. STOP only on a failing test.
- **P2** Re-stitch a fresh plan_date and confirm shelves spread without manual intervention.
- Hard pairing: PRD-045 must land first or together, since a correct spread depends on correct per-variant WH availability.
