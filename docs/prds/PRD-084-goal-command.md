# PRD-084 goal command

GOAL: Execute PRD-084 (docs/prds/PRD-084-prepack-drift-guard.md) AUTO mode. Self-run Dara/Cody/Stax. Keep PRD-084-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. Depends PRD-076+077. PARTIAL PRIOR ART PRD-057 (monitor) — add BLOCKING guard, reuse monitor defs. Flag prepack_guard (advisory|block|off).

HARD GATES: engines md5 byte-identical; plan output unchanged (guard acts on dispatch, not plan). Advisory BEFORE block. Whitelist multi-SKU shelves. Per-line block + override; NEVER whole-machine. Cody signs. BEGIN..ROLLBACK; forward-only.

WS-1 multi_sku_shelf(machine_id,shelf_id,reason) allowlist; seed known soft-drink/multi-SKU shelves (AMZ-1029 A12).
WS-2 check_prepack_drift(plan_date,machine_ids?): per refill_dispatching line resolve live WEIMI pod_product via v_live_shelf_stock JOIN shelf_configurations (slot_name=LEFT(shelf_code,1)||(SUBSTR(shelf_code,2)::int)::text, is_phantom=false); compare planned vs resolved; classify ok|sku_mismatch|weimi_unresolved|allowed_multi_sku; intended engine swap (Add New from swap) = ok.
WS-3 Wire after stitch / into pack-readiness. Phase1 advisory(surface+log). Phase2(block) set include=false on sku_mismatch pending override(reason), per-line only.

T-TESTS: T1 reproduce AMZ-1038 A01 (McVities), AMZ-1057 A01 (YoPRO), AMZ-1068 A09 (Hunter) => sku_mismatch. T2 soft-drink => allowed_multi_sku. T3 unresolved => weimi_unresolved. T4 intended swap => ok. T5 block per-line + override. T6 diff plan unchanged.

CLOSE: CHANGELOG + registry; PRD-084 SHIPPED + EXECUTION-LOG; commit + push. ON BLOCKER (intended-swap vs drift ambiguity; incomplete allowlist): append PARKING_LOT.md, stay ADVISORY.
