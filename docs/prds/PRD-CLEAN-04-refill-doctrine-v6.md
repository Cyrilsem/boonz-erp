# PRD-CLEAN-04 — Refill Doctrine v6 (one formula, waste-aware)

Status: DONE (2026-07-11) — premise stale: the v15 fill-to-capacity engine no longer
exists; live engine_add_pod v19_base_stock (since 2026-06-22) already implements the
v6 hybrid (base-stock target + 70% seller floor + spoilage cap from real WH shelf
life). Engine rewrite CANCELLED as a regression risk; delivered bible v6 +
deprecation banners on v5_7..v5_10 + invariant battery (0 violations, perishable
cap binding on real dates). Full rationale in DECISIONS.md.
Priority: P1 (resolves the fill-to-capacity vs days-of-cover contradiction)

## Problem

Two contradictory doctrines are simultaneously "canonical":

- BOONZ_REFILL_BRAIN_v3 / bible v5.8 lineage: velocity-based days-of-cover,
  "NEVER blindly refill to max_stock".
- Live engine_add_pod v15 (Refill v2, June 2026): FILL-TO-CAPACITY on every
  selling shelf, warehouse scarcity as the only throttle.
  Fill-to-capacity on slow shelves and perishables manufactures expiry waste.

## Doctrine v6 — the hybrid (CS-approved direction)

Per shelf, grade by machine-local velocity (existing A/B/C/D grading:
A ≥ .5/d, B ≥ .2/d, C > 0, D = dead):

- Grade A/B: fill to capacity → target = max_stock (v2 behaviour kept where it
  is correct: fast shelves cannot overstock relative to demand).
- Grade C: target = LEAST(max_stock,
  GREATEST(CEIL(velocity_30d_daily * cover_days_c), floor_c))
  defaults: cover_days_c = 21, floor_c = 3 (configurable).
- Perishable cap (applies to ALL grades, overrides upward targets):
  target = LEAST(target, CEIL(velocity_30d_daily * shelf_life_days / 2)).
  Never below current sellable stock; qty = GREATEST(target − current, 0).
- Grade D: unchanged (qty 0 + pod_swaps tag; swap engine handles it).
- Ranking/score (final_score, Pearson) stays RANKING-ONLY for WH scarcity
  ordering — it never caps a fill (v2 core principle preserved).
- New-product swap-in minimums unchanged: 6 drinks / 4 snacks, capped at
  slot max.

## Shelf life source

Check `boonz_products` for a shelf-life column
(information_schema.columns first — never guess). If absent, create table
`category_shelf_life(category text PK, shelf_life_days int)` seeded:
dairy/yogurt 21, fresh juice 30, iced coffee 60, cake/bakery 45,
default NULL (= no perishable cap). Resolve per pod product via its dominant
boonz mapping's category.

## Implementation

1. New config columns appended to `pick_urgency_params` (single-row tuner CS
   already live-edits): cover_days_c int DEFAULT 21, floor_c int DEFAULT 3,
   perishable_half_life boolean DEFAULT true.
2. `CREATE OR REPLACE engine_add_pod` (v16). This is a canonical-writer change:
   - Save the current definition to docs/PRDs/rollback/engine_add_pod_v15.sql
     BEFORE replacing.
   - Keep idempotency (clears own pod_refills + dead tags on re-run).
   - Keep clamp_reason values; add 'c_grade_cover_cap' and 'perishable_cap'.
3. Consolidated doctrine doc: write docs/refill_engine_bible_v6.md — the v6
   formula, grading, swap rules, gate model, and an explicit "supersedes
   BOONZ_REFILL_BRAIN_v3.md and refill_engine_bible_v5_8.html" header.
   Add deprecation banners to the old docs (do not delete).

## Verification battery

1. Shadow comparison on a NON-LIVE plan date: run v15 output (captured before
   replace) vs v16 on the same picks. Report per-machine unit deltas.
   Expectation: A/B shelf qtys identical; C/perishable qtys ≤ v15.
2. Invariant battery: R7 60% shelf cap respected; no qty < 0; no qty when
   current ≥ target; runway/procurement_gaps checks pass.
3. NEVER regenerate or touch any plan_date that is stitched/dispatched.
4. `SELECT` sample of 10 perishable shelves shows perishable_cap engaging.
