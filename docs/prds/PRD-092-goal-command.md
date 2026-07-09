# PRD-092 goal command

GOAL: Execute PRD-092 (docs/prds/PRD-092-no-wh-action.md) AUTO. Self-run Dara/Cody. Keep PRD-092-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. Engine-logic -> SHIP DARK. Flag add_nowh_action_v1 (default off).

HARD GATES: flag OFF => diff_vs_golden IDENTICAL. Other Family A engines md5 byte-identical. Proposals only, no execution. Respect pickable WH / source surplus (no oversubscription). Cody PASS. BEGIN..ROLLBACK; forward-only. NEVER enable (CS-only).

WS-1 engine_add_pod (behind add_nowh_action_v1): for clamp_reason='blocked_no_wh': (a) find_substitutes_for_shelf with pickable WH>=min -> emit nowh_substitute proposal; (b) else surplus-machine holding same pod_product above its need -> emit nowh_m2m proposal; (c) else keep procurement_gaps. OFF => identical.
WS-2 Capture ON delta via rollback; report substitute/M2M/procurement counts. Leave flag OFF.

T-TESTS: T1 flag off => golden identical. T2 blocked shelf w/ substitute => nowh_substitute. T3 blocked shelf w/ surplus source => nowh_m2m. T4 truly-out => procurement alert (no silent empty). T5 conservation green, no oversubscription.

CLOSE: CHANGELOG + registry; PRD-092 SHIPPED DARK + EXECUTION-LOG (on-delta for CS); commit+push. ON BLOCKER: PARK to MASTER-PARKING-LOT.md, do NOT ship.
