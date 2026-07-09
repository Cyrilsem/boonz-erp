# PRD-091 goal command

GOAL: Execute PRD-091 (docs/prds/PRD-091-pod-expiry-add-input.md) AUTO. Self-run Dara/Cody. Keep PRD-091-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. Engine-logic -> SHIP DARK. Flag expiry_input_v1 (default off).

HARD GATES: flag OFF => diff_vs_golden IDENTICAL. Other Family A engines md5 byte-identical. Cody PASS. BEGIN..ROLLBACK; forward-only. NEVER enable (CS-only).

WS-1 (Dara) refill_policy_params += expiry_risk_days.
WS-2 engine_add_pod (behind expiry_input_v1): read v_pod_inventory_latest min expiration per shelf -> days_to_expiry_min; if days_to_expiry_min < expiry_risk_days AND velocity>0 emit expiry_pull remediation (REMOVE expiring qty tagged expiry_risk + fresh REFILL). No auto-swap here. OFF => identical.
WS-3 Capture ON delta via rollback; report expiry-risk remediations. Leave flag OFF.

T-TESTS: T1 flag off => golden identical. T2 flag on => performing shelf w/ near-expiry emits expiry_risk remediation. T3 fresh shelf untouched. T4 conservation green. T5 no shelf > wh_avail.

CLOSE: CHANGELOG + registry; PRD-091 SHIPPED DARK + EXECUTION-LOG (on-delta for CS); commit+push. ON BLOCKER: PARK to MASTER-PARKING-LOT.md, do NOT ship.
