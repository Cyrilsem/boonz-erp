# PRD-096 goal command

GOAL: Execute PRD-096 (docs/prds/PRD-096-within-pod-relocation.md) AUTO. Self-run Dara/Cody. Keep PRD-096-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. Engine-logic -> SHIP DARK. Flag pod_reloc_v1 (default off). Baseline golden_v2.

HARD GATES: flag OFF => diff_vs_golden(golden_v2) IDENTICAL. Other Family A engines md5 byte-identical. Proposals only, no execution. Relocation unit-neutral (conservation green). Cody PASS. BEGIN..ROLLBACK; forward-only. NEVER enable (CS-only).

WS-1 engine_finalize_pod (behind pod_reloc_v1): for each capacity_mismatch pair, emit a RELOCATE proposal (swap_shelf_pod shape: hv_product hv_shelf->lv_shelf) tagged within_pod_relocation. OFF => warnings only (identical).
WS-2 Capture ON delta via rollback; report relocation proposals. Leave flag OFF.

T-TESTS: T1 flag off => golden_v2 identical. T2 flag on => hv-small/lv-big pair emits within_pod_relocation proposal. T3 proposal approvable not auto-executed. T4 conservation green (unit-neutral). T5 no oversubscription.

CLOSE: CHANGELOG + registry; PRD-096 SHIPPED DARK + EXECUTION-LOG (on-delta for CS); commit+push. ON BLOCKER: PARK to MASTER-PARKING-LOT.md, do NOT ship.
