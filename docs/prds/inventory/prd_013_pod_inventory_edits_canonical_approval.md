# PRD-013: Pod Inventory Edits Canonical Approval Surface

**Owner:** CS
**Started:** 2026-05-25
**Status:** Draft, awaiting Dara plus Cody review
**Supabase project:** eizcexopcuoycuosittm
**Relationship to other PRDs:** Supersedes the approval RPC scope of PRD-012 (Driver Pod Add Workflow). PRD-012's `propose_pod_inventory_add` stays. PRD-012's `approve_pod_inventory_add` and `reject_pod_inventory_add` are absorbed into the unified RPCs defined here.

## 1. The two outcomes

**A.** Every approval and rejection action on any `pod_inventory_edits` row goes through ONE canonical RPC that atomically flips both the edit row AND the underlying `pod_inventory` state in the same transaction. Zero partial states. Zero rows stuck in "approved but pod row still Active."

**B.** Direct UPDATE on `pod_inventory` outside the canonical RPC path is refused at the database level. No future FE regression can introduce the same leak again.

## 2. Context

Diagnostic 2026-05-25 found that the `pod_inventory_edits` approval flow has no canonical RPC. The FE writes directly to the table. As a result, 23 of 88 historical approved `expired` edits left the underlying `pod_inventory` row `status = 'Active'` with positive `current_stock` or `estimated_remaining`. The view `v_pod_inventory_expiry_status` keeps surfacing those rows, and the field UI at `/field/pod-inventory?filter=to_validate` keeps showing them. Driver tries to remove. WH approves. Nothing changes. Loop.

This is the third instance of the same anti-pattern in 14 days. The structural fix is to centralise state-machine transitions in canonical RPCs and block direct writes at the trigger layer. Same playbook as Phase G workstream A.7.

## 3. Goals (measurable)

**G1.** After Phase 1 deploy, every approval action on `pod_inventory_edits` goes through `approve_pod_inventory_edit`. Zero direct UPDATEs to `pod_inventory_edits.status` from any client. Measured: `SELECT COUNT(*) FROM write_audit_log WHERE table_name = 'pod_inventory_edits' AND via_rpc = false AND occurred_at > deploy_date` should be zero.

**G2.** After Phase 2 deploy, all 23 backlog rows are archived. Measured: zero rows in `v_pod_inventory_expiry_status` that have a linked `pod_inventory_edits` row with `status = 'approved'` and `edit_type IN ('expired','return_to_warehouse')`.

**G3.** After Phase 3 deploy, the hard-block trigger on `pod_inventory` is live. Measured: `SELECT COUNT(*) FROM monitoring_alerts WHERE source = 'pod_inventory_direct_write_blocked' AND created_at > deploy_date` shows blocked-write attempts; zero leaked rows.

**G4.** After full deploy, the `to_validate` filter shows only genuinely pending rows (driver has not yet flagged, OR WH has not yet approved). No stuck post-approval rows.

## 4. Non goals

- No change to the FE filter UX itself. The bug is upstream of the filter.
- No change to `edit_type` semantics. The four existing values plus the new one from PRD-012 stay.
- No change to `boonz_products`, `planogram`, or `shelf_configurations`.
- No change to refill engine logic.

## 5. Baked decisions

**D1. One unified RPC handles all five `edit_type` values.** `approve_pod_inventory_edit(p_edit_id, p_approver_id, p_decision_note)` dispatches internally by `edit_type`. Same for `reject_pod_inventory_edit`. PRD-012's separate add-flow approve and reject RPCs are absorbed here.

**D2. Dispatch table by `edit_type` (the contract).**

