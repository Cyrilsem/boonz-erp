# Amendment 008 — `pod_inventory_edits` to Appendix A

**Status:** Ratified
**Filed:** 2026-05-25
**Article amended:** 15 (governance) — invokes the amendment process to extend Appendix A of the Constitution
**Trigger event:** PRD-012 Phase 1 review (Cody flagged at P1.A)
**Linked PRD:** [`docs/prds/inventory/prd_012_driver_pod_add_workflow.md`](../prds/inventory/prd_012_driver_pod_add_workflow.md)

---

## Context

Phase 1 of PRD-012 (driver pod add workflow) added three SECURITY DEFINER canonical writers that drive a propose-then-approve lifecycle on `pod_inventory_edits` for the new `edit_type = 'add_new_product'`. The approve RPC then INSERTs into `pod_inventory` (Appendix A) on success. By the Amendment 007 precedent — which elevated `inventory_control_session` and `inventory_control_attempt` because they govern writes to a protected entity — `pod_inventory_edits` belongs in Appendix A for the same reason: it is the proposal substrate for `pod_inventory` writes via the new flow.

Cody flagged this at P1.A review and again at P1.B/C/D review. The migrations applied today (`prd_012_pod_inventory_edits_add_flow`, `prd_012_extend_pod_inventory_edits_check_whitelists`, `prd_012_relax_add_flow_check`, the three RPCs, and the auto-expire cron) all shipped with a Phase 3 binding to file this amendment before Phase 3 close.

## The complication — existing edit_type callers

Amendment 007 had a clean shape because `inventory_control_session` and `inventory_control_attempt` are net-new tables and their write paths are exclusively the new RPCs (plus the narrow FE INSERT exception on `inventory_control_attempt` for network-error capture). Amendment 008 cannot have that clean shape because `pod_inventory_edits` has been in production since before the constitution and has received direct FE INSERTs from drivers for the existing edit types: `sold`, `partial_sold`, `expired`, `return_to_warehouse`, `transfer`, `in_stock`. Those FE-direct flows are not in PRD-012 scope; migrating them to canonical RPCs is the explicit charter of PRD-013 (canonical approval).

So Amendment 008 codifies the table as Appendix A with a tiered exception: the new `add_new_product` subset is RPC-only (no FE-direct INSERT), while the legacy subsets are grandfathered until PRD-013 migrates them.

## Findings — what Amendment 008 codifies

1. `pod_inventory_edits` joins Appendix A under "Core entities (RLS + canonical RPC required)".
2. **For `edit_type = 'add_new_product'`** (PRD-012 surface):
   - **INSERT**: only via `propose_pod_inventory_add` (SECURITY DEFINER, field_staff + manager roles).
   - **UPDATE to status = 'approved'**: only via `approve_pod_inventory_add` (SECURITY DEFINER, manager roles).
   - **UPDATE to status = 'rejected'**: only via `reject_pod_inventory_add` (SECURITY DEFINER, manager roles).
   - **UPDATE to status = 'expired'**: only via `auto_expire_pod_add_proposals` (SECURITY DEFINER, cron).
   - **DELETE**: forbidden.
3. **For all other `edit_type` values** (sold / partial_sold / expired-as-edit-type / return_to_warehouse / transfer / in_stock):
   - **INSERT**: still allowed via FE direct under the existing `field_staff_insert_edits` RLS policy. **Grandfathered, owned by PRD-013.**
   - **UPDATE**: still allowed via FE direct under the existing `reviewers_update_edits` RLS policy. **Grandfathered, owned by PRD-013.**
   - These legacy writers do NOT set `app.via_rpc='true'`. Once PRD-013 migrates them, this exception expires.
4. **Forensic discriminator:** `edit_type` is the boundary. Add-new-product rows can only be created/mutated by the four canonical writers above; legacy rows continue under the existing FE pattern.
5. Append-only-log status: pod_inventory_edits is NOT append-only — UPDATE is required for the review-decision flow. It belongs in "Core entities", not in "Append-only logs".
6. Audit trigger expectation: the generic `tg_audit_*` trigger should be installed on `pod_inventory_edits` so that every canonical writer's UPDATE/INSERT lands in `write_audit_log`. The legacy FE-direct writes will NOT carry `app.via_rpc` so they will appear in the audit log without rpc_name attribution — that's the explicit signal for PRD-013 to migrate.

## Constitutional articles affected

- **Article 15 (governance)**: invoked to amend Appendix A.
- **Article 1 (write paths)**: confirmed — `propose_pod_inventory_add`, `approve_pod_inventory_add`, `reject_pod_inventory_add`, `auto_expire_pod_add_proposals` are the canonical writers for the `add_new_product` subset.
- **Article 3 (authenticated writes)**: tiered carve-out as described. PRD-013 closes the legacy gap.
- **Article 4 (DEFINER validates)**: the four canonical writers all set `app.via_rpc='true'` plus `app.rpc_name` plus `app.mutation_reason`.
- **Article 5 (status state machine)**: the four canonical writers enforce the directed graph (pending → approved | rejected | expired; no reverse transitions).
- **Article 7 (audit logs)**: pod_inventory_edits is NOT an append-only audit log (UPDATE required); placement is in "Core entities".

## Forward implications

- **Phase 3 of PRD-012** can close after this amendment lands; the cron + the three RPCs all become Article-15-compliant.
- **PRD-013 (canonical approval)** picks up the legacy FE-direct INSERT/UPDATE callers for the non-add edit_types. When PRD-013 completes, this amendment's tiered exception collapses: every write to pod_inventory_edits will be via a canonical RPC, and the FE direct INSERT pattern + the `field_staff_insert_edits` + `reviewers_update_edits` policies can be retired (Phase B perimeter close).
- **Audit trigger install**: a follow-up migration should install `tg_audit_pod_inventory_edits` mirroring the `tg_audit_pod_inventory` shape from A.4. Not blocking this amendment.

## Ratification

Reviewed by Cody (2026-05-25). Applied to constitution.html in the same commit as this markdown file.
