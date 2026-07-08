# PRD-095 goal command

GOAL: Execute PRD-095 (docs/prds/PRD-095-expiry-risk-swap-trigger.md) AUTO. Self-run Dara/Cody. Keep PRD-095-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. Engine-logic -> SHIP DARK. Flag swap_expiry_v1 (default off). Baseline golden_v2. Self-contained (do NOT block on parked PRD-091).

HARD GATES: flag OFF => diff_vs_golden(golden_v2) IDENTICAL. Other Family A engines md5 byte-identical. Substitute sizing uses PRD-094 product-anchored cap; respect pickable wh_avail. Cody PASS. BEGIN..ROLLBACK; forward-only. NEVER enable (CS-only).

WS-1 engine_swap_pod (behind swap_expiry_v1): extend rotate/dead candidate set with shelves where days_to_expiry_min < expiry_risk_days (v_pod_inventory_latest, or PRD-091 expiry_risk tag if shipped), even velocity>0; resolve via normal substitute path. OFF => zero-velocity-only (identical).
WS-2 Capture ON delta via rollback; report expiry-triggered rotations. Leave flag OFF.

T-TESTS: T1 flag off => golden_v2 identical. T2 flag on => velocity>0 near-expiry shelf enters rotate set + gets substitute. T3 fresh shelves untouched. T4 conservation green. T5 no oversubscription.

CLOSE: CHANGELOG + registry; PRD-095 SHIPPED DARK + EXECUTION-LOG (on-delta for CS); commit+push. ON BLOCKER: PARK to MASTER-PARKING-LOT.md, do NOT ship.
