# PRD-012: Driver Pod Add Workflow

**Owner:** CS
**Started:** 2026-05-25
**Status:** Draft, awaiting Dara + Cody review
**Supabase project:** eizcexopcuoycuosittm

## 1. The two outcomes

**A.** Driver in the field can add a new product to a machine pod through the existing field UI: picks a product from `boonz_products`, assigns the shelf, enters quantity and expiry date, submits. The submission becomes a pending proposal that warehouse manager reviews.

**B.** Warehouse manager sees pending additions in a queue, reviews per row (product, shelf, qty, expiry, driver, notes, optional photo), approves or rejects. On approve, the canonical RPC creates the `pod_inventory` row. On reject, the proposal is closed with a reason and the driver sees the rejection on their device.

## 2. Context

Today drivers can edit existing `pod_inventory` rows (quantity, expiry, location) through the field inventory page. They cannot add a NEW product to a machine; that path is warehouse-manager-only via the operator inventory page. In the field, drivers regularly discover that a planogram-intended product was missing or that operations decided to seed a new SKU at a machine and ask for manual addition. The current workaround is a phone call to the WH manager, who then opens the operator UI and adds the row. This is slow, error prone, and skips the audit trail.

The existing infrastructure already has the right primitives:

- `pod_inventory_edits` table with columns `edit_type`, `quantity_update`, `photo_path`, `notes`, `status` (pending/approved/rejected), `reviewed_by`, `reviewed_at`, plus `destination_machine_id` and `destination_shelf_id`.
- Approval review UI pattern from the warehouse side.

This PRD extends the existing edit proposal pattern with a new `edit_type = 'add_new_product'`, plus the columns needed to carry expiry and a writer RPC plus an approver RPC.

## 3. Goals (measurable)

**G1.** After deploy, any driver with `EDIT_ROLES` can open the field inventory page for a machine and submit a new product add. The proposal lands in `pod_inventory_edits` with `edit_type = 'add_new_product'` and `status = 'pending'`.

**G2.** Within 5 seconds of submit, the WH manager sees the new proposal in the pending review queue on the operator inventory page.

**G3.** On approve, a new `pod_inventory` row is created at the target machine and shelf, with the driver's quantity and expiry, via the canonical RPC. The original edit row links via `pod_inventory_id`.

**G4.** Audit trail end to end: every proposal, approval, rejection, and the resulting `pod_inventory` row is traceable through `pod_inventory_audit_log` and `pod_inventory_edits`.

**G5.** Zero ability to create a `pod_inventory` row outside the new approval path (the canonical writer rejects direct INSERT from the field role).

## 4. Non goals

- No change to how drivers edit existing rows. Quantity, expiry, and location edits remain on their current path.
- No change to the pod inventory swap / move flow (which uses `destination_machine_id` and `destination_shelf_id` for M2M).
- No new fields on `boonz_products`.
- No driver-side product creation. The driver always picks from existing `boonz_products` only.
- No bulk add. One product per submit.

## 5. Baked decisions

**D1. Existing table, not new.** Reuse `pod_inventory_edits` with `edit_type = 'add_new_product'`. Add one column: `requested_expiration_date date`. Add one column: `requested_quantity numeric` if `quantity_update` semantics conflict (Dara decides). No new table.

**D2. Shelf conflict policy.** If the target shelf has an Active `pod_inventory` row for ANY product, the proposal is refused at submit time with a clear error: "Shelf X currently has Product Y. Use the swap flow instead." Driver does not see this as an approval-pending state; the proposal never lands.

**D3. Expiry validation.** Submit rejects expiry dates in the past or more than 36 months out. WH manager can override at approval time only with an explicit "expiry override accepted" note.

**D4. Photo required only when WH manager configures it.** Add a feature flag `field_inventory.require_photo_for_add` (default false for v1). Photo can be uploaded optionally even when not required.

