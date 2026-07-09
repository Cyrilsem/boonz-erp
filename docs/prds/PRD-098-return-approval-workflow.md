# PRD-098: Return Approval Workflow (kill the quarantine backlog for good)

Status: SHIPPED 2026-07-10 (backend; approve/reject_return + pending views + append-only log + cron; Cody PASS; Family-A unchanged). FE queue = Stax follow-up. See EXECUTION-LOG.

## Why (root cause — verified in `return_dispatch_line`)

When stock is returned, `return_dispatch_line` merges it into an **existing** warehouse batch matching product+expiry → provenance `dispatch_return` (**pickable**). When **no existing batch matches**, it creates a **new** row stamped `dispatch_return_unverified` → the generated `quarantined` column flips **true** (invisible to picking). That quarantine is correct safety — _don't sell un-reconciled returned stock_. **The gap: there is no step that ever releases them.** They sit forever.

**Baseline (2026-07-09):** 180 units invisible — 62 `dispatch_return_unverified` (ongoing, ~12 units/week; all have a known future expiry) + 118 `unknown_pre_migration` (one-time migration artifact, 68 recoverable / 50 expired). ~130 recoverable units of real stock are stranded.

**CS policy decision:** returns must be **approved by an inventory manager** before re-entering pickable inventory. So we do NOT auto-release — we build the missing approval path.

## Design (Dara designs, Cody reviews, Stax wires)

1. **`v_pending_return_approvals`** — the manager's worklist: every `warehouse_inventory` row with `provenance_reason='dispatch_return_unverified' AND warehouse_stock>0`, enriched with product name, qty, expiration_date, days_to_expiry, origin (machine/dispatch), warehouse, and age. Read-only.
2. **`approve_return(p_wh_inventory_id uuid, p_approver_id uuid, p_note text, p_corrected_expiry date DEFAULT NULL, p_corrected_qty numeric DEFAULT NULL)`** — role-gated to **inventory manager** (`role IN ('warehouse','operator_admin','superadmin')`; Dara/Cody confirm exact set). Optionally corrects expiry/qty, then sets `provenance_reason='dispatch_return'` → `quarantined` flips false → the units become pickable. Writes an audit row (approver, at, note, before/after). SECURITY DEFINER, forward-only.
3. **`reject_return(p_wh_inventory_id uuid, p_approver_id uuid, p_reason text)`** — for damaged / expired / not-actually-returned stock: write off (`status='Inactive'`, `warehouse_stock=0`), audited. Keeps it out of pickable without deleting the audit trail.
4. **Backlog:** the current 62 flow straight into `v_pending_return_approvals` — the manager works the queue (no auto-release, per policy).
5. **Legacy `unknown_pre_migration` (separate one-time):** a companion `v_pending_legacy_quarantine` + the same approve/reject, so a manager clears the 68 recoverable and writes off the 50 expired. One-time; not part of the ongoing return flow.
6. **"Never silent again":** `cron_pending_return_alert` — flags any pending approval older than N days so the queue can't quietly rebuild. No change to `return_dispatch_line` (it correctly quarantines).

## Gates

- Additive (1 view + 2 RPCs + 1 alert); the only mutation is the provenance flip on approve/reject → Cody signs. **Does NOT touch the refill engines** → Family-A md5 unchanged; `diff_vs_golden` unaffected (no plan impact). Role-gated; every action audited. Forward-only.

## T-tests

- T1 `v_pending_return_approvals` lists the 62 current unverified units.
- T2 `approve_return` on one row ⇒ it appears in `v_wh_pickable` afterward (pickable); audit recorded.
- T3 `reject_return` ⇒ written off, not pickable, audited.
- T4 a non-manager role is rejected.
- T5 corrected expiry/qty is applied and audited.
- T6 refill engines untouched (Family-A md5 unchanged; a plan `diff_vs_golden` = identical).

## CLOSE

CHANGELOG + RPC_REGISTRY; PRD-098 SHIPPED + EXECUTION-LOG (baseline counts + how many cleared); commit+push. FE returns-approval queue = a Stax follow-up (backend ships first). Rollback = drop the view/RPCs (approve/reject already-applied flips stay, they're valid data).
