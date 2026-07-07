# PRD-079 goal command

GOAL: Execute PRD-079 (docs/prds/PRD-079-availability-gate-held-state.md) AUTO mode. Self-run Dara/Cody/Stax. Keep PRD-079-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. Depends PRD-076+077 (referee green on golden_v1). PRIOR ART SHIPPED PRD-045/036 — VERIFY + add held-state, do NOT re-implement. Flag wh_gate_v2.

HARD GATES: pickable SET unchanged (additive representation only) — PROVE via diff_vs_golden identical AND engine_add_pod.wh_avail equal to pre-change values on golden inputs; if plan output moves => STOP + PARK. engines md5 byte-identical except the wh_avail subquery refactor which must be output-identical. Cody signs. BEGIN..ROLLBACK; forward-only.

WS-1 (Dara) wh_is_pickable(wi,machine_id,today) = current predicate. Rewrite v_wh_pickable on it. Point engine_add_pod.wh_avail + PRD-077 at the same fn (remove divergent inline copies).
WS-2 v_wh_stock_state: per batch pickable_units + held_units by {quarantined,pinned_other_machine,inactive,expired,consumer_moved}.
WS-3 Packing availability read returns pickable + held{by class}. (FE render = separate Stax task.)

T-TESTS: T1 SF Pancake => 0 pickable, 38 held.quarantined. T2 pinned-elsewhere => held. T3 consumer_moved. T4 diff_vs_golden identical. T5 conservation green. T6 wh_avail == old on golden (divergence guard).

CLOSE: CHANGELOG + registry; PRD-079 SHIPPED + EXECUTION-LOG; commit + push. ON BLOCKER (esp. T6 divergence): append PARKING_LOT.md and keep flag OFF.
