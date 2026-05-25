# PRD-013 Phase 2 Summary — Backlog cleanup of 9 stuck pod_inventory rows

**Phase:** 2 (backlog cleanup)
**Status:** Shipped 2026-05-25
**Source PRD:** [`docs/prds/inventory/prd_013_pod_inventory_edits_canonical_approval.md`](../inventory/prd_013_pod_inventory_edits_canonical_approval.md)

## Shipped

| #    | Deliverable                              | File                                                 | Notes                                                                                                                                                                                                                                                                                 |
| ---- | ---------------------------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P2.A | Cleanup CSV                              | `docs/prds/prd-013/pod_edits_cleanup_2026-05-25.csv` | 9 unique pod_inventory rows (27 linked approved edit rows total). All past-expiry, operator-approved 'expired'.                                                                                                                                                                       |
| P2.B | CS sign-off at G3                        | (chat record)                                        | CS approved all 9 rows in one batch.                                                                                                                                                                                                                                                  |
| P2.C | `backfill_archive_pod_inventory_row` RPC | `supabase/migrations/20260525220000_*.sql`           | SECURITY DEFINER. Gated to superadmin + operator_admin. Min 10-char `p_reason`. FOR UPDATE lock. RAISE NOTICE on already-Inactive idempotent re-call. Sets all three set_config markers including a structured `mutation_reason` carrying pod_id + edit_link + reason. Cody approved. |
| P2.D | Loop of 9 archives                       | (one-shot SQL)                                       | All 9 rows archived. `previous_status='Active'` → `new_status='Inactive'`. Total stock zeroed: 1+1+1+2+7+1+1+1+0 = 15 units; total estimated_remaining zeroed: 1+1+1+2+7+1+1+1+1 = 16 units. Audit trail captured via tg_audit_pod_inventory.                                         |

## Reconciliation: PRD baseline (23) vs actual (27 → 9)

The diagnostic dated 2026-05-25 reported "23 stuck rows." Re-query at execution time found **27 linked approved 'expired' edit rows pointing at 9 unique pod_inventory rows**. The 23 → 27 delta is 4 additional approved edits piled up between the diagnostic and execution (operators kept clicking approve, the rows kept not flipping — the bug was actively reproducing). The cleanup target is the 9 pod rows, not the 27 edit rows.

## Verification (PRD §G2)

```sql
-- Before P2.D
SELECT count(*) FROM pod_inventory_edits e
JOIN pod_inventory pi ON pi.pod_inventory_id = e.pod_inventory_id
WHERE e.status='approved' AND e.edit_type IN ('expired','return_to_warehouse')
  AND pi.status='Active' AND (current_stock > 0 OR estimated_remaining > 0);
-- → 23 (per Phase 1 baseline) / 27 (at P2.A execution time)

-- After P2.D
-- → 0 ✅
```

`v_pod_inventory_expiry_status` no longer surfaces these 9 pod rows in the `to_validate` filter (the view's `WHERE` clause excludes Inactive rows; once the pod rows flipped, they fell out of the view's result set).

## Section 9 test matrix updates

| #   | Case                            | Status                                                                                                                                                                                                   |
| --- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 17  | Backlog cleanup, signed off     | ✅ PASS — 9/9 rows archived via `backfill_archive_pod_inventory_row`; each RPC call returned `{result:'success', new_status:'Inactive'}` with previous state captured for audit traceability.            |
| 18  | Backlog cleanup, not signed off | ✅ COVERED structurally — the helper RPC requires explicit invocation with caller identity and reason; without a CS-signed-off row in the CSV, no write happens. Zero un-signed-off rows were processed. |

## Audit trail captured

Each of the 9 archives wrote one row to `write_audit_log` (via `tg_audit_pod_inventory`) with:

- `rpc_name = 'backfill_archive_pod_inventory_row'`
- `mutation_reason = 'backfill_archive pod=<uuid> edit_link=<uuid> by=82bba4ee... reason=backlog_cleanup_2026-05-25 via PRD-013 G3 sign-off'`
- `actor = 82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d` (operator_admin)
- Pre-image: `{status:'Active', current_stock:N, estimated_remaining:M}`
- Post-image: `{status:'Inactive', current_stock:0, estimated_remaining:0, removal_reason:'backlog_cleanup_2026-05-25 ...'}`

## Pending follow-ups (Phase 3)

- A.5 caller audit: list every direct UPDATE to pod_inventory in last 30 days. Surface to CS. Migrate any non-RPC callers found.
- A.3 cron: `auto_expire_pod_inventory_edits` at 02:30 Dubai daily; flips pending → expired after 14 days.
- A.4 hard-block trigger: BEFORE UPDATE on pod_inventory raises when `app.via_rpc != 'true'` AND the change touches `current_stock`, `estimated_remaining`, `status`, or `removal_reason`. G4 caller-audit gate required (7-day clean record).
- Section 9 cases 13, 14, 16 covered after Phase 3.

## Notes for next maintainer

- The 9 archived rows are permanent state changes (not reversible without per-row sign-off + another canonical RPC call).
- The `backfill_archive_pod_inventory_row` helper stays available indefinitely for future ad-hoc backfills, gated to superadmin + operator_admin.
- If new stuck rows appear in `v_pod_inventory_expiry_status` after this cleanup, they should NOT need this helper — the new canonical `approve_pod_inventory_edit` RPC archives correctly on approve. Investigate any new stuck rows as a regression.
