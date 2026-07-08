# PRD-094 Execution Log — Product-anchored swap caps (PARKED)

Run 2026-07-09 overnight, AUTO. **Status: PARKED (rule F: spec drift). NOT shipped.**

## Why parked

The live `engine_swap_pod` (30KB) has been **rewritten** since PRD-094 was authored. The spec's
design anchors do not exist: Pass-1 `qty_in = GREATEST(shelf_weimi_max/2,4)` — `shelf_weimi_max`
has **0 occurrences**; Pass-2 `qty_in = v_shelf_max_stock` — `v_shelf_max_stock` is now a **view**
(joined as `sms`), not a qty_in assignment. The current engine already **partially product-anchors**
(`product_slot_capacity_units(k.inc_phys, k.shelf_size)*0.85` in the pool pass). Whether the
"cap-stuck-on-old-product" bug still exists in the rewritten engine is unclear.
Implementing the intent would require reverse-engineering the 30KB Family-A engine against a spec
that no longer maps — the exact blind-edit risk that produced the PRD-090 footprint bug.

## Needed to un-park

Dara re-specs PRD-094 against the CURRENT `engine_swap_pod` 3-pass structure: identify the
remaining shelf-cap `qty_in` sizings (the `qty_in = LEAST(GREATEST(v_shelf_cap,8,1), wh_stock)`
form), confirm the incoming product's physical_type + shelf_size are in scope, and give exact
anchors. Then build behind `swap_prod_cap_v1`, prove flag-off identical vs golden_v2, Cody PASS.

## Status: PARKED (rule F: engine_swap_pod rewritten; spec anchors absent). Owner: Dara + CS.