**D5. Idempotency.** Submit includes a client-generated `correlation_id`. Server-side, one pending proposal allowed per (machine_id, shelf_id, boonz_product_id, status=pending). Duplicates within 60 seconds are deduped by `correlation_id`.

**D6. Auto-expire pending proposals after 14 days.** A cron sets `status = 'expired'` on pending rows older than 14 days. Driver notified via the field inventory page.

## 6. Workstream A: Backend (schema, RPCs, canonical writer)

**Owner:** Dara (schema), Cody (constitutional review), assistant (apply migrations).

### A.1 Schema extension

Migration adds to `pod_inventory_edits`:

- `requested_expiration_date date null` (only required when `edit_type = 'add_new_product'`)
- `requested_shelf_id uuid null` (replaces overloaded `destination_shelf_id` for add flow if Dara prefers; if not, reuse `destination_shelf_id`)
- `correlation_id uuid not null default gen_random_uuid()` for idempotency
- `expired_at timestamptz null` for D6 auto-expire bookkeeping

Constraint: when `edit_type = 'add_new_product'`, `pod_inventory_id IS NULL` (the row does not exist yet) and the new fields are NOT NULL.

### A.2 New RPC `propose_pod_inventory_add`

Signature: `(p_machine_id uuid, p_shelf_id uuid, p_boonz_product_id uuid, p_quantity numeric, p_expiration_date date, p_notes text default null, p_photo_path text default null, p_correlation_id uuid default null, p_proposed_by uuid default null)`.

Behavior:

1. Validate inputs (quantity > 0, expiry not in past, expiry not > 36 months).
2. Refuse if shelf has any Active `pod_inventory` row (D2).
3. Refuse if there is already a pending proposal for the same (machine, shelf, product).
4. Dedupe by `correlation_id` within 60 seconds.
5. INSERT into `pod_inventory_edits` with `edit_type = 'add_new_product'`, `status = 'pending'`.
6. Return `edit_id` and structured response.

RLS: callable by `EDIT_ROLES` (driver, warehouse, operator_admin, superadmin, manager).

### A.3 New RPC `approve_pod_inventory_add`

Signature: `(p_edit_id uuid, p_approver_id uuid default null, p_decision_note text default null, p_expiry_override_accepted boolean default false)`.

Behavior:

1. Fetch the edit row, lock it. Refuse if `status != 'pending'` or `edit_type != 'add_new_product'`.
2. Re-validate the shelf conflict (in case state changed since submit). Refuse with clear error if shelf is no longer free.
3. Re-validate expiry. If now in the past, refuse unless `p_expiry_override_accepted = true`.
4. Set `app.via_rpc = true`, `app.rpc_name = 'approve_pod_inventory_add'`, `app.mutation_reason = format('pod_add_approval edit_id=%s by %s', p_edit_id, p_approver_id)`.
5. INSERT into `pod_inventory` with the requested quantity, expiry, machine, shelf, product. Status = `Active`. `batch_id = format('POD_ADD-%s', p_edit_id)`.
6. UPDATE the edit row: `status = 'approved'`, `reviewed_by = p_approver_id`, `reviewed_at = now()`, `pod_inventory_id = <new row id>`, append decision_note.
7. Return structured response with both ids.

RLS: callable by warehouse, operator_admin, superadmin, manager.

### A.4 New RPC `reject_pod_inventory_add`

Signature: `(p_edit_id uuid, p_approver_id uuid default null, p_decision_note text)`.

Behavior:

1. Fetch and lock the edit row. Refuse if `status != 'pending'`.
2. UPDATE `status = 'rejected'`, `reviewed_by`, `reviewed_at`, decision_note (required, non-empty).
3. Return structured response.

### A.5 Cron: auto-expire pending after 14 days

New pg_cron job `pod_add_proposals_auto_expire` at 02:00 Dubai daily. Function `auto_expire_pod_add_proposals()` UPDATEs `status = 'expired'`, `expired_at = now()` for rows where `edit_type = 'add_new_product'`, `status = 'pending'`, `created_at < now() - interval '14 days'`.

