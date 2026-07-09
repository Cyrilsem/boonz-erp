# PRD-098 Execution Log — Return Approval Workflow

Run 2026-07-09/10, AUTO. **Status: SHIPPED.** Backend only; NO refill-engine edit
(Family-A md5 UNCHANGED: add=b91c530b / swap=a69c2df8 / finalize=55141509 / pick=48cc1844).
Cody PASS (⚠️→revisions applied: role set incl 'manager'; append-only policies). No auto-release
(policy) — the manager works the queue.

## Baseline (2026-07-09)
- `dispatch_return_unverified` w/ stock>0 (ongoing backlog): **24** rows (v_pending_return_approvals).
- `unknown_pre_migration` w/ stock>0 (legacy, one-time): **42** rows (v_pending_legacy_quarantine).
  **WS-4 split: 19 recoverable (future expiry) / 23 expired.** (PRD stated 68/50; data has moved since.)

## Shipped
- **Table** `return_approval_log` (append-only: SELECT true / UPDATE false / DELETE false, Article 7).
- **Views** `v_pending_return_approvals` (WS-1) + `v_pending_legacy_quarantine` (WS-4) — enriched, read-only.
- **`approve_return(wh_inventory_id, approver_id, note, corrected_expiry?, corrected_qty?)`** — role-gated
  (warehouse/operator_admin/superadmin/manager), sets `provenance_reason='dispatch_return'` → the GENERATED
  `quarantined` flips false ⇒ pickable. Optional expiry/qty correction. Audited. NO status write (Article 6).
- **`reject_return(wh_inventory_id, approver_id, reason)`** — drains `warehouse_stock=0`+`disposal_reason='Waste'`
  then the canonical `inactivate_warehouse_row` (status='Inactive'); guarded for already-Inactive rows. Audited.
- **`cron_pending_return_alert(days=3)`** + pg_cron `prd098_pending_return_alert` (daily 06:00, job 37) →
  monitoring_alerts if backlog ages (never-silent-again).

## T-tests (rolled-back real-data runs)
| T | Result |
|---|---|
| T1 v_pending lists the unverified backlog | PASS (24) |
| T2 approve_return ⇒ row in v_wh_pickable + audit | PASS |
| T3 reject_return ⇒ Inactive, not pickable, audit | PASS |
| T4 non-manager (field_staff) rejected | PASS (forbidden) |
| T5 corrected expiry/qty applied + audited | PASS (exp+90, qty=7) |
| T6 Family-A md5 unchanged + plan-neutral | PASS (engines untouched; no plan write) |

## Article-6 compliance
Approve never writes `status` (quarantined is generated from provenance_reason). Reject delegates the
status transition to the canonical `inactivate_warehouse_row`. Writer-gate satisfied via app.via_rpc/rpc_name.

## Cleared counts
0 auto-cleared (policy: manager approval required). Backlog handed to the manager queue (24 pending +
42 legacy). FE returns-approval queue = Stax follow-up.

## Status: SHIPPED (backend). FE queue = Stax follow-up.
