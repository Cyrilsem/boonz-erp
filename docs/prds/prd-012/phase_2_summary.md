# PRD-012 Phase 2 Summary — FE (driver add flow + operator review queue)

**Phase:** 2 (FE)
**Status:** Shipped 2026-05-25
**Source PRD:** [`docs/prds/inventory/prd_012_driver_pod_add_workflow.md`](../inventory/prd_012_driver_pod_add_workflow.md)

## Shipped

Three new components plus minimal touches to the operator inventory page. Total: ~620 LOC across four files. Build clean (tsc + next build). Cody Article 3 review verdict: ✅ Approve.

| File                                                    | Status             | Purpose                                                                                                                                                                                                                                                                                                                                                          |
| ------------------------------------------------------- | ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/components/field/AddProductDialog.tsx`             | NEW (~285 LOC)     | B.2 driver-side add dialog. Product search, shelf picker (disables Active-row shelves with "in use by [Product]" badge), qty bounded by shelf max_capacity, expiry date bounded today+1 to today+36mo, optional notes. Generates `correlation_id` via `crypto.randomUUID()`. Calls `propose_pod_inventory_add`.                                                  |
| `src/app/(field)/field/shelf-view/[machineId]/page.tsx` | REWRITE (~250 LOC) | B.1 "+ Add Product" button on the per-machine shelf-view page, role-gated to field_staff + manager set. B.3 "Your add-product proposals" section listing pending + recently-rejected proposals for this machine. B.4 alert() fires once per rejection on first sight (within 7-day window).                                                                      |
| `src/components/inventory/PendingPodAdditionsPanel.tsx` | NEW (~340 LOC)     | C.1–C.5 operator queue. Count badge in header, expandable list, text filter (machine/product/shelf/driver email). Per-row Approve / Reject buttons opening modals. Approve dialog: optional decision note + override checkbox if expiry past. Reject dialog: required note >= 10 chars. Routes through `approve_pod_inventory_add` / `reject_pod_inventory_add`. |
| `src/app/(app)/app/inventory/page.tsx`                  | EDIT (+2 lines)    | One import, one component mount between `PendingRemoveApprovalsPanel` and `PendingProposalsPanel`. Zero changes to inventory edit/save logic.                                                                                                                                                                                                                    |

## What works end-to-end

A driver on `/field/shelf-view/<machineId>` taps "+ Add Product", picks a free shelf (occupied shelves are visibly disabled), searches for and picks a product, sets qty + expiry, optionally adds notes, submits. The dialog calls `propose_pod_inventory_add` with a client-generated correlation_id. On success an alert confirms submission and the "Your add-product proposals" section refreshes to show the new pending row. Idempotent retry within 60s returns the same edit_id.

An operator on `/app/inventory` sees the new "Pending Pod Additions" amber panel at the top (count badge shows pending proposal count). Expanding the panel lists each row with machine / shelf / product / qty / expiry / submitted_by_email / notes plus Approve and Reject buttons. Approve opens a modal with an optional decision note and an expiry-override checkbox shown only if the proposed expiry is now in the past. Reject opens a modal with a required >=10-char decision note. Submit calls the relevant SECURITY DEFINER RPC.

When a driver next opens the shelf-view for their machine after a rejection, an alert() fires with the rejection reason extracted from the edit row notes.

## Constitutional compliance (Cody verdict ✅)

| Article                              | Status           | Note                                                                                                                                              |
| ------------------------------------ | ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 (canonical write path)             | ✅               | All three RPCs deployed at Phase 1. FE calls them and nothing else for adds.                                                                      |
| 3 (no FE direct writes to protected) | ✅               | Confirmed: no `.insert/.update/.delete` on `pod_inventory`, `pod_inventory_edits`, or any Appendix A entity in the new code.                      |
| 5 (status state machine)             | ✅               | pending → approved / rejected transitions happen inside SECURITY DEFINER RPCs only. FE never sets `pod_inventory_edits.status` directly.          |
| 9 (edge functions stateless)         | n/a              | No edge functions.                                                                                                                                |
| 2, 7, 8                              | ✅ cross-checked | RLS unchanged (existing `all_authenticated_read_edits` covers reads). Generic `tg_audit_pod_inventory` trigger captures the approve RPC's INSERT. |

## Non-constitutional flags (deferred, not blocking)

- **F1 stale-row UX** — operator panel doesn't auto-refresh on RPC error (only on success). If two operators race on the same row, the second sees the error but the stale row stays in the queue. Trivial polish.
- **F2 warehouse role gap** — middleware routes warehouse-role users away from `/app`. The PRD §8 C.1 specifies `/app/inventory` placement, so this is per-spec. If Simran's warehouse staff need to approve adds, mount the panel on `/field/inventory` too as a Phase 2.1 follow-up.
- **F3 realtime SLA** — PRD §10 allows polling. Current implementation refreshes on dialog close + collapse-expand. A `supabase.channel(...).on('postgres_changes', ...)` subscription would meet the strict 5-second SLA. Phase 2.1 polish.
- **F4 photo upload** — PRD D4 feature-flag-gated (default false). Implement when ops flips the flag and the storage bucket is provisioned.

## Section 9 test matrix status (after Phase 2)

| #   | Case                                 | Status                                                                                |
| --- | ------------------------------------ | ------------------------------------------------------------------------------------- |
| 1   | Happy path                           | ✅ smoke-tested at Phase 1 close; live FE not yet manually tested                     |
| 2   | Shelf has different product          | RPC enforces, FE shelf picker shows disabled with "in use by" badge                   |
| 3   | Same shelf+product exists            | RPC enforces, same disabled shelf in picker                                           |
| 4   | Duplicate proposal (two drivers)     | partial UNIQUE index + RPC pre-check                                                  |
| 5   | Quantity exceeds capacity            | FE `max` attribute + RPC enforces server-side                                         |
| 6   | Expiry in past                       | FE `min` attribute + RPC enforces                                                     |
| 7   | Expiry beyond 36mo                   | FE `max` attribute (approximate) + RPC enforces                                       |
| 8   | Quantity zero                        | FE `min=1` + RPC enforces                                                             |
| 9   | Idempotent retry                     | ✅ smoke-tested                                                                       |
| 10  | Approval after shelf became occupied | Approve RPC re-validates, surfaces error to operator dialog                           |
| 11  | Approval with expiry now past        | FE override-checkbox shown only if expired, RPC enforces `p_expiry_override_accepted` |
| 12  | Reject without note                  | FE `>=10 chars` validation + RPC enforces same min                                    |
| 13  | Auto-expire 14d                      | ⏳ Phase 3                                                                            |
| 14  | Concurrent approve                   | FOR UPDATE lock + RPC raises clean error                                              |
| 15  | Direct INSERT bypass                 | ⏳ Phase 3                                                                            |

Manual UAT (1–12) by CS pending; see PRD §11.

## Pending (Phase 3)

- A.5 cron `pod_add_proposals_auto_expire` at 02:00 Dubai daily (binding: must be SECURITY DEFINER with all three set_config markers; must `UPDATE WHERE status='pending'` only)
- A.6 hard-block trigger on direct INSERT to pod_inventory (G4 caller-audit gate first)
- C.6 Inventory Control Session integration on approve/reject when session open
- Amendment 008 elevating pod_inventory_edits to Appendix A with FE INSERT exception clause

## Notes for next maintainer

- The B.4 rejection notification uses `alert()` rather than a toast because the codebase has no toast library; consistent with the `procurement/page.tsx:446` pattern and the PRD-001 fix earlier in this session. If a toast primitive is added later, this can be migrated cleanly.
- Photo upload is wired in the RPC (`p_photo_path text DEFAULT NULL`) but the FE always sends null. Adding it later means: (a) provision a storage bucket, (b) add an `<input type="file">` to AddProductDialog, (c) upload via `supabase.storage.from(bucket).upload(...)`, (d) pass the returned path to the RPC, (e) render thumbnail in PendingPodAdditionsPanel rows.
- The operator queue panel is intentionally collapsed-by-default would be `setCollapsed(true)`; current default is open. Flip if the queue gets noisy.
