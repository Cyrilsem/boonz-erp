# PRD-100 — Empty-shelf signal (per-shelf holes, not per-product runout)

Status: APPLIED (2026-07-14, CS go-ahead) — ws1a/ws2/ws3/ws1b + fix1 live in prod.
Shadow-tested first (T1-T8 PASS in rolled-back txn, T4 golden md5-identical); post-apply:
consistency guard 0 findings, ACTIVATE-2005 P1 (s_holes 100), fleet P1 3 / P2 9 / P3 18
= shadow-identical. Dara + Cody (chip-surface revision included) PASS. Note: live
swaps_enabled flipped to true (p0_fix14) after this spec was written — PRD-100 does not
touch it; T7 amended to "engines untouched" (byte-identical, no engine DDL in this PRD).
Owner: CS · Author: Cowork conductor · Date: 2026-07-14
Governance: Dara (design) → Cody (Article 16 canonical writer — touches `v_machine_priority`) → apply.
Depends on: PRD-063 (extends the urgency view + `pick_urgency_params`).

## Problem

The picker cannot see an empty shelf when the product sits on more than one row.

`v_shelf_sales_identity` is keyed on **(machine_id, pod_product_id)**, not on the shelf. It pools
stock across every facing of a product and divides by the product's velocity. So days-of-supply is a
**product-level** number, and an empty row is averaged away by the rows that still have stock.

Proven live on ACTIVATE-2005 (2026-07-14):

- Aquafina occupies **7 rows** (A1, A2, A9, A10, A11, B15, B16). Two of them are at **zero**.
- Pooled: 53 units ÷ 22.1/day = **2.40 days** of supply → above the 2-day horizon → no hero trigger,
  no P2 trigger, `urgency` 14.5 → **P3_OK**.