### A.6 Block direct INSERT outside the canonical path

Existing trigger or new check ensures `pod_inventory` INSERTs always carry `app.via_rpc = 'true'`. Field role attempting a direct INSERT gets blocked. Same guard family as `trg_detect_silent_warehouse_write` but for pod_inventory.

## 7. Workstream B: Driver UI (field add flow)

**Owner:** Stax (implementation).

### B.1 "Add Product" button on `/field/inventory/[machine_id]/page.tsx`

Visible to all `EDIT_ROLES`. Disabled while page is loading or in read-only state (no open inventory session if soft lock is on).

### B.2 Add Product dialog

- **Product search**: typeahead bound to `boonz_products` (filtered to active products only, excluding ones already on the machine if Dara confirms there is a clean way; otherwise allow all).
- **Shelf picker**: dropdown of all shelves on this machine. Shelves with an existing Active `pod_inventory` row are shown but disabled with badge "in use by [Product Name]" (D2).
- **Quantity input**: numeric, must be > 0 and <= shelf max_capacity (read from `shelf_configurations`).
- **Expiry date picker**: must be >= tomorrow, <= today + 36 months.
- **Notes**: optional free text.
- **Photo**: optional upload (mandatory when feature flag enabled).
- **Submit button**: calls `propose_pod_inventory_add` with a client-generated `correlation_id`.

### B.3 Pending state on the driver page

Submitted proposals appear in a "Pending review" section at the bottom of the field inventory page, showing: product, shelf, qty, expiry, submitted time, status badge. Refreshes when status changes.

### B.4 Rejection toast

If the proposal is rejected, the driver gets a toast on next page load with the rejection reason.

## 8. Workstream C: WH manager review UI

**Owner:** Stax (implementation).

### C.1 "Pending pod additions" section on operator inventory page

Top of `/app/inventory/page.tsx` shows count badge of pending pod additions. Click expands a list.

### C.2 Per-row actions

Each pending row shows: machine name, shelf code, product, quantity, expiry, submitted by, submitted time, notes, photo thumbnail (if any). Two action buttons: Approve | Reject.

### C.3 Approve dialog

- Optional decision note input.
- Expiry validation banner if expiry is now in the past (forces "I accept the override" checkbox).
- Click confirm calls `approve_pod_inventory_add`. Optimistic UI off. Spinner while RPC in flight. On success, row moves to "Approved today" section. On error, banner with error message.

### C.4 Reject dialog

- Mandatory decision note input (must be >= 10 chars).
- Click confirm calls `reject_pod_inventory_add`. Same UX rules.

### C.5 Filters and search

Filter pending list by: machine, product, driver, age. Default sort: oldest first.

### C.6 Inventory control session integration

If Phase G Inventory Control Mode session is active, the approve and reject actions are attributed to the session (writes a corresponding `inventory_control_attempt` row).

## 9. Edge case test matrix

