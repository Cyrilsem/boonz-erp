# PRD-059 — Expiry Batch Hygiene (NULL-shelf resolution, Inactive removal, drawer truth)

Status: Shipped - APPLIED to prod 2026-06-24 (5 migrations, per-WS CS gate); MERGED to main via PR #5 (merge `f6195be`) 2026-06-25; PROD-DEPLOYED (recorded by `06737fb chore(deploy): record production f6195be`).

- WS1 (classify on v_live_shelf_stock): RESOLVE 158 / HIGHLIGHT 110 / NO-MAPPING 23. ✅
- WS2 `prd059_ws2_resolve_shelf_backfill`: 61 shelf_id backfills (74 collisions skipped → WS6 display; 23 ambiguous left NULL). ✅
- WS3 `prd059_ws3_no_mapping_inactive`: 23 → Inactive. ✅
- WS4 `prd059_ws4_highlight_orphan_writeoff`: 110 → Removed/Expired (orphan_not_on_machine). ✅
- WS5 `prd059_ws5_inactive_cleanup`: 1,901 → Removed/Expired (inactive_cleanup); 0 Inactive-with-stock remain. ✅
- WS6 `prd059_ws6_drawer_expiry_truth` + FE `refill/page.tsx`: nearest_expiry_qty per slot + Unassigned/orphan section. tsc+lint+build green. ✅
- Tests: T1 (1 residual orphan fleet-wide, surfaced) · T2 (0 Inactive/Removed counted) · T3 (6,515 rows unchanged, all reversible) · T4 (WAVEMAKER Coca Cola Zero RESOLVE) · T5 (engines unmodified, swaps_enabled=false). All ✅.
  Original draft below.

Status (orig): DRAFT (not applied)
Owner: CS · Author: Cowork conductor · Date: 2026-06-24
Scope: data hygiene on `pod_inventory` (protected, Article entity) + the expiry views + a
small FE drawer fix. No engine/scoring change.

## Problem

The Stock Snapshot card "X expired / X expiring" counts come from `v_machine_expiry_summary`
→ `v_machine_expiry_batches` → Active `pod_inventory` batches, keyed by `boonz_product_id`,
with **no link to the physical shelf** and **no check that the product is still on the
machine**. Two visible symptoms:

1. A card shows "expired" but clicking the machine shows nothing, because the expiring batch
   has `shelf_id = NULL` (orphan) and/or the product is no longer on the planogram.
2. Large shadow stock: `pod_inventory` holds 1,878 Inactive rows / 7,646 units (293 already
   expired) and 69 Removed/Expired rows that linger but are correctly ignored by the view.

### Verified current state (live, eizcexopcuoycuosittm, 2026-06-24)

NULL-shelf Active batches resolved through `product_mapping` (Active mappings only) against
the machine's current slots:

| Bucket                                     | batches | units | expired | exp ≤30d |
| ------------------------------------------ | ------- | ----- | ------- | -------- |
| RESOLVE (pod-product IS on the machine)    | 132     | 481   | 1       | 6        |
| HIGHLIGHT (pod-product NOT on the machine) | 138     | 579   | 4       | 14       |
| NO ACTIVE MAPPING (boonz product unmapped) | 23      | 109   | 0       | 2        |

The "on machine" check above used `slot_lifecycle.is_current`, which is known to miss
products that are physically on the shelf (e.g. WAVEMAKER Coca Cola Zero). **This PRD switches
the resolution check to `v_live_shelf_stock`** (machine_id + pod_product_id, is_enabled),
which is the same source the drawer renders, so RESOLVE vs HIGHLIGHT matches what CS sees.

## Goal

Make expiry counts and the per-machine drawer agree, and stop counting stock that is not
really live, without losing or deleting any data.

## Resolution rule (canonical for this PRD)

For each Active `pod_inventory` batch with `shelf_id = NULL`:

