# PRD-094: Product-anchored swap caps (fix cap-stuck-on-old-product)

Status: PARKED 2026-07-09 (rule F: Wave-2 spec drift vs rewritten engine / dependencies; + concurrent engine modification mid-run). NOT shipped. See EXECUTION-LOG.
Owner: CS. Mode: AUTO with hard gates. Dara designs, Cody reviews.

## Why

When a product is swapped onto a shelf, the incoming quantity is sized from the **shelf's** capacity, not the new product's. In `engine_swap_pod`: Pass 1 (tag) `qty_in = GREATEST(shelf_weimi_max/2, 4)`; Pass 2 (dead-resolution) `qty_in = v_shelf_max_stock` (= the OUTGOING product's WEIMI calibration). Only Pass 3 uses `slot_profile_pool` / `product_slot_capacity_units(new_physical_type, shelf_size)`. So most swaps make the new product inherit the old product's cap — over- or under-stuffing the shelf.

## Design (Dara designs, Cody reviews)

1. In `engine_swap_pod` Pass 1 & Pass 2, size `qty_in` from the **incoming** product: `product_slot_capacity_units(incoming.physical_type, shelf.shelf_size)` via `slot_profile_pool` (the same source Pass 3 already uses), clamped to pickable `wh_avail` (PRD-079). Behind `swap_prod_cap_v1`.
2. Flag off ⇒ Passes 1/2 keep today's shelf-cap sizing (byte-equivalent).
3. Case 5 (not-performing → swap) inherits this fix automatically — its substitute is now sized to the new product.

## Gates

- Flag OFF ⇒ `diff_vs_golden` (golden_v2) IDENTICAL. Flag ON ⇒ capture delta; a swap of product B onto A's shelf yields **B's** cap, not A's; conservation green; no oversubscription (respects pickable WH). Other Family-A engines (`engine_add_pod`, `engine_finalize_pod`, `pick_machines_for_refill`) md5 byte-identical. Cody signs.

## T-tests

- T1 flag off ⇒ golden_v2 identical.
- T2 flag on ⇒ a Pass-2 dead-resolution swap sizes `qty_in` to `product_slot_capacity_units(new)`, not `v_shelf_max_stock`.
- T3 flag on ⇒ a Pass-1 tag swap likewise product-anchored.
- T4 conservation green; T5 no `qty_in > pickable wh_avail`.

## CLOSE

CHANGELOG + registry; PRD-094 SHIPPED DARK + EXECUTION-LOG (on-delta for CS); commit+push. Enable = CS flips `swap_prod_cap_v1=on` after delta review. Rollback = flag off.
