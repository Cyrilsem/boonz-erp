# Making v3 a monster — the decision-correctness plan

19 Aug 2026. Companion to RETRO-v3-measurement-2026-08-19.md.

---

## First, honesty about "10x"

Forecast accuracy does not 10x — the best grocery-retail engines on earth run WMAPE ~0.3–0.5 at daily/shelf grain, and v3 is at 0.54 on shelves that sell. The realistic accuracy ceiling is ~2x better. The 10x is real but it lives elsewhere: it is the **compound** of accuracy × coverage × waste × labor × autonomy. v3 planning 288 shelves v19 ignored is already a coverage multiplier. The plan below is ordered by measured error contribution, not by what sounds impressive.

## Where v3's error actually is (measured, settled series)

| Error bucket                         | Share of all v3 error | The lever                                                           |
| ------------------------------------ | --------------------- | ------------------------------------------------------------------- |
| **Over-forecast on selling shelves** | **48%**               | Bias correction — v3 systematically forecasts high (+35% on AMAZON) |
| Under-forecast on selling shelves    | 36%                   | Mostly censoring remnants + no event calendar                       |
| Shelves that sold zero               | 16%                   | Not an accuracy problem — a scoring + assortment problem            |

And the top 10 over-forecast offenders share one trait: **they are almost all mix shelves** (Coca Cola Mix, Snack Bar, Chocolate Bar, Soft Drinks Mix). v3 knows a mix shelf's aggregate history but not its current composition — it forecasts the shelf as if the fast variant fills it.

---

## The plan — five moves, in order

### Move 1 — Fix the instrument before the engine (this week, zero engine code)

You cannot tune what you cannot score. Three changes:

1. **Rule on S-341**: the gate compares only shelves both engines planned on the same date. Your ruling, one view change.
2. **Report coverage and accuracy as two numbers.** v3's 288 extra shelves show up as a coverage gain, never as an accuracy loss.
3. **A fixture that goes red if the gate ever compares non-overlapping populations again.** The instrument gets the same protection as the engine.

This is the "decision correctness" layer you asked about: every number a human reads before authorizing something gets a test, an owner, and a definition of what it may not silently include. Code got 78 fixtures; decisions got zero. Even the split.

### Move 2 — Kill the +35% over-forecast bias (biggest single win, ~2 weeks)

Half of all error is one systematic direction. A per-cluster bias corrector — multiply each forecast by the cluster's trailing settled forecast/actual ratio, clamped — is boring, proven, and attacks 48% of the error directly. The learning loop to carry it **already exists**: the weekly miners mint parameter proposals and you approve them. The missing piece is a bias-correction proposal type. Estimated effect: v3's like-for-like WMAPE drops from ~0.87 toward ~0.6.

### Move 3 — Switch on what is built and sitting at zero (days, not weeks)

The most expensive discovery of this audit: v3's best weapons are installed and disarmed.

| Weapon                                            | State today                                                                                            | Action                                                                                                                           |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| **Demand calendar** (events × DOW × campaigns)    | **0 rows. Empty.** The multiplier layer multiplies by nothing.                                         | Seed it now — Back-to-Office launches **31 Aug**, UAE school return, and the engine currently has no idea. This is 12 days away. |
| **14 miner proposals** (pick + edit learning)     | Pending your approval since minting                                                                    | Review them this week. The engine is trying to learn from you and waiting at the door.                                           |
| **18 facing proposals**                           | Pending                                                                                                | Same session.                                                                                                                    |
| **Intent awareness** (`w_intents`)                | Dial shipped at **0** — and the miner is structurally unable to raise a dial that produces no evidence | Set it to a small nonzero value deliberately; let evidence accrue.                                                               |
| **Margin weighting** (`substitute_margin_weight`) | **0.000** — substitution ignores money                                                                 | Turn on low; this is the revenue-per-slot lever.                                                                                 |
| **Preflight enforcement**                         | `warn` — plans that fail invariants still commit                                                       | `git push` deploys DR-6, then flip D-19 to `block`. The push has been owed for 11 days.                                          |

### Move 4 — Feed the mix-shelf blind spot (the composition estimator, ~2–4 weeks)

The top over-forecast offenders are all mixes, and mixed shelves were already 24% of units in the Alpha Mind report. The composition estimator exists (hourly cron, one machine). Expand it, and let PRD-112 driver substitutions and PRD-114 expiry checks write composition evidence back — the drivers' fingers become the engine's eyes. This attacks the head of the error distribution, not the tail.

### Move 5 — Evidence everywhere, then flip cluster by cluster (weeks 2–6)

Six clusters have zero v3 shadow rows; they are unflippable by construction. Bring them into nightly shadow scope deliberately. With the fixed instrument from Move 1, each cluster flips the moment its paired evidence says v3 wins there — AMAZON and OHMYDESK will likely be first. VOX last: biggest, venue-sourced, least forgiving.

---

## The compounding math (why this is the 10x)

| Layer                                   | Today                | After the plan            | Multiplier                   |
| --------------------------------------- | -------------------- | ------------------------- | ---------------------------- |
| Accuracy (like-for-like WMAPE)          | 0.87                 | ~0.5                      | ~1.7x fewer wrong units      |
| Coverage (shelves planned)              | v19 skips slow/empty | every enabled shelf       | ~1.9x series planned         |
| Stockout capture (blocked demand → POs) | logged, ignored      | feeds procurement         | recovered lost sales         |
| Waste (expiry ceiling, live)            | shadow only          | live per cluster          | expired/sold trending to <2% |
| Labor (your 2-hour refill sessions)     | manual archaeology   | dictate → diff → approve  | G8's ≤2 min target           |
| Autonomy                                | 0 clusters           | KPI-earned auto-with-veto | your attention freed         |

No single row is 10x. The product of the rows is. That was always PRD-110's actual thesis — G5 (revenue +10%), G7 (waste <2%), G8 (2-minute edits) and G10 (autonomy) are multiplicative, not additive.

## The one rule that protects all of it

**Every decision-bearing number gets the same discipline as decision-bearing code.** A fixture on the gate view. An expiry date and owner on every "harmless for now." A paired-population check on every A/B verdict. The engine was never the weak link — the scoreboard was. Guard the scoreboard and the engine's own learning loop does the rest.

## This week, concretely

1. Rule on S-341 (the comparison rule) — unblocks everything.
2. Seed `demand_calendar` with Back-to-Office + school return before 31 Aug.
3. One approval session: 14 miner + 18 facing proposals.
4. `git push` → DR-6 deploys → flip preflight to `block`.
5. Order the six blind clusters into shadow scope.
