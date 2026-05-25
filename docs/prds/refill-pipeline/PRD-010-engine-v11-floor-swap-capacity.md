---
id: PRD-010
title: Engine v11 — signal-aware floor, duplicate swap guard, visual-fill minimum, shelf capacity expansion
status: Done
severity: P1
reported: 2026-05-24
source: CS review of auto_generate_draft for 2026-05-25; MINDSHARE Chocolate Bar 17u WIND DOWN refill; MC-2004 duplicate YoPro swap + Barebells under-fill + Coca Cola Zero capacity constraint
routing: [Dara, Stax, refill-brain, boonz-pico-refill-plan]
protected_entities:
  [pod_refill_plan, refill_plan_output, shelf_configurations, planned_swaps]
done_summary:
  commit: 44ef57a
  shipped_at: 2026-05-25
  migrations:
    - 20260525004300_engine_add_pod_v11_signal_aware_floor_visual_fill.sql (AC#1 signal-aware performance floor + AC#3 visual-fill minimum)
    - 20260525004310_engine_swap_pod_v9_machine_uniqueness_planned_swap_guard.sql (AC#2 machine-level duplicate swap guard + planned_swaps priority check)
    - 20260525004320_engine_finalize_pod_v11_capacity_mismatch_warnings.sql (AC#4 capacity_mismatch_warnings JSONB diagnostic)
    - 20260525004330_pick_machines_v6_auto_close_executed_planned_swaps.sql (AC#5 auto-close planned_swaps when both ADD detected on machine and REMOVE absent from original shelf)
  verification:
    regenerated_draft: pass (2026-05-25 draft regenerated post-deploy; MINDSHARE Chocolate Bar WIND DOWN now refills at velocity target, MC-2004 YoPro no longer duplicates across B06+B08, MC-2004 Barebells reaches 50% visual floor, MC-2004 Coca Cola Zero surfaces a capacity_mismatch_warnings entry suggesting the Loacker shelf swap)
    followup_prd: PRD-010a (v9.1 patch — engine_swap_pod shelf_code mismatch fix in the planned-swap guard, plus AC#4 capacity warning filter widening so MC-2004 still surfaces the suggestion after the planned Plaay swaps land)
---

# PRD-010 — Engine v11: signal-aware floor, duplicate swap guard, visual-fill minimum, shelf capacity expansion

## Problem

Four distinct engine issues surfaced from the 25-May draft review:

### Issue 1: Performance floor ignores signal (MINDSHARE Chocolate Bar)

The engine refilled 17 units of Chocolate Bar on MINDSHARE A10, a WIND DOWN product with v30 of 0.23/day. Pure velocity targeting would give ~3 units (0.23 x 14 days). Instead, `performance_floor` topped the shelf from 3/25 (12%) to 20/25 (80%). Refilling 17 units of a product you intend to phase out wastes truck capacity and delays the wind-down.

**Root cause:** `performance_floor` is applied uniformly regardless of `signal`. WIND DOWN, WATCH, and STAR all get the same 80% floor.

### Issue 2: Duplicate product across multiple shelves in one swap cycle (MC-2004 YoPro)

engine_swap_pod placed YoPro as ADD_NEW on both B06 (replacing Hummus) and B08 (replacing Rice Cake) via autonomous Pearson Pass 2. This violates the existing "no 2 products on same shelf" rule (see feedback_pico_no_dual_product_shelf) but at the machine level: one swap cycle should not introduce the same product onto two different shelves.

Additionally, both shelves had pending Plaay swaps in `planned_swaps` (Hummus to Plaay Truffles, Rice Cake to Plaay Tablets). The autonomous Pass 2 overrode the strategic intent without checking.

**Root cause:** (a) No machine-level uniqueness check in autonomous swap pass. (b) engine_swap_pod Pass 2 does not check `planned_swaps` table for strategic overrides before selecting a Pearson substitute.

### Issue 3: Velocity target ignores visual fill / shelf appearance (MC-2004 Barebells)

Barebells on MC-2004 B09 has 7/20 stock (35% fill) with v30 of 0.63/day. The engine gave REFILL 2u (velocity target: 0.63 x 14 = ~9, minus current 7 = 2). Mathematically correct, but the shelf looks 65% empty. Barebells is the 4th fastest seller on this machine (most products are 0.1-0.3/day), and a well-stocked shelf drives visual appeal and purchase intent.

**Root cause:** The engine targets only velocity-based cover without a minimum visual-fill floor for healthy products. A KEEP/KEEP GROWING/STAR product should never sit below 50% fill.

### Issue 4: No mechanism for shelf capacity expansion (MC-2004 Coca Cola Zero)

Coca Cola Zero is the fastest seller on MC-2004 (v30 = 1.53/day) but sits on a 14-unit shelf (0-A01). The engine gives REFILL 2 (capped_by_max), and the shelf empties in ~9 days. Meanwhile, Loacker (v30=0.07) occupies a 24-unit shelf and Chocolate Bar (low velocity) occupies a 25-unit shelf.

**Root cause:** The engine has no concept of "this product deserves a bigger shelf." Shelf assignments are static in the planogram. There is no automated or semi-automated flow to propose moving a high-velocity product to a higher-capacity shelf when a low-velocity product is occupying one.

## Acceptance Criteria

### AC#1: Signal-aware performance floor

The performance floor in `engine_add_pod` must be scaled by signal:

| Signal       | Floor (% of max_capacity)       | Rationale                      |
| ------------ | ------------------------------- | ------------------------------ |
| STAR         | 80%                             | Hero product, always full      |
| DOUBLE DOWN  | 80%                             | Growing, keep prominent        |
| KEEP GROWING | 70%                             | Good trajectory                |
| KEEP         | 60%                             | Stable performer               |
| WATCH        | 40%                             | Under observation              |
| WIND DOWN    | velocity target only (no floor) | Let it drain naturally         |
| ROTATE OUT   | 0% (swap/remove only)           | Engine should swap, not refill |
| DEAD         | 0% (swap/remove only)           | Engine should swap, not refill |
| RAMPING      | 50%                             | New product, learning phase    |

When signal is WIND DOWN, the engine writes `clamp_reason: 'velocity_target'` (not `performance_floor`). The refill qty is purely `CEIL(v30 x days_cover) - current_stock`, clamped at 0.

**Test:** Rerun MINDSHARE draft. Chocolate Bar (WIND DOWN, v30=0.23) should get ~3 units, not 17.

### AC#2: Machine-level duplicate swap guard

Before `engine_swap_pod` commits an autonomous (Pass 2) ADD_NEW row:

1. Check if the proposed `pod_product_id` already exists on another shelf of the same machine in this plan_date's draft (either as an existing shelf or another ADD_NEW row).
2. Check if the proposed shelf has a pending row in `planned_swaps` (status = 'pending') for this machine. If yes, the strategic swap takes priority; skip autonomous substitution for that shelf.
3. If duplicate detected, pick the next-best Pearson candidate that is NOT already on the machine.

**Test:** Rerun MC-2004 draft. B06 and B08 should NOT both get YoPro. Shelves with pending Plaay swaps should show the Plaay product, not YoPro.

### AC#3: Visual-fill minimum for healthy products

For products with signal in (STAR, DOUBLE DOWN, KEEP GROWING, KEEP), apply a **visual-fill minimum** after the velocity target:

```
visual_floor_qty = CEIL(max_capacity * 0.50)
final_target = GREATEST(velocity_target, visual_floor_qty)
refill_qty = GREATEST(final_target - current_stock, 0)
```

This ensures a healthy product never sits below 50% fill even if velocity alone would leave it low. The `clamp_reason` should be `'visual_fill_minimum'` when this floor activates.

**Test:** MC-2004 Barebells (KEEP, 7/20, v30=0.63). Velocity target = 9. Visual floor = CEIL(20 x 0.50) = 10. Final target = 10. Refill qty = 10 - 7 = 3. (Not 2.)

### AC#4: Shelf capacity expansion proposals

Add a new output to `engine_finalize_pod`: a `capacity_mismatch_warnings` JSONB array in the plan diagnostics. For each machine, flag cases where:

- A product with signal in (STAR, DOUBLE DOWN, KEEP GROWING) is on a shelf with max_capacity <= 14
- AND the same machine has a shelf with max_capacity >= 20 occupied by a product with signal in (WIND DOWN, ROTATE OUT, DEAD, WATCH)
- AND the high-velocity product's shelf fill reaches >= 80% after refill (i.e., capped_by_max)

Each warning should contain:

```json
{
  "machine_name": "MC-2004-0100-O1",
  "high_velocity_product": "Coca Cola Zero",
  "current_shelf": "A02",
  "current_max": 14,
  "v30": 1.53,
  "signal": "KEEP GROWING",
  "candidate_shelf": "A10",
  "candidate_max": 24,
  "candidate_product": "Loacker",
  "candidate_signal": "ROTATE OUT",
  "candidate_v30": 0.07,
  "days_gained": 6.5
}
```

These are advisory only (not auto-executed). They surface in the FE draft view as a "Shelf optimization suggestions" section so CS can act on them. Shelf swaps are planogram changes that need CS approval.

**Test:** MC-2004 Coca Cola Zero (KEEP GROWING, 14-unit shelf, capped_by_max) should trigger a warning suggesting a move to the Loacker shelf (24 units, ROTATE OUT).

### AC#5: Close planned_swaps loop after execution

When a planned_swap's `add_pod_product_name` product is detected as already present on the target machine in `v_live_shelf_stock` (matched by pod_product_id), and the `remove_pod_product_name` product is no longer on the shelf it was originally assigned to, the swap has been physically executed. The system should:

1. Auto-detect this state during the picker or engine run
2. Update `planned_swaps.status` from 'pending' to 'completed'
3. Set `completed_at` = now() and `completed_by` = 'auto_detect'

This prevents the engine from repeatedly trying to execute swaps that were already done in a previous visit.

**Test:** MC-2004 Plaay swaps (Hummus to Truffles, Rice Cake to Tablets) should auto-close since Plaay Truffle and Plaay Tablet are already live on the machine per WEIMI.

## Decisions

- Signal-aware floor values are initial proposals. CS may tune after one week of observation.
- Visual-fill minimum of 50% applies only to KEEP and above. WATCH/WIND DOWN/DEAD products should drain.
- Shelf expansion proposals are advisory, not auto-executed. Planogram changes need human sign-off.
- planned_swaps auto-close is safe because it cross-checks both the ADD product being present AND the REMOVE product being absent.

## Migration Plan

1. Modify `engine_add_pod` RPC: add signal-aware floor table + visual-fill minimum
2. Modify `engine_swap_pod` RPC: add machine-level uniqueness check + planned_swaps priority check
3. Modify `engine_finalize_pod` RPC: add capacity_mismatch_warnings to diagnostics
4. Add auto-close logic to `pick_machines_for_refill` (runs before engine, has WEIMI context)
5. FE: render capacity_mismatch_warnings in draft view

## Rollback

All changes are in RPCs. Revert to engine v10 RPCs if issues detected. No schema migration required for AC#1-3. AC#4 adds a JSONB key to existing diagnostics. AC#5 modifies planned_swaps.status (reversible).
