# PRD-097 goal command

GOAL: Execute PRD-097 (docs/prds/PRD-097-swap-guards-r7-r3.md) AUTO. Self-run Dara/Cody. Keep PRD-097-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. Engine-logic -> SHIP DARK. Flag swap_guards_v1 (default off). Baseline golden_v2.

HARD GATES: flag OFF => diff_vs_golden(golden_v2) IDENTICAL. Other Family A engines md5 byte-identical. Cody PASS. BEGIN..ROLLBACK; forward-only. NEVER enable (CS-only).

WS-1 engine_finalize_pod (behind swap_guards_v1): (a) R7 hard block machines with swap churn >60% of slots (or require override tag), not just count; (b) R3 net-flow enforce across same-SKU shelves (combined alloc <= combined WH); (c) surface auto-suppressed removals as a suppressed_removal list. OFF => counts-only/unenforced/silent (identical).
WS-2 Capture ON delta via rollback; report R7 blocks, R3 clamps, suppressed-removal surfacing. Leave flag OFF.

T-TESTS: T1 flag off => golden_v2 identical. T2 flag on => >60% machine blocked/override. T3 same-SKU alloc <= combined WH. T4 suppressed removals surfaced. T5 conservation green.

CLOSE: CHANGELOG + registry; PRD-097 SHIPPED DARK + EXECUTION-LOG (on-delta for CS); commit+push. ON BLOCKER: PARK to MASTER-PARKING-LOT.md, do NOT ship.