- Meanwhile the customer is looking at two empty water rows on the fleet's fastest seller
  (663 units/30d, 63% of the machine's volume).

The inversion: an empty row triggers P1 **only when the product has no other facing** (pooled DOS
collapses to 0). The more facings a product has — i.e. the more important it is — the harder it is for
an empty row of it to fire.

| Machine | empty selling rows | seller/day | pooled DOS the model sees | tier today |
| --- | --- | --- | --- | --- |
| OMDCW-1021 | 1 | 2.4 | 0.00 | P1 |
| NISSAN-0804 | 1 | 0.5 | 0.00 | P1 |
| **ACTIVATE-2005** | **2** | **22.1** | **2.40** | **P3_OK** |

There is no backstop, because PRD-063 deliberately removed "empty shelf" as a trigger (it was
over-picking empty-plus-dead cosmetics: MC-2004, ALJLT, NOVO). Correct decision, but it also killed
the case where the empty shelf is a **seller**.

## Goal

Measure emptiness **per shelf**, as its own present-tense signal, and weight it heavily. An empty
shelf is bad aesthetically and commercially, independent of whether the machine is about to run dry.

Explicitly **do not** fake a per-shelf runout. Pooled DOS is the *correct* answer to "when do we run
out of water" (when one water row empties, the machine keeps selling water from the other six). It is
the *wrong* answer to "is there a hole in my machine right now". These are two different questions and
the model will now answer both.

## The model (locked with CS 2026-07-14)

### Hole definition (per shelf, per CS Q3 = fraction of capacity)

A shelf is a **hole** when it is enabled, not broken, and:

`current_stock = 0` **OR** `current_stock / max_stock <= hole_frac` (default **0.15**)

Fraction-of-capacity, never a flat count: a 25-slot water row with 2 bottles is a hole; a 6-slot Evian
row with 2 is half full.

### Grade weighting (per CS Q2)

Holes are weighted by how well the row's product sells, but the curve is **deliberately shallow** —
per CS, an empty shelf is bad even when the product is a laggard, so the weights stay high in relative
terms:

| grade | daily velocity | `hole_wt` |
| --- | --- | --- |
| A | ≥ 0.5/day | 1.0 |
| B | ≥ 0.2/day | 0.8 |
| C | > 0 | 0.6 |
| D | dead (0 sales 30d) | 0.4 |

### Score

`s_holes = 100 × LEAST(1, Σ(hole_wt over all holes) / holes_norm)`, `holes_norm` default **3**.

### Tier overrides (added to the PRD-063 set)

- **P1** if `holes_a >= 1` (a hero row is empty) **OR** `total_holes >= p1_holes_min` (default **2** —
  per CS, "2+ is severe").
- **P2** if `total_holes >= 1`.

Per CS Q1: an empty **dead** row does **not** get routed to SWAP and ignored — it is a hole, it gets
filled. A single dead hole lands P2; two or more holes of any grade land P1. ("2+ is severe. no need
to swap just refill.")

### Weight rebalance (the empty signal must be heavy — CS Q2)

| component | PRD-063 | PRD-100 | note |
| --- | --- | --- | --- |
| `w_runout` | 0.50 | **0.35** | still the biggest single driver |
| `w_holes` | — | **0.30** | NEW, second-heaviest by design |
| `w_expiry` | 0.20 | **0.12** | |
| `w_stale` | 0.15 | **0.13** | |
| `w_capacity` | 0.15 | **0.10** | mostly funds `w_holes`: machine-level fill % is the blunt version of exactly what `s_holes` now measures sharply, per shelf |

Sum = 1.00. All tunable via `pick_urgency_params`.

## Fleet impact (simulated live, 2026-07-14 — low noise)

Only **9 machines** fleet-wide have any hole at all under the 15% rule.

| Machine | track | holes (A/B/C/D) | tier today | tier with PRD-100 |
| --- | --- | --- | --- | --- |
| ACTIVATE-2005 | vox | 3 (3/0/0/0) | P3_OK | **P1** ← the target case |
| OMDCW-1021 | main | 1 (1/0/0/0) | P1 | P1 (unchanged) |
| NISSAN-0804 | main | 1 (0/1/0/0) | P1 | P1 (unchanged) |
| WAVEMAKER-1006 | main | 1 (0/0/0/1) | P3_OK | P2 |
| OMDBB-1020 | main | 1 (0/1/0/0) | P3_OK | P2 |
| HUAWEI-2003 | main | 1 (0/0/1/0) | P3_OK | P2 |
| VML-1003 | main | 1 (0/1/0/0) | P3_OK | P2 |
| USH-1008 | main | 1 (0/0/1/0) | P3_OK | P2 |
| ALJLT-1015-0100 | main | 1 (0/0/1/0) | P3_OK | P2 |

Net: **one new P1** (ACTIVATE, and it's on the VOX track so it does not consume the main cap of 8),
plus six machines promoted P3 → P2. MC-2004 / ALJLT-0200 / NOVO — the machines PRD-063 correctly
dropped — stay out, because their empty rows are not holes under this rule.

## Design (the change set)

1. **Extend `pick_urgency_params`** (singleton id=1) with: `hole_frac` (0.15), `hole_wt_a/b/c/d`
   (1.0/0.8/0.6/0.4), `holes_norm` (3), `w_holes` (0.30), `p1_holes_min` (2), `p2_holes_min` (1);
   and re-seed `w_runout`/`w_capacity`/`w_expiry`/`w_stale` to the rebalanced values above.
2. **New `v_shelf_holes`** — per (machine_id, shelf): `is_hole`, `grade`, `hole_wt`. Reads
   `v_live_shelf_stock` (the reliable slot total, and the same source the drawer renders) joined to
   `v_shelf_sales_identity` **for the product's velocity/grade only**. Grain is the SHELF. This is the
   object the whole PRD turns on.
3. **`v_machine_priority`** — add `s_holes` to the urgency sum at `w_holes`; add the two tier
   overrides; expose `holes_total` / `holes_a` / `holes_b` / `holes_c` / `holes_d` as new columns; add
   reason tokens `empty_hero_row`, `empty_rows_2plus`, `hole_row`. Keep every existing output column.
4. **Consumers untouched**: `pick_machines_for_refill`, `get_machine_health` cards (they pick up the
   new tiers and the new reason tokens for free), `build_draft_for_confirmed`.
5. **Pooled runout stays as-is.** `v_shelf_sales_identity` is NOT re-grained. No per-facing velocity
   fiction.

## Acceptance tests (all must pass; STOP on fail)

- T1 `v_shelf_holes` flags exactly the 2 zero Aquafina rows on ACTIVATE-2005 plus the third A-row
  under 15%; does not flag the Fade Fit rows (8/8 and 8/12, not holes).
- T2 ACTIVATE-2005 becomes P1 with reason `empty_hero_row` + `empty_rows_2plus`.
- T3 Fleet simulation reproduces the 9-machine table above: 1 new P1, 6 new P2, and MC-2004 /
  ALJLT-0200 / NOVO do NOT return to P1.
- T4 With `w_holes = 0` and the PRD-063 weights restored, `v_machine_priority` is byte-identical to
  PRD-063 (golden — the signal is additive and fully dialable).
- T5 `hole_frac` is a true ratio: a 6-slot row with 2 units is NOT a hole; a 25-slot row with 2 units
  IS. Verify on Evian 1L (6 cap) vs Aquafina (25 cap).
- T6 `v_machine_priority` still returns the full fleet < 800 ms.
- T7 `engine_add_pod` / `engine_swap_pod` byte-identical; `swaps_enabled` stays false.
- T8 Single-row param guard on `pick_urgency_params` still holds.

## Rollback

One forward migration restores the PRD-063 `v_machine_priority` body and weights. `pick_urgency_params`
columns are additive (data). `v_shelf_holes` can be dropped. No picker/FE change to undo.

## Risk

The weight rebalance re-scores the whole fleet, not just the 9 machines with holes. Mitigation: T4
golden (w_holes=0 reproduces PRD-063 exactly) proves the delta is entirely attributable, and the
before/after tier table for the full fleet goes to CS before apply.

## Also

Update boonz-master-3 (engine table, Stage-1 Picker row): picker now carries a per-shelf hole signal;
an empty row of a seller is P1, 2+ holes of any grade is P1.

## Out of scope

Per-facing velocity allocation (rejected — pooled runout is the correct runout metric). Assortment /
variety inside a multi-SKU row (that is PRD-064, still parked). Procurement.
