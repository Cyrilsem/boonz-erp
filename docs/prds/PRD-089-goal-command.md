# PRD-089 goal command

GOAL: Execute PRD-089 (docs/prds/PRD-089-add-absolute-velocity-floor.md) AUTO. Self-run Dara/Cody/Stax. Keep PRD-089-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. Engine-logic change -> SHIP DARK only; do NOT enable. Flag add_abs_floor_v1 (default off).

HARD GATES: flag OFF => refill_qa.diff_vs_golden IDENTICAL (inertness proof — REQUIRED to ship). Other Family A engines (engine_swap_pod, engine_finalize_pod, pick_machines_for_refill) md5 byte-identical. Cody PASS. BEGIN..ROLLBACK; forward-only. NEVER enable the flag (CS-only after delta review).

WS-1 (Dara) refill_policy_params += abs_velocity_floor, min_facing_floor.
WS-2 engine_add_pod: gate on add_abs_floor_v1; when ON, force band_fraction=1.0 for shelves with v30/30>=abs_velocity_floor OR v7>=abs_velocity_floor; cover_units=GREATEST(cover_units,min_facing_floor) for velocity>0; keep clamps to max_stock-current_stock and wh_avail. When OFF, identical to today.
WS-3 Capture the ON delta via rollback-on-prod (BEGIN..ROLLBACK, set flag on in-txn, run engine, diff_vs_golden, ROLLBACK). Report top changed shelves + unit deltas in the EXECUTION-LOG. Leave flag OFF in prod.

T-TESTS: T1 flag off => golden identical. T2 flag on => band-3 shelf with velocity>=floor gets full cover. T3 velocity>0 shelves >= min_facing_floor. T4 conservation green. T5 no shelf > wh_avail.

CLOSE: CHANGELOG + registry; PRD-089 SHIPPED DARK + EXECUTION-LOG (with on-delta for CS); commit+push. ON BLOCKER (flag-off not identical): PARK to MASTER-PARKING-LOT.md, do NOT ship.