| #   | Case                                     | Setup                                                                                                                     | Expected                                                                       |
| --- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| 1   | Happy path                               | Empty shelf, valid product, qty 5, expiry 2027-01-01, driver submits                                                      | Proposal lands in pending. WH approves. pod_inventory row created with stock 5 |
| 2   | Shelf already has different product      | Shelf has Active row for Product Y, driver tries to add Product Z                                                         | Submit refused with error "Shelf X currently has Product Y. Use swap flow."    |
| 3   | Same shelf, same product, already exists | Shelf already has Active row for Product Z, driver tries to add Product Z                                                 | Submit refused with "Product already on this shelf. Use the edit flow."        |
| 4   | Duplicate proposal                       | Driver A submits add for shelf X. Driver B submits same combination                                                       | Second submit refused; first proposal remains pending                          |
| 5   | Quantity exceeds capacity                | Shelf max_capacity = 6, driver enters qty = 10                                                                            | Submit refused with "Quantity exceeds shelf capacity 6"                        |
| 6   | Expiry in past                           | Driver enters expiry = 2024-01-01                                                                                         | Submit refused with "Expiry must be in the future"                             |
| 7   | Expiry beyond 36 months                  | Driver enters expiry = 2030-01-01                                                                                         | Submit refused (or warning, per Dara)                                          |
| 8   | Quantity zero                            | Driver enters qty = 0                                                                                                     | Submit refused                                                                 |
| 9   | Idempotent retry                         | Submit times out client-side. Driver retries with same correlation_id within 60s                                          | Server returns existing edit_id, no duplicate row created                      |
| 10  | Approval after shelf became occupied     | Driver submits. WH manager opens approval 30 min later. Another driver added a different product to same shelf in between | Approval refused with "Shelf now in use by [Product]. Reject or escalate."     |
| 11  | Approval with expiry now past            | Driver submits with expiry 1 day out. WH manager opens approval next day                                                  | Approval requires explicit "expiry override accepted" checkbox                 |
| 12  | Reject without note                      | WH manager clicks reject with empty note                                                                                  | Refused, note required                                                         |
| 13  | Auto-expire                              | Pending proposal older than 14 days                                                                                       | Cron sets status to expired, driver sees expired badge                         |
| 14  | Concurrent approve                       | Two managers click approve on same proposal                                                                               | Second click gets "already approved" error                                     |
| 15  | Direct INSERT bypass                     | Field role tries to INSERT into pod_inventory directly                                                                    | Trigger refuses with "use canonical RPC"                                       |

## 10. Success criteria

| Outcome | Criterion                                                             | Measurement                                                                                 |
| ------- | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| A       | Drivers can submit a new product add from field UI                    | UAT pass on cases 1, 2, 3, 6                                                                |
| A       | Submit lands in pending within 1 second                               | Client telemetry on time-to-success-response                                                |
| B       | WH manager review queue surfaces new proposals within 5 seconds       | Supabase realtime subscription or 5-second polling                                          |
| B       | Approval creates pod_inventory row via canonical RPC                  | `SELECT COUNT(*) FROM pod_inventory WHERE batch_id LIKE 'POD_ADD-%'` matches approved count |
| Audit   | Every state transition logged                                         | `pod_inventory_audit_log` and `pod_inventory_edits` rows match                              |
| Safety  | Zero pod_inventory rows created outside the new RPC path after deploy | Query: any row where `app.via_rpc != true` in audit log post deploy                         |

## 11. Sequencing

**Phase 1 (this week):**

- A.1 schema migration (Dara designs, Cody reviews, apply).
- A.2 propose RPC.
- A.3 approve RPC.
- A.4 reject RPC.

**Phase 2:**

- B.1 to B.4 driver UI.
- C.1 to C.5 WH manager UI.
- Test matrix cases 1 to 12.

**Phase 3:**

- A.5 auto-expire cron.
- A.6 hard block on direct INSERT.
- C.6 inventory control session integration.
- Test matrix cases 13 to 15.

## 12. Safety constitution

- All `pod_inventory` writes via canonical RPC only. No direct INSERT or UPDATE.
- No DELETE on `pod_inventory` or `pod_inventory_edits` without per-row CS approval.
- Plan Write Protocol for all canonical writers: pre-flight validation, write via RPC, verify by reading back, return structured response.
- No em dashes anywhere.
- Every migration reviewed by Cody before apply (CONSTITUTIONAL verdict required).
- Skill boonz-master-3 loaded before any operational test.

## 13. Open questions for CS

None. All decisions baked in Section 5. CS can amend D1 through D6 before /goal fires if needed.

## 14. Out of scope

- Driver-side product creation (drivers always pick from existing `boonz_products`).
- M2M transfer flow (separate workstream).
- Auto-routing to a specific warehouse manager.
- SMS / push notification to the manager on new proposal (could be Phase 4).
- Photo OCR or barcode scanning (separate workstream).
