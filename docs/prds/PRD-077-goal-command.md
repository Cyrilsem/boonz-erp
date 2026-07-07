# PRD-077 goal command

GOAL: Execute PRD-077 (docs/prds/PRD-077-conservation-merge-gate.md) end to end, AUTO mode. Self-run Dara/Cody/Stax. Apply green pieces, SKIP-and-HIGHLIGHT gate failures, keep PRD-077-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. Depends PRD-076.

HARD GATES: read-only, writes nothing. engine_add_pod/engine_swap_pod/engine_finalize_pod/pick_machines_for_refill md5 byte-identical. Reuse existing check_pod_conservation + PRD-068 guards — do NOT fork conservation logic. Exclude held/quarantined/consignment from WH balance. Integer-exact. BEGIN..ROLLBACK for DDL; forward-only.

WS-1 conservation_check(plan_date, run_id?) -> {status,violations[],totals}: assert (a) plan balance per product/warehouse WH-out==placed+M2W-returned; (b) every referenced batch has >= needed pickable units (canonical predicate shared w/ PRD-079); (c) no orphan REMOVE/M2W (must map to real pod_inventory). Classes: orphan_removal, phantom_batch, oversubscribed_batch, rounding_leak. Modes absolute + delta-vs-baseline.

WS-2 CI wrapper (Stax): fail build on delta violations only.

WS-3 Known-debt baseline: capture today's committed-plan violations; get CS agreement; store as delta reference.

T-TESTS: T1 balanced=>pass. T2 orphan M2W=>fail/orphan_removal. T3 empty batch=>fail/phantom_batch. T4 two-lines-one-batch=>fail/oversubscribed_batch. T5 quarantined excluded (no false pass). T6 record known-debt baseline. T7 prod tables unchanged.

CLOSE: RPC_REGISTRY (conservation_check) + CHANGELOG; PRD-077 SHIPPED + EXECUTION-LOG; commit + push, main==origin/main. ON BLOCKER: append PARKING_LOT.md {item, blocker, needed} and continue.