1. Map `boonz_product_id` → `pod_product_id` via `product_mapping` where `status='Active'`
   (machine-specific row preferred over `is_global_default`). No Active mapping → see WS3.
2. Check `v_live_shelf_stock` for a row with that `machine_id` + `pod_product_id` and
   `is_enabled = true`.
   - PRESENT → **RESOLVE**: backfill `shelf_id` to the shelf for that live slot
     (resolve shelf via machine + `aisle_code`/`slot_name` → shelf_configurations).
   - ABSENT → **HIGHLIGHT**: product not on the machine → orphan for write-off (WS4).

## Workstreams (phased; STOP for CS between phases)

- **WS1 — Recompute with live-shelf truth.** Implement the resolution rule above using
  `v_live_shelf_stock` (not slot_lifecycle). Produce the refreshed RESOLVE / HIGHLIGHT /
  NO-MAPPING lists. Read-only; CS reviews the lists before any write.
- **WS2 — RESOLVE: relink shelf_id.** Backfill `pod_inventory.shelf_id` NULL→resolved shelf
  for the RESOLVE set. Pointer backfill only (NULL→value), zero stock change. Show the full
  per-row list first (memory rule: NULL→value backfill is allowed, list shown first).
  After this, resolved expiry shows correctly in the drawer.
- **WS3 — NO ACTIVE MAPPING: mark Inactive.** Set `pod_inventory.status='Inactive'` for the
  23 unmapped batches (per CS 2026-06-24). Status transition, not delete. Show the row list.
- **WS4 — HIGHLIGHT orphans: write-off path.** Product genuinely off the machine. Transition
  these to `status='Removed/Expired'` with `removal_reason='orphan_not_on_machine'` after CS
  signs off the list. No DELETE. Driver pull is not required (stock not physically on shelf).
- **WS5 — Inactive cleanup ("all inactive should be removed").** The 1,878 existing Inactive
  rows linger with stock. Transition to `status='Removed/Expired'` (removal_reason
  ='inactive_cleanup') so they stop appearing as live inventory; current_stock preserved for
  audit, not zeroed by DELETE. Show CS the aggregate + row list first; forward-only.
  (Article 18 / no-destructive: status transition, never DROP/DELETE.)
- **WS6 — Drawer truth (FE, Stax).** (a) Surface any remaining NULL-shelf / orphan expiry in
  the drawer as an "Unassigned / orphan expiry" section so a header count can never be
  invisible. (b) Populate the empty "Exp Qty" column per slot from the batch nearest-expiry.
  Browser-verify 375px, axe clean.

## Acceptance tests (all must pass; STOP on any failure)

- T1 After WS2, for every RESOLVE batch the drawer slot shows the batch and its Exp Qty; the
  machine's header expired/expiring count == sum of in-drawer expiry (no invisible remainder).
- T2 After WS3/WS4/WS5, `v_machine_expiry_summary` counts only batches that are Active AND
  (shelf-mapped OR surfaced in the orphan section); no Inactive/Removed stock counted.
- T3 No row deleted; every WS3/WS4/WS5 row is a status transition, fully reversible; counts of
  rows in == rows out.
- T4 Resolution parity: RESOLVE/HIGHLIGHT classification recomputed on `v_live_shelf_stock`
  matches the drawer (spot-check WAVEMAKER Coca Cola Zero now classifies correctly).
- T5 No engine impact: engine_add_pod / engine_swap_pod output byte-identical; swaps_enabled
  stays false.

## Governance

`pod_inventory` and the expiry views are protected. Dara designs the resolution query + any
view change; Cody reviews (Hard Rule 6 / Articles on protected entities + no-destructive).
Forward-only. No DELETE, no stock zeroing, no DROP — status transitions and NULL→value
backfills only, each with a CS-reviewed row list.

## Out of scope

P1/P2 priority weighting (PRD-058). Procurement/write-off accounting of the orphaned units.
