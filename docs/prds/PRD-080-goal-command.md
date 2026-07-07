# PRD-080 goal command

GOAL: Execute PRD-080 (docs/prds/PRD-080-fefo-reservation-at-approve.md) AUTO mode. Self-run Dara/Cody/Stax. Keep PRD-080-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. Depends PRD-076+077+079. PRIOR ART SHIPPED PRD-036/050; closes PRD-072 residue. Flag fefo_reserve_v1.

HARD GATES: plan ROWS unchanged (only binding meta + reservations added) => diff_vs_golden plan rows identical; conservation green; NO batch oversubscribed; consignment SKUs skipped. engines md5 byte-identical. Cody signs (approve path + warehouse reservation). BEGIN..ROLLBACK; forward-only.

WS-1 VERIFY shipped FEFO bind (PRD-036) + live rebind in pack_dispatch_line; document actual behaviour, no change if correct.
WS-2 (Dara) wh_reservation(reservation_id,wh_inventory_id,dispatch_id,units,plan_date,expires_at,created_at); v_wh_pickable subtracts active reserved units.
WS-3 bind_fefo_reserved(plan_date,machine_ids[]): contention-aware FEFO with per-batch running tally (no oversub); write reservations; call inside approve_pod_refill_plan/stitch; FOR UPDATE by wh_inventory_id.
WS-4 Release on pack/void/reschedule/TTL (fold into release_stale_wh_pins). Retire manual FEFO patch from runbook.

T-TESTS: T1 two lines one 1-unit batch => distinct bind/gap. T2 expire bound batch => rebind ok. T3 re-approve no leaked reservations. T4 concurrent approve no oversub. T5 diff plan rows unchanged. T6 conservation green.

CLOSE: update PRD-072 residue; CHANGELOG + registry; PRD-080 SHIPPED + EXECUTION-LOG; commit + push. ON BLOCKER (reservation-table vs pin decision, TTL value): append PARKING_LOT.md, ship table+predicate, keep approve wiring OFF until resolved.