| `edit_type`                      | What approve does to `pod_inventory`                                                                                                                                                                                                             | What approve does to `warehouse_inventory`                                                                                                                                                                                   |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `expired`                        | Archive row: `current_stock = 0`, `estimated_remaining = 0`, `status = 'Inactive'`, `removal_reason = format('expired_validated_via_edit_%s', edit_id)`                                                                                          | No change                                                                                                                                                                                                                    |
| `sold`                           | Decrement `current_stock` and `estimated_remaining` by `quantity_update`. If both hit zero, set `status = 'Inactive'` with `removal_reason = format('sold_drained_via_edit_%s', edit_id)`                                                        | No change                                                                                                                                                                                                                    |
| `partial_sold`                   | Decrement `current_stock` and `estimated_remaining` by `quantity_update`. Stay `Active`                                                                                                                                                          | No change                                                                                                                                                                                                                    |
| `return_to_warehouse`            | Archive row (same as `expired`).                                                                                                                                                                                                                 | Credit `warehouse_inventory` row matching (`boonz_product_id`, `expiration_date`) at the destination warehouse by `quantity_update`. If no matching row, INSERT a new one with `batch_id = format('POD_RETURN-%s', edit_id)` |
| `add_new_product` (from PRD-012) | INSERT new `pod_inventory` row at the target shelf with `current_stock = requested_quantity`, `expiration_date = requested_expiration_date`, `batch_id = format('POD_ADD-%s', edit_id)`, `status = 'Active'`. Refuse if shelf has any Active row | No change                                                                                                                                                                                                                    |

**D3. Audit-first for hard-block trigger** (mirrors Phase G D2). Step 1 list every direct caller of `pod_inventory` UPDATE. Step 2 migrate each to canonical RPC. Step 3 flip `BEFORE UPDATE` trigger to raise exception when `app.via_rpc != 'true'`. No flip until 7 days of zero direct callers.

**D4. Backlog cleanup is per-row CS sign-off.** I will pre-build the 23-row diff CSV. Each row needs an explicit "OK to archive" from CS before the cleanup DO block runs. Same protocol as Phase G Gate 3.

**D5. PRD-012 layering.** `propose_pod_inventory_add` from PRD-012 still ships. It writes a new `pod_inventory_edits` row with `edit_type = 'add_new_product'`, `status = 'pending'`. WH manager then approves through THIS PRD's unified `approve_pod_inventory_edit`. One approval surface for all edit types.

**D6. Concurrency model.** `approve_pod_inventory_edit` takes `SELECT ... FOR UPDATE` on the edit row. Second approver gets a clear "already approved" error. No partial double-approval state possible.

## 6. Workstream A: Backend (canonical RPCs and hard block)

**Owner:** Dara (any schema), Cody (constitutional review), assistant (apply).

### A.1 `approve_pod_inventory_edit` RPC

Signature: `(p_edit_id uuid, p_approver_id uuid default null, p_decision_note text default null, p_expiry_override_accepted boolean default false)`.

Behavior:

1. `SELECT * INTO v_edit FROM pod_inventory_edits WHERE edit_id = p_edit_id FOR UPDATE`. Refuse if `status != 'pending'`.
2. Set session config: `app.via_rpc = 'true'`, `app.rpc_name = 'approve_pod_inventory_edit'`, `app.mutation_reason = format('pod_edit_approval edit_id=%s type=%s by %s', p_edit_id, v_edit.edit_type, p_approver_id)`.
3. Dispatch by `edit_type` per D2 table.
4. UPDATE `pod_inventory_edits`: `status = 'approved'`, `reviewed_by = p_approver_id`, `reviewed_at = now()`, append decision_note if provided.
5. Return structured JSONB: `{edit_id, edit_type, pod_inventory_id, pod_status_after, wh_inventory_id_credited (if applicable), audit_log_entry_id}`.

Errors raised on:

- Edit not in `pending` state.
- Edit references a `pod_inventory_id` that does not exist (for non-add types).
- Add type targets a shelf now occupied by another product.
- `return_to_warehouse` with no matching WH row and no default warehouse configured.

### A.2 `reject_pod_inventory_edit` RPC

Signature: `(p_edit_id uuid, p_approver_id uuid default null, p_decision_note text)`.

Behavior:

1. Lock edit row. Refuse if `status != 'pending'`.
2. Refuse if `p_decision_note` is null or fewer than 10 characters.
3. UPDATE `pod_inventory_edits`: `status = 'rejected'`, `reviewed_by`, `reviewed_at`, decision_note.
4. No change to `pod_inventory` or `warehouse_inventory`.
5. Return structured response.

### A.3 `expire_pod_inventory_edits` cron (auto-expire pending after 14 days)

Function `auto_expire_pod_inventory_edits()`. New pg_cron job at 02:30 Dubai daily. Sets `status = 'expired'` on rows where `status = 'pending'` and `created_at < now() - interval '14 days'`. Notifies via the field inventory page banner.

### A.4 Hard-block trigger on `pod_inventory`

