# PRD-090 goal command

GOAL: Execute PRD-090 (docs/prds/PRD-090-niche-merchandising-fill.md) AUTO. Self-run Dara/Cody/Stax. Keep PRD-090-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. Engine-logic -> SHIP DARK. Flag add_niche_fill_v1 (default off).

HARD GATES: flag OFF => diff_vs_golden IDENTICAL. Other Family A engines md5 byte-identical. Never promise held/quarantined WH (use PRD-079 pickable wh_avail). Cody PASS. BEGIN..ROLLBACK; forward-only. NEVER enable (CS-only).

WS-1 (Dara) refill_policy_params += niche_footprint_max, niche_facing_target.
WS-2 engine_add_pod (behind add_niche_fill_v1): footprint = COUNT(DISTINCT active machines per pod_product); if footprint<=niche_footprint_max AND shelf is best location (max v30), need_raw=GREATEST(cover_units, niche_facing_target) clamped to shelf cap AND pickable wh_avail. OFF => identical.
WS-3 Capture ON delta via rollback; report niche fills + any held/procurement surfacing. Leave flag OFF.

T-TESTS: T1 flag off => golden identical. T2 flag on => niche SKU w/ pickable WH filled to facing. T3 SF Pancake (WH quarantined) => held/procurement, not phantom fill. T4 conservation green. T5 no shelf > pickable wh_avail.

CLOSE: CHANGELOG + registry; PRD-090 SHIPPED DARK + EXECUTION-LOG (on-delta for CS); commit+push. ON BLOCKER: PARK to MASTER-PARKING-LOT.md, do NOT ship.
