# Refill system — master build order (the one sequence)

Each PRD is intentionally scoped to one thing; this is how they chain. Build top-to-bottom — later
layers read what earlier layers write. Status as of 2026-06-05.

## Layer 0 — Foundation (reliability dancefloor)

- **v2 fix batch** (`PRD_refill_v2_fixes.md`, 2026-06-01 migrations) — cron, dedup, REMOVE-to-driver,
  qty cap, subset finalize, reset_and_restitch, commit comment, swaps toggle, void/reschedule,
  swap_pod_refill_row. → mostly files written; confirm applied.
- **FIX-1** (`v_live_shelf_stock` aisle off-by-one) — ✅ **APPLIED & verified** (0/727 drift, 2026-06-05).
  Everything below reads product-per-shelf, so this had to land first. It did.
- **PRD-015** (machine include/exclude toggle, build_draft_for_confirmed, launch gate, unmatched
  alert, pod_inventory reconcile) — ✅ **APPLIED** (2026-05-31). The 16 Plaay shelves reconciled.

## Layer 1 — The brain (compute the right plan) ← BUILD NOW

- **PRD-UNIFY** (`PRD-UNIFY-stance-dosage-scoring.md`, goal `GOAL_unify_scoring.md`) — one blended
  decision (lifecycle = stance, recency = dosage) + a single **Final Score** on the health page;
  retire the competing 💎/PROTECT verdict. **In progress in Claude Code.**
  - Engine change is **surgical**: emit `decision` jsonb + `final_score`, fix WIND DOWN to drain,
    keep v13's existing cover/floor numbers as baseline (do NOT re-tune every multiplier — that's the
    learning loop's job; flag any quantity that would change for CS sign-off).
  - Depends on: FIX-1 (✅).

## Layer 2 — The control surface (let the human act on the plan)

The RD set (`refill-day/`, goal `refill-day/GOAL_refill_day.md`). These edit/extend the plan the
brain produced, so they come **after** PRD-UNIFY — the edit/source/expiry actions should read the
unified `decision`.

- **RD-01** create plan / add machine (no FIX-1 dep)
- **RD-05** expiry-aware product pick (no FIX-1 dep)
- **RD-03** driver self-service (no FIX-1 dep)
- **RD-02** PO-in-refill (needs FIX-1 ✅)
- **RD-04** shelf-to-shelf move (needs FIX-1 ✅)
- **RD-06** per-row source selection (needs FIX-1 ✅)

## Layer 3 — The learning loop (make the brain improve)

- **v2 F7 / FIX-10** (goal `GOAL_learning_loop.md`) — recommendation snapshot, edit signals,
  driver-signal ingest, **bounded** deterministic feedback, weekly systematic-miss report. This is
  where the PRD-UNIFY **open questions** get answered with data (velocity blend `0.6·v7 + 0.4·v30`,
  days_cover, final-score weights) — **propose-only**, CS approves; never auto-tunes the engine.
  Build last — it tunes the Layer-1 dials against operator-corrected history.

## The dependency in one line

FIX-1 ✅ → **PRD-UNIFY (now)** → RD-01/05/03 then RD-02/04/06 → learning loop.

## Why PRD-UNIFY is correctly standalone

It is the _only_ piece that changes how the plan is **computed** and adds the single source of truth
(`compute_refill_decision`). Every Layer-2 action reads that decision; the Layer-3 loop tunes it. If
it were merged into the RD batch it would be impossible to diff-gate the engine cleanly. One focused
build, then the rest chains off it.
