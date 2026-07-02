# PRD-027: Refill Hardening Batch (Swap Guards, WH Source Visibility, Data Backfills)

**Date:** 2026-06-12
Status: Closed 2026-07-02 (PRD-071 sweep). Reason: overtaken by the PRD-030/031 batch and the PRD-053 conservation line. Reopen by deleting this line.
**Severity:** Medium. None of these corrupt data today, but each erodes trust or hides information the operator needs.
**Owners:** mixed per workstream (Cody / Stax / Dara / CS), see each section.

Grouped follow-ups from the 2026-06-12 pipeline review (BOONZ BRAIN/refill_review_2026-06-12.md). Each workstream is independently shippable.

---

## WS1: Swap engine guards (engine_swap_pod v10.1) — Cody review

**1a. p_min_pearson is accepted but never applied.** The dead-tag resolution loop takes the top `find_substitutes_for_shelf` candidate regardless of correlation; last night swaps shipped at corr 0.214 (NOOK A05 Be-kind) and 0.242 (OMDBB A07 Nescafe). Fix: in the dead-tag loop, prefer candidates with `pearson_score >= p_min_pearson`; if none qualify, fall back to best global performer EXPLICITLY (`substitute_source = 'global_performer_fallback'`) so the FE can show it was a low-affinity pick. Do not silently drop the threshold parameter.

**1b. No per-machine cap on dead-tag swaps.** `p_max_swaps_per_machine` (default 2) only caps Pass 1 strategic tags. A machine with 6 dead shelves gets 6 swaps in one cycle (driver workload, machine-face churn). Fix: apply the cap across both passes, strategic tags first, dead-tags by worst shelf first; overflow dead shelves resolve to qty 0 + carry the tag to the next cycle.

**1c. qty_in default of 8.** When `v_shelf_max_stock` has no row for a shelf the swap-in quantity defaults to 8. Tied to WS4 backfill; until then log a `clamp_reason: default_capacity_8` marker into reasoning so defaulted rows are auditable.

## WS2: warehouse source visibility — Stax (FE only)

The data already exists: `refill_dispatching.from_warehouse_id` was populated on 103/103 lines for 2026-06-13 (WH_CENTRAL 59, WH_MCC 29, WH_MM 15). The FE does not display it.

- Add a "Source WH" column/badge (join `warehouses.name`) to Refill Planning (committed view) and Packing.
- Filter chip per warehouse so packers can pull their own warehouse's lines.
- Read-only change, no RPC work.

## WS3: push_plan_to_dispatch WH assignment review — Cody

MPMCC-1054 (Magic Planet, MCC cluster) had all 7 lines assigned from WH_CENTRAL while WH_MCC stocked at least part of the products; ACTIVATE-2005 split 15 MCC / 2 CENTRAL. Audit the assignment logic in `push_plan_to_dispatch` v3: expected policy is nearest/cluster warehouse first with stock, CENTRAL fallback per line. Document the actual rule, fix if it ignores machine↔warehouse affinity, and emit the chosen warehouse + reason into the dispatch comment or a new column so WS2 can display it.

## WS4: shelf capacity backfill — Dara design, CS data entry

**2,612 of 2,615 active shelves have `shelf_configurations.max_capacity = NULL.`** Every cap consumer works around it via `v_shelf_max_stock` (WEIMI max) or hardcoded defaults (8 in swap, etc.).

- Backfill `max_capacity` from `v_shelf_max_stock.max_stock_weimi` where present (show CS the row diff first per no-silent-changes rule; backfilling NULL → value is the allowed class).
- Shelves with neither source get flagged for manual entry (ties to open bug: shelves missing from v_live_shelf_stock with NULL max_capacity, Task #18).
- Dara: decide whether `max_capacity` becomes authoritative with WEIMI as validator, or stays advisory.

## WS5: refill_plan_output display fields — assistant + Stax

Stitch v19/v20 hardcodes `current_stock = 0`, `max_stock = 0` in emitted lines, which renders every row "above cap" in any FE comparison and contributed to the cap scare reviewed on 2026-06-12. Either populate real values at stitch time (live shelf stock + v_shelf_max_stock) or remove the columns from the FE display. Decide, then ship the small patch.

## Acceptance criteria

- [x] WS1 swaps: no swap-in below threshold without explicit fallback marker; per-machine cap enforced across passes. APPLIED 2026-06-12 as `phaseF_swap_pod_v10_2_ws1_guards` (engine_swap_pod v10.2). Cody ✅ (Articles 1, 4, 8, 12); v10.1 rollback md5 `c30f1165329034488967b1dfca5e4894`; rolled-back smoke on 06-13 green (new counters `dead_tags_deferred_by_cap` / `dead_tags_below_pearson_fallback` in return shape). Also shipped 1c: `clamp_reason='default_capacity_8'` audit marker. Live guard exercise lands with the PRD-024 section-2 rebuild (engine_add re-creates dead tags).
- [ ] WS2: Source WH visible on Refill Planning + Packing. TICKETED to Stax (action_tracker a419f50e).
- [ ] WS3: assignment rule documented; MPMCC-class mismatches eliminated or justified. TICKETED (action_tracker 37d86638).
- [ ] WS4: NULL max_capacity count from 2,612 -> < 100 (manual-entry remainder tracked). TICKETED to Dara (action_tracker 4cf2ec8f).
- [ ] WS5: no FE surface compares quantity against a hardcoded zero max. DRAFTED as `supabase/migrations/_DRAFT_phaseF_stitch_v21_ws5_real_stock.sql` (stitch v21 emits real current/max stock) - HELD: second stitch rewrite within 24h of v20 requires CS green light; apply-time Cody on the full verbatim body. Can ride along with the PRD-024 section-2 green light.
