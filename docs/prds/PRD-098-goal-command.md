# PRD-098 goal command

GOAL: Execute PRD-098 (docs/prds/PRD-098-return-approval-workflow.md) AUTO. Self-run Dara/Cody/Stax. Keep PRD-098-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. Freeze-INDEPENDENT (does NOT touch refill engines). commit+push (main==origin/main).

POLICY: returns require inventory-manager approval before re-entering pickable inventory. Do NOT auto-release. Do NOT change return_dispatch_line's quarantine behaviour.

HARD GATES: no edit to engine_add_pod/engine_swap_pod/engine_finalize_pod/pick_machines_for_refill (record md5 start+end, must match). Only mutation = provenance flip on approve/reject (warehouse_inventory) => `cody` PASS REQUIRED. Role-gated + audited. forward-only; npm build green. A plan diff_vs_golden must stay IDENTICAL (this work is plan-neutral).

WS-1 v_pending_return_approvals: warehouse_inventory rows where provenance_reason='dispatch_return_unverified' AND warehouse_stock>0, enriched (product name, qty, expiration_date, days_to_expiry, origin machine/dispatch, warehouse, age). Read-only.
WS-2 approve_return(p_wh_inventory_id, p_approver_id, p_note, p_corrected_expiry default null, p_corrected_qty default null): role IN ('warehouse','operator_admin','superadmin') (confirm w/ Cody); optionally correct expiry/qty; SET provenance_reason='dispatch_return' (=> quarantined=false => pickable); write audit (approver, at, note, before/after). SECURITY DEFINER.
WS-3 reject_return(p_wh_inventory_id, p_approver_id, p_reason): write off (status='Inactive', warehouse_stock=0), audited.
WS-4 (one-time, separate) v_pending_legacy_quarantine for provenance_reason='unknown_pre_migration'; same approve/reject applies. Report the 68 recoverable / 50 expired split for the manager.
WS-5 cron_pending_return_alert: flag pending approvals older than N days.

T-TESTS: T1 v_pending lists the 62. T2 approve_return -> row now in v_wh_pickable + audit. T3 reject_return -> written off + audit. T4 non-manager rejected. T5 corrected expiry/qty applied+audited. T6 Family-A md5 unchanged + plan diff_vs_golden identical.

CLOSE: CHANGELOG + RPC_REGISTRY; PRD-098 SHIPPED + EXECUTION-LOG (baseline + cleared counts); commit+push. Backend only; FE queue = Stax follow-up. ON BLOCKER (role set undecided, audit-table shape): append MASTER-PARKING-LOT.md and continue with the non-blocked WS.
