# Wave 1–2 — Open Design Decisions & Findings (for Dara + CS)

Date: 2026-07-09. Purpose: unblock the parked Wave-1/Wave-2 PRDs with the specific decisions each needs. Nothing here is code — these are the rulings that let the next run build.

---

## A. FINDING — 089/090 thresholds: do NOT tune to bind (recommendation: enable-as-guardrail or leave dormant)

**Evidence** (pod_refills, last 14 plans): 75 band-3 (throttled ×0.30) engine REFILL rows; 60 of them selling (v>0); **zero** sell ≥ 0.2 units/day (0 rows qualify at floors of 0.5, 0.3, _and_ 0.2). 090's niche best-location facings already meet the 0.8×cap floor.

**Interpretation:** Cause D / Case 2 ("relative-band starvation") is **largely theoretical on Boonz's real data** — the bottom-third shelves are genuinely low-velocity, not healthy shelves unfairly throttled. Lowering `abs_velocity_floor` / `min_facing_floor` / `niche_facing_target` to force a delta would push units onto shelves selling <1 unit / 5 days → manufactured waste.

**Decision:** enable 089/090 as **inert guardrails** (they're proven 0-delta, so enabling is zero-risk and arms them for future data shifts), or leave dormant. **Do not chase binding via threshold tuning.** Revisit only if fleet velocity distribution changes materially.

---

## B. PRD-091 — Dara decision: how to represent an `expiry_pull` remediation

The park: the ADD-side "pull expiring + refill fresh" representation is undecided, and pull/refill conservation is fiddly.

| Option              | Shape                                                                              | Trade-off                                                                                                                                                                |
| ------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1                   | pod_swaps REMOVE(expiring) + ADD_NEW(fresh, same product)                          | reuses swap machinery, but "swap to the same product" is unusual; R5 cooldowns / self-substitution guards may misfire                                                    |
| 2                   | pod_refills REFILL(fresh) + separate REMOVE(expiring) line, tagged `expiry_risk`   | keeps ADD/REMOVE semantics but conservation must net the pull against the fresh add                                                                                      |
| **3 (recommended)** | **signal-only**: emit an `expiry_risk` tag on the shelf; no ADD-side inventory row | cleanest — avoids ADD-side conservation entirely; the actual rotation is done by **PRD-095** (which already reads pod expiry self-contained). 091 becomes a thin tagger. |

**Recommendation: Option 3.** It makes 091 trivial and conservation-neutral, and hands the real work to 095. **CS/Dara to confirm.** If confirmed, 091 unparks as a small tagger and 095 becomes the load-bearing expiry PRD.

---

## C. PRD-092 — Dara decision: where to emit `blocked_no_wh` action proposals

The park: emitting substitute/M2M/procurement proposals risked an unsafe edit-point inside the engine (`v_procurement_gaps`), and proposals aren't plan rows so they were diff-inert (unvalidatable by the referee).

| Option              | Shape                                                                                                                                                                                 | Trade-off                                                                                                                                               |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **1 (recommended)** | **new side table** `refill_action_proposals(plan_date, machine_id, shelf_id, kind{substitute\|m2m\|procurement}, detail jsonb, …)`; engine appends to it, does NOT mutate plan output | engine plan output stays byte-identical (flag-off inert trivially); proposals are additive + **validatable by row count**; SWAP/operator read the table |
| 2                   | qty=0 rows in pod_refills tagged `nowh_*`                                                                                                                                             | visible in the plan, but pollutes plan semantics and risks conservation/diff noise                                                                      |

**Recommendation: Option 1 (side table).** Keeps the referee gate clean and makes the proposals countable. **Dara** designs the table + the surplus-machine and `find_substitutes_for_shelf` queries; **Cody** reviews the additive migration.

---

## D. PRD-094 — prerequisite: an engine change-freeze window

Re-spec'd against the live `engine_swap_pod` (`ac953f99`). **Cap bug confirmed present in Passes 1 & 2** (`qty_in` sized from `v_shelf_cap = MAX(v_shelf_max_stock.max_stock_weimi)` = the shelf/old-product cap); Pass 3 already product-anchored. Fix = copy Pass 3's `product_slot_capacity_units(...)` sizing into Passes 1 & 2. **Blocked only on coordination:** needs a Family-A engine change-freeze (the 07-09 run parked when a concurrent session changed `pick_machines_for_refill` mid-run). Schedule a freeze, then run `PRD-094-goal-command.md`.

---

## E. Coordination — the real Wave-2 bottleneck

Multiple sessions are editing Family-A engines concurrently (the 086/087/088 work). The referee's byte-identity gate **cannot hold** during concurrent engine surgery. **Recommendation:** designate a change-freeze window for Wave-2 engine work; no other engine migrations during it. Without this, every Wave-2 engine run parks on byte-identity, regardless of spec quality.

---

## Summary — what unblocks what

- **089/090:** decision made (enable-as-guardrail or dormant; don't tune). No further work.
- **091:** confirm Option 3 (signal-only) → unparks as a thin tagger.
- **092:** confirm Option 1 (side table) → Dara designs table + queries.
- **094:** ready; needs an engine-freeze window.
- **095/096/097:** follow 094 + the 091/092 rulings; 096 also needs the hv→lv pairing rule (capacity_mismatch is per-shelf today).

## Status update — 2026-07-09 (CS confirmed 091=Opt3, 092=Opt1)

- **091 — Option 3 CONFIRMED → SHIPPED (signal-only):** `v_shelf_expiry_risk` + `refill_policy_params.expiry_risk_days`. Additive, no engine edit. Consumed by PRD-095 (freeze-held).
- **092 — Option 1 CONFIRMED → SHIPPED (side-table):** `refill_action_proposals` + standalone `compute_nowh_proposals(plan_date)`. Additive, no engine edit. 12/12 validated.
- **093 seed:** VOX Aquafina/Ice Tea/M&M candidates PREPARED for CS confirmation (see PRD-093-EXECUTION-LOG). Not tagged.

### HELD for the engine-freeze window (no Family-A edits until then)
- **094** product-anchored swap caps — needs Dara re-spec vs current `engine_swap_pod`.
- **095** expiry-risk swap trigger — consumes the 091 `v_shelf_expiry_risk` signal.
- **096** within-pod relocation — needs the hv→lv pairing rule (capacity_mismatch is per-shelf today).
- **097** R7/R3 guards — R3/net-flow anchors absent; build from Dara design.
- **091/092 engine-wiring** — wiring `expiry_input_v1`/`add_nowh_action_v1` into `engine_add_pod`.
- **093 Part B** — consignment `wh_avail`-skip gating in `engine_add_pod`.

Family-A md5 baseline (start=end of this goal, UNCHANGED): engine_add_pod=`b91c530b` · engine_swap_pod=`90f26896` · engine_finalize_pod=`55141509` · pick_machines_for_refill=`48cc1844`.
