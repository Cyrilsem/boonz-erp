/goal PRD-054: clean the WH "Returns awaiting approval" queue. (1) exclude M2M transfers from the queue view, (2) add a durable venue_team (VOX) receive guard so venue-owned returns never credit Boonz WH. MODE AUTO, no questions. Full spec: boonz-erp/docs/prds/PRD-054-returns-queue-m2m-exclusion-and-vox-guard.md. Backend only (view + receive path). Dara design, Cody (Articles 1/4/6/8/12).

CONTEXT (verified): panel PendingRemoveApprovalsPanel reads view v_pending_wh_remove_confirmations (~41 rows). The 7 PRD-052 Vitamin Well rows (is_m2m=true, transfer_id 1538f35f-c386-405b-9cb1-dbc1fba94277) leaked into it because the view does not filter is_m2m. 0 venue_team rows in the queue today, but no guard stops a future venue_team return from crediting Boonz WH.

PRE: git pull --rebase main; branch feat/prd-054-returns-cleanup.

BUILD (forward migrations):

1. VIEW FIX: read the live def of v_pending_wh_remove_confirmations, then CREATE OR REPLACE VIEW adding AND COALESCE(rd.is_m2m,false)=false to its WHERE (change ONLY that predicate; keep columns identical). Removes the 7 PRD-052 rows + any future M2M leg.
2. VOX GUARD: in the WH receive path - wh_approve_remove_receipt, wh_approve_remove_receipt_multivariant, and the Remove branch of receive_dispatch_line - before any warehouse_inventory credit, check EXISTS(product_mapping pm WHERE pm.machine_id=dispatch.machine_id AND pm.boonz_product_id=dispatch.boonz_product_id AND pm.source_of_supply='venue_team'). If true: mark the line received WITHOUT a WH credit (no warehouse_inventory insert/merge; set item_added=true, provenance 'venue_owned_no_credit') instead of crediting Central. Do NOT touch warehouse_inventory.status (Article 6). Keep app.via_rpc + write_audit_log (Article 8). Fetch live bodies via pg_get_functiondef before editing; base migrations on live bodies.

TEST (BEGIN..ROLLBACK first, then apply):

- T1 view returns no is_m2m=true row; 7 PRD-052 rows gone; non-m2m rows unchanged.
- T2 normal boonz return approve -> credits Central WH as before (no regression).
- T3 venue_team return (sim) -> NO warehouse_inventory credit; line resolved 'venue_owned_no_credit'; audited.
- T4 multivariant venue_team return -> guard per variant.
- T5 boonz product on a VOX machine NOT venue_team-mapped still credits WH (guard keys on source_of_supply, not machine name).
- T6 each receive path still writes write_audit_log.
- STOP and report on any failure; do not apply a failing build.

VERIFY post-apply: re-query v_pending_wh_remove_confirmations (7 M2M rows gone, count drops by exactly the is_m2m count); print before/after.

CLOSE: update CHANGELOG.md, MIGRATIONS_REGISTRY.md, RPC_REGISTRY.md; set PRD-054 APPLIED with migration names + verification.

HARD SAFETY: backend only (view recreate + receive-path guard); no warehouse_inventory.status writes; no picker/engine change; swaps_enabled stays false; do NOT auto-approve/cancel any real driver-confirmed return rows (operator triage separate); forward-only migrations; rebase --autostash; do NOT push to main without my explicit go-ahead.