New trigger `trg_block_direct_pod_inventory_write` (BEFORE UPDATE on `pod_inventory`). Raises exception when:

- `app.via_rpc != 'true'`, AND
- The change touches `current_stock`, `estimated_remaining`, `status`, or `removal_reason`.

INSERTs remain allowed (snapshot ingestion, PO receipt). DELETEs remain forbidden by the existing no-delete rule.

Audit-first deploy per D3.

### A.5 Caller migration audit

Run `SELECT ... FROM write_audit_log WHERE table_name IN ('pod_inventory', 'pod_inventory_edits') AND via_rpc = false GROUP BY actor_role, rpc_name`. Surface every non-RPC caller. Migrate each to canonical RPC. Confirm 7 days clean before flipping A.4.

## 7. Workstream B: FE (rewire to canonical RPCs)

**Owner:** Stax.

### B.1 Field approval handler at `/field/pod-inventory`

Where the "approve" button currently lives, replace direct UPDATE with a call to `approve_pod_inventory_edit(edit_id, auth.uid(), reason)`. Same UX rules as Phase G:

- No optimistic update. Spinner while RPC in flight.
- On `result = 'success'`: row removed from the to_validate list, green toast.
- On any failure: row stays, red banner with the actual error message.

### B.2 Operator review UI

Where the WH-side approve and reject lives, do the same rewire. The reject path requires a non-empty decision note input (>= 10 chars) per A.2 validation.

### B.3 Pending state visual treatment

After approve, the row leaves the to_validate list within 1 second. No manual refresh needed. After reject, the row also leaves (or moves to a "rejected" section if you want a 7-day visible history).

### B.4 Optional: per-row movement trail drawer (Phase G alignment)

If Phase G B.4 ships first, reuse the per-row trail drawer here. Click any pod_inventory row to see its lifecycle including the `pod_inventory_edits` history.

## 8. Workstream C: Backlog cleanup (23 stuck rows)

**Owner:** Assistant, with CS per-row sign-off.

### C.1 Pre-build the diff CSV

`pod_edits_cleanup_2026-05-25.csv` lists every row where:

- A `pod_inventory_edits` row exists with `status = 'approved'`, `edit_type IN ('expired', 'return_to_warehouse')`,
- AND the corresponding `pod_inventory.status = 'Active'` AND (`current_stock > 0` OR `estimated_remaining > 0`).

Columns: `edit_id`, `pod_inventory_id`, `machine`, `product`, `shelf`, `current_stock`, `estimated_remaining`, `expiration_date`, `proposed_target_stock = 0`, `proposed_target_status = 'Inactive'`, `requires_signoff = true`, `notes`.

### C.2 CS reviews CSV

Same protocol as Phase G Gate 3. CS marks each row OK or amend.

### C.3 Apply cleanup via canonical path

For each CS-approved row, call a new helper RPC `backfill_archive_pod_inventory_row(p_pod_inventory_id, p_reason, p_edit_id_link)` that sets the row to `current_stock = 0, estimated_remaining = 0, status = 'Inactive', removal_reason = format('backlog_cleanup_2026-05-25_via_edit_%s', p_edit_id_link)`. Logs to `pod_inventory_audit_log`.

This helper RPC stays available for future ad-hoc backfills but is gated to `superadmin` and `operator_admin` only.

## 9. Edge case test matrix

