# PRD-094: Product-anchored swap caps (fix cap-stuck-on-old-product) — RE-SPEC'd

Status: RE-SPEC'd 2026-07-09 against the LIVE `engine_swap_pod` (md5 `ac953f99`, ~30.5KB). Bug re-confirmed present in Passes 1 & 2. Ready to ship DARK **during a Family-A engine change-freeze window** (the 2026-07-09 run parked because a concurrent session changed `pick_machines_for_refill` mid-run). Flag `swap_prod_cap_v1` (default off).
Owner: CS. Mode: AUTO with hard gates. Dara designs, Cody reviews.

## Why (verified against current source, not the original snapshot)

`qty_in` for an incoming (swapped-in) product is still sized from the **shelf's** WEIMI capacity, not the new product's, in two of three passes:

- **Pass 1 (strategic tag) & Pass 2 (dead/rotate resolution):** `SELECT MAX(sms.max_stock_weimi) INTO v_shelf_cap FROM public.v_shelf_max_stock sms …` then `qty_in = LEAST(GREATEST(v_shelf_cap, 8), 1)` (clamped to WH stock). `v_shelf_cap` = the shelf's WEIMI max = the **outgoing** product's calibration → the new product inherits the old product's cap.
- **Pass 3 (value-model broad):** correctly uses `product_slot_capacity_units(physical_type, shelf_size) * 0.85` via `slot_profile_pool` (product-anchored). This is the pattern to copy.

So the keystone bug (audit Case 10 / Cause B) is **still real in Passes 1 & 2**; only Pass 3 is correct. The engine was rewritten (new 3-pass shape) since the original PRD, but the defect survived — the fix target just moved.

## Design (Dara designs, Cody reviews)

1. In Pass 1 & Pass 2, replace the shelf-cap sizing of `qty_in` with the **incoming product's** cap, computed exactly as Pass 3 does: `product_slot_capacity_units(incoming.physical_type, shelf.shelf_size)` via `slot_profile_pool` (join on the candidate/incoming `boonz_product_id`), then `qty_in = LEAST(GREATEST(product_cap, 1), pickable_wh_avail)`. Keep the `>=1` floor. Behind `swap_prod_cap_v1`.
2. Flag OFF ⇒ Passes 1/2 keep `v_shelf_cap`-based sizing byte-for-byte (inert).
3. Case 5 (not-performing → swap) inherits the fix — its substitute is now sized to the new product.

## Gates

- **Coordination gate (NEW):** only apply/validate while Family-A engine md5s are stable for the whole run (no concurrent engine migrations). If a Family-A md5 changes mid-run → PARK (byte-identity gate cannot hold).
- Flag OFF ⇒ `diff_vs_golden`(golden_v2) IDENTICAL. Flag ON ⇒ capture delta; a Pass-1/Pass-2 swap sizes `qty_in` to the incoming product's cap, not `v_shelf_cap`; conservation green; no oversubscription (respects pickable `wh_avail`). Other Family-A engines (`engine_add_pod`, `engine_finalize_pod`, `pick_machines_for_refill`) md5 byte-identical. Cody signs.

## T-tests

- T1 flag off ⇒ golden_v2 identical.
- T2 flag on ⇒ a Pass-2 dead-resolution swap sizes `qty_in` to `product_slot_capacity_units(incoming)`, not `MAX(max_stock_weimi)`.
- T3 flag on ⇒ Pass-1 tag swap likewise product-anchored.
- T4 conservation green; T5 no `qty_in > pickable wh_avail`; T6 Pass-3 behaviour unchanged.

## CLOSE

CHANGELOG + registry; PRD-094 SHIPPED DARK + EXECUTION-LOG (on-delta for CS); commit+push. Enable = CS flips `swap_prod_cap_v1=on` after delta review. Rollback = flag off. **Prereq: an engine-freeze window.**
