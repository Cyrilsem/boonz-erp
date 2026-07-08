# PRD-094 goal command

GOAL: Execute PRD-094 (docs/prds/PRD-094-product-anchored-swap-caps.md) AUTO. Self-run Dara/Cody. Keep PRD-094-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. Engine-logic -> SHIP DARK. Flag swap_prod_cap_v1 (default off). Baseline = golden_v2.

HARD GATES: flag OFF => diff_vs_golden(golden_v2) IDENTICAL. Other Family A engines (engine_add_pod, engine_finalize_pod, pick_machines_for_refill) md5 byte-identical. Respect pickable wh_avail (no oversubscription). Cody PASS. BEGIN..ROLLBACK; forward-only. NEVER enable (CS-only).

WS-1 engine_swap_pod Pass 1 & 2 (behind swap_prod_cap_v1): size qty_in from product_slot_capacity_units(incoming.physical_type, shelf.shelf_size) via slot_profile_pool (same source Pass 3 uses), clamped to pickable wh_avail. OFF => identical.
WS-2 Capture ON delta via rollback (flip flag in-txn, run engine, diff_vs_golden(golden_v2) + conservation_check, ROLLBACK). Report swaps whose qty_in changed. Leave flag OFF.

T-TESTS: T1 flag off => golden_v2 identical. T2 flag on => Pass-2 dead-resolution swap sized to product_slot_capacity_units(new), not v_shelf_max_stock. T3 Pass-1 tag swap product-anchored. T4 conservation green. T5 no qty_in > pickable wh_avail.

CLOSE: CHANGELOG + registry; PRD-094 SHIPPED DARK + EXECUTION-LOG (on-delta for CS); commit+push. ON BLOCKER (flag-off not identical, cody FAIL): PARK to MASTER-PARKING-LOT.md, do NOT ship.
