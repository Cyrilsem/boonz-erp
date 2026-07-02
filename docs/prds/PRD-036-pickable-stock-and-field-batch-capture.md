# PRD-036: Pickable-stock truth at packing + field-time batch capture

Status: Shipped 2026-07-01 (FEFO dispatch bind, commit e1b9368 on main + prod; 3 prd036 migrations). PRD-071 sweep.

Owner: CS
Date: 2026-06-18
Relationship to PRD-035: PRD-035 WS-C fixes the ENGINE/STITCH side (silent 0-fill when the on-shelf flavor is OOS, WH-aware sibling fallback). This PRD is the DISPATCH/PACKING side (a correctly-planned line still shows pickup 0 because its WH batch is not bound) plus field-time batch capture. Complementary, not overlapping. Do PRD-035 WS-C first if both are in flight.
Surface: Backend (dispatch pickable-stock binding + a field/manual batch-capture path) and FE (packing badge, manual-refill capture fields). Touches protected entities `refill_dispatching`, `warehouse_inventory`, `pod_inventory`. Cody review per writer.
Governance: Dara designs any view/column, Cody reviews each writer, Stax wires FE. Forward-only. No em dashes. Apply nothing to prod without CS sign-off; phased with a STOP per phase.

## Objective

Kill the two systemic failures surfaced by the 08/06-18/06 field log:

1. The picker/packing screen shows pickup quantity 0 even when the warehouse physically holds the stock, forcing drivers to pack manually off the recommended qty.
2. There is no field-time capture of a physical batch + expiry, so almost every visit produces an "Error in the Data: fix WH, pods and log the flow" backlog that has to be hand-logged after the fact.

## Why

Across the period, drivers repeatedly reported (a) "physical stock available in the warehouse but pickup quantity showing as 0, packed manually" (Huawei: Vitamin Well + Pepsi Black; VML5: Coca Cola Zero + Chocolate Bar; OMDBB: VW Antioxidant), and (b) dozens of batch corrections (new purchases, replacements, partials) listed on paper because the system had no way to capture them at the moment of the action. Both push staff off the sanctioned path and cause chronic WH/pod drift, wrong FEFO and expiry alerts, and manual reconciliation.

## Phase A. Pickup qty = 0 despite WH stock (pickable-stock truth)

Fetch live bodies first. Diagnose the gap against the three reported cases, then fix the root cause. Likely contributors (verify, do not assume):

- `from_wh_inventory_id` is not bound at approve time (the FEFO bind step is done manually in the conductor, skipped by the FE), so packing finds no pickable batch and shows 0.
- Stale committed/unpacked dispatch lines hold availability to 0 (the "Available 0" phantom-committed class; `release_stale_unpacked_dispatches` exists, confirm it covers these).
- `v_wh_pickable` (or equivalent) excludes Active-in-date stock that should be pickable.

Deliverables:

- A canonical FEFO-bind step at approve (fold the `from_wh_inventory_id` stamping into `approve_refill_plan`, or a dedicated `bind_dispatch_fefo(plan_date, machine_names[])` RPC) so every Refill/Add New dispatch row has its WH batch bound before packing. DEFINER, role-gated, audited.
- Confirm/extend the stale-unpacked release so genuinely available stock is never shown as 0.
- FE: a pickable-stock badge on the packing screen showing true WH-available units per line, so a 0 is real, not a binding gap (Stax).

Acceptance: re-create the three reported cases (VW/Pepsi at Huawei, Coke Zero/Choc Bar at VML5, VW Antioxidant at OMDBB); after binding, the packing pickup qty equals real WH availability, not 0. Rolled-back tests; prod untouched.

## Phase B. Field-time batch + expiry capture (kill the hand-logging backlog)

The "Error in the Data" backlog exists because new purchases, replacements, and partial placements are not captured with batch + expiry at action time. `log_manual_refill(machine, source_warehouse, refill_date, lines jsonb, reason)` already exists but is not wired to any surface.

Deliverables:

- Extend the Manual Refill tab (PRD from the manual-refill work) and/or the field flow so that when a product is added, replaced, or a new-purchase placement is made, the operator captures qty + expiry + a new-purchase flag. On submit, write WH receipt + pod placement through the canonical path (`log_manual_refill` or `receive_dispatch_line`), not on paper.
- Surface a short "unlogged field corrections" list (from driver notes) until each is captured, so nothing is dropped.

Acceptance: a simulated field correction (e.g., a new purchase with expiry, a replacement) flows entirely in-system: WH batch created with the captured expiry, pod placement updated, zero items left for after-the-fact manual logging. Rolled-back tests; prod untouched.

## Out of scope

The actual data corrections from the 08-18 June log (already reconciled and largely done, tracked in BOONZ BRAIN/Refill_Triage_2026-06-08_to_18.xlsx) and the M2W->Remove+destination redesign (PRD pending).

## Notes

Phase A is the higher-impact fix (it is why drivers distrust the pick list). Phase B removes the root cause of the WH/pod drift. They can ship independently; do Phase A first.