| #   | Case                                            | Setup                                                                                    | Expected                                                                                                             |
| --- | ----------------------------------------------- | ---------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| 1   | Approve expired happy path                      | Edit pending, pod row Active with stock 1, expired                                       | After approve: edit status=approved, pod status=Inactive, current_stock=0, estimated_remaining=0, removal_reason set |
| 2   | Approve sold happy path                         | Edit pending, pod row stock 5, edit qty 2                                                | After approve: pod row stock 3 (5-2), status still Active                                                            |
| 3   | Approve sold drains to zero                     | Pod row stock 2, edit qty 2                                                              | Pod row stock 0, status Inactive                                                                                     |
| 4   | Approve partial_sold                            | Pod row stock 5, edit qty 2                                                              | Pod row stock 3, status stays Active (never auto-archives)                                                           |
| 5   | Approve return_to_warehouse                     | Edit pending, pod row stock 3, default WH set                                            | Pod row archived. WH row credited by 3 units at matching expiry                                                      |
| 6   | Approve return_to_warehouse, no matching WH row | Same as 5 but WH has no matching (product, expiry) row                                   | New WH row inserted with batch_id POD_RETURN-{edit_id}, 3 units, Active                                              |
| 7   | Approve add_new_product                         | Edit pending (from PRD-012), target shelf empty                                          | New pod_inventory row inserted with requested qty and expiry                                                         |
| 8   | Approve add_new_product, shelf now occupied     | Same as 7 but shelf has Active row at approval time                                      | Refused with clear error, edit stays pending                                                                         |
| 9   | Reject without note                             | Approver clicks reject, no note                                                          | Refused                                                                                                              |
| 10  | Reject with short note                          | Note is 5 chars                                                                          | Refused with "decision note must be >= 10 chars"                                                                     |
| 11  | Concurrent approve                              | Two approvers click approve simultaneously                                               | First wins, second gets "already approved" error                                                                     |
| 12  | Approve already-approved                        | Edit status=approved, approver clicks again                                              | Refused with "edit not in pending state"                                                                             |
| 13  | Direct UPDATE to pod_inventory.status           | Any client tries `UPDATE pod_inventory SET status = 'Inactive' WHERE ...` outside an RPC | After A.4 flip: refused with "use canonical RPC"                                                                     |
| 14  | Direct UPDATE to pod_inventory.current_stock    | Same                                                                                     | Refused                                                                                                              |
| 15  | INSERT to pod_inventory still works             | Snapshot ingestion or PO receipt INSERTs                                                 | Allowed                                                                                                              |
| 16  | Auto-expire                                     | Edit pending for 15 days                                                                 | Cron sets status='expired'. Driver sees expired badge                                                                |
| 17  | Backlog cleanup, signed off                     | CSV row approved by CS                                                                   | `backfill_archive_pod_inventory_row` archives the pod row. Audit log entry created                                   |
| 18  | Backlog cleanup, not signed off                 | CS leaves row blank in CSV                                                               | Skipped. No write                                                                                                    |

## 10. Success criteria

| Outcome   | Criterion                                           | Measurement                                                                                                               |
| --------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| A         | Every approve and reject goes through canonical RPC | Zero non-RPC writes to `pod_inventory_edits` after Phase 1 deploy                                                         |
| A         | `pod_inventory` stays consistent with edit state    | Zero rows where `status = 'Active'` AND linked edit `status = 'approved'` AND edit_type in (expired, return_to_warehouse) |
| A         | `to_validate` filter only shows truly pending rows  | Manual UAT pass on a 7-day window after deploy                                                                            |
| B         | FE call sites migrated and clean build              | tsc plus build plus lint pass; Cody Article 3 review pass                                                                 |
| C         | All 23 backlog rows archived                        | `pod_edits_cleanup_2026-05-25.csv` zero pending rows                                                                      |
| Hardening | Hard block trigger live, zero leaks                 | `monitoring_alerts` shows blocked attempts not actual writes                                                              |

## 11. Sequencing

**Phase 1 (this week, 2026-05-26 to 2026-06-01):**

- A.1 + A.2 (the two RPCs). Dara designs, Cody reviews, apply.
- A.5 caller audit (read-only baseline).
- B.1 + B.2 (FE rewire). Stax implements.
- Section 9 tests 1 through 12.

**Phase 2 (week of 2026-06-02):**

- C.1 + C.2 + C.3 (backlog cleanup with CS per-row sign-off).
- Section 9 tests 17 and 18.

**Phase 3 (week of 2026-06-09):**

- A.3 auto-expire cron.
- A.4 hard-block trigger (after 7 days clean caller audit per D3).
- Section 9 tests 13 through 16.

## 12. Safety constitution

- All `pod_inventory` and `pod_inventory_edits` writes via canonical RPC only.
- No DELETE on any table without per-row CS approval.
- No silent stock reductions. Show row diff before commit.
- Plan Write Protocol every write.
- No em dashes anywhere.
- Every migration reviewed by Cody before apply.
- Skill boonz-master-3 loaded before any operational test.

## 13. Out of scope

- The FE filter UX or component itself.
- Refill engine logic.
- Sales ingestion (WEIMI).
- Driver app payload format unrelated to approval flow.
- VOX or partner sourcing logic.
- Any change to `sales_lines` or Adyen reconciliation.
