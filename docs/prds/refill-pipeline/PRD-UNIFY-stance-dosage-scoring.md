---
id: PRD-UNIFY
title: One refill decision — lifecycle sets the stance, recency sets the dosage (retire the competing health verdict)
status: Draft
owners: { design: Dara, review: Cody, implement: Stax, engine: refill-brain }
protected_entities: [pod_refill_plan, refill_plan_output]
related:
  - mv_global_product_scores (health: 💎/👑 base_score = 4·u7d + 0.5·u15d)
  - v_product_lifecycle_global_enriched (lifecycle: score + trend + signal)
  - compute_strategy / compute_local_strategy / get_machine_slots_with_expiry (the competing display verdict)
  - engine_add_pod v11 (already blends signal-floor + cover×velocity — PRD-010 AC#1/#3, engine v8 runway gate)
---

# PRD-UNIFY — One decision: lifecycle = stance, recency = dosage

## Problem

Two scoring systems run in parallel and **contradict each other on real products**:

- **Lifecycle engine** (`v_product_lifecycle_*.signal`, on 30-day velocity + trend): the structural /
  directional view → DOUBLE DOWN / KEEP / WIND DOWN / ROTATE OUT. **This is what `engine_add_pod`
  actually consumes** to write the refill.
- **Health engine** (`mv_global_product_scores.base_score = 4·units_7d + 0.5·units_15d` → 💎 Global
  Hero / 👑 Local Hero → PROTECT/SUSTAIN, surfaced by `get_machine_slots_with_expiry` + `compute_strategy`):
  the recency view, shown on the **machine card** — with its own "fill-to-max" target.

They disagree because one is **structural/30-day** and the other is **recency/7-day**. Verified
2026-06-05:

| Product                  | Lifecycle (engine acts) | Health (card shows)       | The clash                        |
| ------------------------ | ----------------------- | ------------------------- | -------------------------------- |
| Organic Larder Rice Cake | **WIND DOWN** (5.60)    | **💎 Global Hero**        | card says protect; engine drains |
| Gatorade                 | **DOUBLE DOWN** (8.69)  | **📦 Core Range**         | card says meh; engine grows      |
| Vitamin Well             | **KEEP** (6.81)         | **💎 → PROTECT, fill 16** | card over-pours a steady item    |

The operator sees one brain on screen and a different brain writes the plan. That is the confusion
and the "two brains" of the 2026-06-05 post-mortem.

## The model: stance × dosage (both are inputs to ONE decision)

They answer different questions, so we use both — but as **inputs, not competing verdicts**:

- **Lifecycle = the STANCE.** It decides direction and the ceiling: grow / maintain / drain / exit,
  plus a visual-fill floor. (Structural — won't be fooled by a one-week blip.)
- **Recency velocity = the DOSAGE.** It decides how many units this cycle and how urgent the visit
  is. (Reactive — catches what's moving now.)
- **Health percentile (💎/👑)** is demoted from a verdict to a **badge + priority tiebreaker** — it no
  longer produces its own target.

### The canonical decision (per shelf = machine × product)

```
stance         = lifecycle signal            -- from v_product_lifecycle (local scope preferred)
cover_mult      = COVER[stance]               -- see table
floor_pct       = FLOOR[stance]               -- see table  (visibility for growth products)
velocity        = recency-weighted daily rate -- the dosage (calibration: see Open Q1)
days_cover      = 10 (default)                 -- PRD-UNIFY-CAL (delta-validated vs the illustrative 7)

velocity_target = velocity × days_cover × cover_mult
visual_target   = floor_pct × shelf_capacity
target_units    = LEAST( GREATEST(velocity_target, visual_target), shelf_capacity )
                  -- EXCEPT WIND DOWN / ROTATE OUT / DEAD: target_units ≤ current_stock (drain; never refill up)
refill_qty      = GREATEST(target_units − current_stock, 0)

runway_days     = current_stock / NULLIF(velocity,0)   -- → picker priority (lower = visit sooner)
```

### The dials (lifecycle signal → stance), reconciled with engine v11 / PRD-010

| Lifecycle signal  | Stance    | cover_mult | floor_pct | Intent                           |
| ----------------- | --------- | ---------- | --------- | -------------------------------- |
| STAR              | grow hard | 2.0        | 0.80      | hero, keep full                  |
| DOUBLE DOWN       | grow      | 1.5        | 0.80      | rising, push visibility          |
| KEEP GROWING      | nurture   | 1.0        | 0.70      | good trajectory                  |
| KEEP              | maintain  | 1.0        | 0.70      | stable; velocity-led (UNIFY-CAL) |
| RAMPING           | seed      | 1.0        | 0.60      | new, shelf presence (UNIFY-CAL)  |
| WATCH             | hold      | 1.0        | 0.40      | under observation                |
| WIND DOWN         | drain     | 1.0        | 0.00      | velocity only, no top-up to full |
| ROTATE OUT / DEAD | exit      | 0          | 0.00      | no refill; swap-out candidate    |

The growth signals (STAR/DOUBLE DOWN) lean on the **floor** (visibility drives trial even at low
velocity → Gatorade gets shelf presence but the cap stops a dump). The steady signals (KEEP/WATCH)
lean on **velocity** (don't over-pour a stable item → Vitamin Well fills to a sensible level, not max).
This is exactly the tension; the floor-vs-velocity split per stance is the resolution.

## The FINAL SCORE (the health-page column)

The health page must show **one final, blended score per product per machine** that reflects the same
decision — so the screen ranks products the way the engine does. It is the existing per-row demand
number (`base_score`), now **modulated by stance + global/local placement + urgency** instead of
standing alone. Column order on the card: **Global · Local · 7d Sales · Stance · Final Score**.

```
demand_base   = 4·units_7d_slot + 0.5·units_15d_slot          -- the recency dosage (today's "Score")
stance_mult   = STANCE_W[stance]                              -- STAR/DOUBLE DOWN 1.5 · KEEP GROWING 1.2 ·
                                                              --   KEEP 1.0 · WATCH 0.8 · WIND DOWN 0.4 ·
                                                              --   ROTATE OUT/DEAD 0.1
placement_mult= global_w × local_w                            -- 💎 1.20 / 📦 1.00 / 🔻 0.80
                                                              --   × 👑 1.20 / ✅ 1.00 / 🐕 0.70 / 💀 0.30
urgency_mult  = 1 + LEAST(0.5, GREATEST(0, (target_days − runway_days)/target_days))
                                                              -- near-empty heroes float up; full shelves don't

final_score   = ROUND( demand_base × stance_mult × placement_mult × urgency_mult , 1)
```

So a WIND DOWN product with great recent sales (Rice Cake) gets its final score **knocked down** (×0.4)
even with a 💎 badge — it stops topping the list. A near-empty 💎/👑 hero (Zigi 0/8) **floats up** via
urgency even on modest 7d sales. The score is transparent: the card shows the four inputs and the one
number, and `final_score` is the same value the picker/engine uses to prioritise the shelf — one brain.
The weights `STANCE_W`, `global_w`, `local_w` are calibration knobs (Open Q5).

## Worked resolutions (days_cover = 7)

- **Vitamin Well @ AMZ A16** — KEEP, cap 16, velocity ≈ 0.7/day. velocity_target ≈ 5; visual_target =
  0.60×16 ≈ 10 → **target 10, refill 2** (vs the card's old "fill to 16"). Steady item, sensibly filled.
- **Rice Cake** — WIND DOWN → drain → **refill 0**, flagged swap-out — even though health says 💎.
  Stance wins direction; recency only stops an abrupt yank.
- **Gatorade** — DOUBLE DOWN, cap ~12, velocity low. visual_target = 0.80×12 ≈ 10 → grow to ~10 for
  visibility, **capped** so it's a ramp, not a 12-unit dump. Health's 📦 caps over-pour.

Each is the answer neither engine gives alone.

## Dara — schema design

The engine already computes most of this; we make the decision **explicit and shared** so the card
reads the same numbers the engine writes.

```sql
-- 1) Persist the decision components on the draft row (so the card + diff read the engine's truth)
ALTER TABLE public.pod_refill_plan
  ADD COLUMN IF NOT EXISTS decision jsonb;   -- {stance, cover_mult, floor_pct, velocity, days_cover,
                                             --  velocity_target, visual_target, target_units, runway_days,
                                             --  global_badge, local_badge, units_7d, final_score, reasoning}
COMMENT ON COLUMN public.pod_refill_plan.decision IS
  'PRD-UNIFY: the single blended refill decision. Lifecycle stance + recency dosage. The machine card renders this; no competing verdict.';

-- 2) ONE shared function both the engine and the display call (single source of truth)
--    compute_refill_decision(machine_id, shelf_id, boonz_product_id, days_cover) RETURNS jsonb
--    (read-only / STABLE; the engine uses it to set qty, the card uses it to render.)
```

Tradeoff: store the decision jsonb on the row (auditable, diffable, the card reads it for committed
plans) AND expose `compute_refill_decision(...)` for live/preview rendering. Rejected: recompute
independently in the card (that's how we got two brains). Cody handoff: Articles 1, 4, 8, 12, 14.

## Cody — constitutional review (design verdict)

**Verdict:** ⚠️ Approve with revisions.
**Articles:** 1 (the decision is written only by the engine writer / `compute_refill_decision`; the
card never computes its own target — this _removes_ the second authority, which is the whole point),
4 (engine writer change sets GUCs/role/validation; `compute_refill_decision` is read-only INVOKER),
8 (decision persisted on pod_refill_plan → audited), 12 (forward-only; the `engine_add_pod` change is
a calibration of the existing per-signal math, **diff-gated vs live** — Hard Rule 10, second rewrite
needs CS green light + diff review), 14 (no parallel table; evolve pod_refill_plan + retire the
display fork).
**Revisions / rulings:**

- (a) **ENGINE CHANGE IS SURGICAL — DO NOT RE-TUNE.** `engine_add_pod` is live at **v13** with its own
  cover/floor numbers. This PR may ONLY: (1) **emit** the `decision` jsonb + `final_score`; (2) **fix
  WIND DOWN** to drain (`target ≤ current`, never refill up — the Rice Cake bug); (3) keep v13's
  existing `cover_mult`/`floor_pct` numbers as the baseline. The dials table above is the _intended
  direction_, NOT a re-tune instruction — re-tuning every multiplier moves quantities fleet-wide and
  is the **learning loop's** job (Layer 3). **If any shelf's `target_units` would change vs current
  v13 output (other than WIND DOWN now draining), STOP and list those rows for CS sign-off before
  applying.** Diff-gate the whole function vs live; surface only those deltas.
- (b) `compute_strategy`/`compute_local_strategy`'s "fill-to-max" target in `get_machine_slots_with_expiry`
  must be **retired as a target source** — the card reads `decision` / `compute_refill_decision`. The
  💎/👑 labels may remain as a **badge** (display only) and a picker tiebreaker, never as a quantity.
- (c) `pick_machines_for_refill` priority may use `runway_days` + the health badge as a tiebreaker;
  no change to its canonical write path.

## Stax — FE / wiring

**Files:** `engines/refill` engine writer (calibrate per the dials table + emit `decision` incl.
`final_score`); `get_machine_slots_with_expiry` (return the engine `decision` + `final_score` instead
of its own `base_score`/target; keep 💎/👑 as badges); the **machine health page** (the screenshot)
and `RefillPlanningTab.tsx`.
**Health-page column change (this screenshot):** replace the standalone `Strategy` (PROTECT/SUSTAIN)
and `Score` columns with the unified set, in this order:
**Slot · Product · Stock · Fill · Global (💎/📦/🔻) · Local (👑/✅/🐕/💀) · 7d Sales · Stance
(DOUBLE DOWN/KEEP/WIND DOWN…) · Final Score · Suggestion · Exp.** The row sorts by `Final Score` desc
by default; `Final Score` is `decision.final_score`. Hovering it shows the breakdown
(`demand_base × stance_mult × placement_mult × urgency_mult`).
Rules: S1 (decision via RPC/engine only), S2, S9. Cody handoff: confirm the card no longer calls
`compute_strategy` for a target _or_ a score; confirm one `compute_refill_decision` is the only
source of both `target_units` and `final_score`.

## Edge cases (tested)

| #   | Case                                          | Expected                                                                                |
| --- | --------------------------------------------- | --------------------------------------------------------------------------------------- |
| E1  | Lifecycle WIND DOWN but health 💎 (Rice Cake) | stance wins: drain, refill 0, swap-out flag; badge still shows 💎                       |
| E2  | DOUBLE DOWN but tiny velocity (Gatorade)      | grow via floor, capped at capacity; no over-pour                                        |
| E3  | KEEP + hot recent week (Vitamin Well)         | velocity-led target, not fill-to-max; card shows the same number                        |
| E4  | velocity = 0 (no recent sales)                | velocity_target 0; floor still applies for grow stances; runway = ∞ (low priority)      |
| E5  | ROTATE OUT / DEAD                             | refill 0 always; never a positive qty regardless of recency                             |
| E6  | capacity < target                             | clamp to capacity; never exceed shelf                                                   |
| E7  | lifecycle signal missing (new product)        | default stance KEEP + RAMPING floor; flagged for review                                 |
| E8  | card vs engine number mismatch                | impossible by construction — both read the same `decision`; a CI check asserts equality |

## Acceptance tests

- A1: for every draft row, the machine card target == `pod_refill_plan.decision.target_units` (no divergence).
- A2: Rice Cake (WIND DOWN) → refill_qty 0 even when health badge = 💎.
- A3: Gatorade (DOUBLE DOWN, low velocity) → target ≤ capacity, > current, reasonable ramp (not a dump).
- A4: Vitamin Well (KEEP) → target is velocity/floor-led, strictly < fill-to-max.
- A5: `compute_strategy` no longer produces a quantity anywhere (grep: no target from the strategy path).
- A6: `engine_add_pod` diff vs live shows only the dials-table calibration + `decision` emission.
- A7: picker priority orders by runway_days asc, health badge as tiebreaker.
- A8: the health page shows the columns Global · Local · 7d Sales · Stance · **Final Score** (no
  standalone PROTECT/SUSTAIN Strategy column, no separate base_score Score); rows sort by Final Score.
- A9: Rice Cake (WIND DOWN, 💎) Final Score is pushed DOWN the list (×0.4 stance) despite the 💎 badge.
- A10: a near-empty 💎/👑 hero (e.g. Zigi 0/8) floats UP via the urgency multiplier.
- A11: `decision.final_score` shown on the card == the value the picker uses to rank the shelf.

## Open questions (the calibration knobs — these are the real decisions)

1. **Dosage velocity window.** Lifecycle uses v30 (smooth); health uses 7d (reactive). Recommend a
   recency-weighted blend, e.g. `velocity = 0.6·v7 + 0.4·v30`, then **calibrate against operator-corrected
   history** (this is the natural hand-off to the learning loop, v2 F7). Decide the weights.
2. **days_cover** default (7?) and whether it varies by venue (high-traffic VOX vs office).
3. **Floor vs velocity precedence for growth** — confirm STAR/DOUBLE DOWN should let the floor win
   (visibility) while KEEP/WATCH let velocity win (anti over-pour). The table above assumes yes.
4. **Local vs global lifecycle signal** — use the per-machine (local) signal for the stance, falling
   back to global when a machine has no local history. Confirm.
5. **Final-score weights** — confirm `STANCE_W` (STAR/DOUBLE DOWN 1.5 … ROTATE OUT/DEAD 0.1),
   `global_w` (💎 1.2 / 📦 1.0 / 🔻 0.8), `local_w` (👑 1.2 / ✅ 1.0 / 🐕 0.7 / 💀 0.3), and the urgency
   cap (0.5). These set how aggressively stance/placement/urgency reshuffle the demand-based score.

## Out of scope

The learning loop itself (v2 F7 calibrates the weights over time). The strategy _labels_ (PROTECT etc.)
may stay as human-readable color, but they stop driving quantity.
