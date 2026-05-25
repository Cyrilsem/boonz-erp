# PRD-012 Phase 1 Summary — Backend Substrate + RPCs

**Phase:** 1 (Backend: schema + canonical writers)
**Status:** Shipped 2026-05-25
**Source PRD:** [`docs/prds/inventory/prd_012_driver_pod_add_workflow.md`](../inventory/prd_012_driver_pod_add_workflow.md)

## Shipped

Five migrations, all applied to prod (Supabase project `eizcexopcuoycuosittm`), all Cody-reviewed.

| #   | Migration                                             | SQL file                                   | Articles        | Notes                                                                                                                        |
| --- | ----------------------------------------------------- | ------------------------------------------ | --------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| 1   | `prd_012_pod_inventory_edits_add_flow`                | `supabase/migrations/20260525140000_*.sql` | 2, 5, 7, 12, 14 | A.1 schema substrate: 3 new columns + CHECK constraint + 3 indexes.                                                          |
| 2   | `prd_012_extend_pod_inventory_edits_check_whitelists` | `supabase/migrations/20260525150300_*.sql` | 5, 12           | Hotfix #1: extends pre-existing edit_type whitelist with `add_new_product` and status whitelist with `expired`.              |
| 3   | `prd_012_relax_add_flow_check`                        | `supabase/migrations/20260525150400_*.sql` | 12, 14          | Hotfix #2: drops the `pod_inventory_id IS NULL` clause from the add-flow CHECK so the approve RPC can link the pod row back. |
| 4   | `prd_012_propose_pod_inventory_add`                   | `supabase/migrations/20260525150000_*.sql` | 1, 3, 4, 5, 8   | A.2: driver-callable propose RPC. Validates D2/D3/D5.                                                                        |
| 5   | `prd_012_approve_pod_inventory_add`                   | `supabase/migrations/20260525150100_*.sql` | 1, 4, 5, 8, 12  | A.3: manager-only approve RPC. Re-validates, INSERTs pod_inventory row with `batch_id POD_ADD-(edit_id)`.                    |
| 6   | `prd_012_reject_pod_inventory_add`                    | `supabase/migrations/20260525150200_*.sql` | 1, 4, 5, 8      | A.4: manager-only reject RPC. Requires decision_note >= 10 chars.                                                            |

(Numbered 1-6 above for narrative; only items 1, 2, 3, 4, 5, 6 are distinct migrations; the hotfixes 2 and 3 were applied in sequence after smoke test caught their omissions.)

## What works end to end

Smoke test passed in a transaction-rolled-back DO block on prod. Sequence verified:

1. Driver (field_staff) calls `propose_pod_inventory_add(machine, shelf, product, qty=5, expiry=+90d, correlation_id=X)` → returns `result='success', edit_id=Y`.
2. Driver re-calls with same correlation_id → returns `result='idempotent_replay', edit_id=Y` (no duplicate row).
3. Manager (operator_admin) calls `approve_pod_inventory_add(edit_id=Y, decision_note='smoke test approval')` → INSERTs `pod_inventory` row with `status='Active'`, `batch_id='POD_ADD-Y'`, returns `pod_inventory_id=Z`.
4. Verify pod_inventory row Z exists with status=Active. ✅
5. Verify edit row Y has status='approved' and pod_inventory_id=Z. ✅
6. Transaction rolled back. Confirmed zero leaked rows.

## Section 9 test matrix status

| #   | Case                                 | Status                                                                        |
| --- | ------------------------------------ | ----------------------------------------------------------------------------- |
| 1   | Happy path                           | ✅ smoke-tested                                                               |
| 2   | Shelf has different product          | covered by D2 RPC validation (live), needs FE UAT                             |
| 3   | Same shelf+product exists            | covered by D2 RPC validation (live), needs FE UAT                             |
| 4   | Duplicate proposal (two drivers)     | covered by `idx_pie_one_pending_add_per_target` + RPC pre-check, needs FE UAT |
| 5   | Quantity exceeds capacity            | covered by max_capacity check, needs FE UAT                                   |
| 6   | Expiry in past                       | covered by D3 check                                                           |
| 7   | Expiry beyond 36 months              | covered by D3 check                                                           |
| 8   | Quantity zero                        | covered by validation                                                         |
| 9   | Idempotent retry                     | ✅ smoke-tested                                                               |
| 10  | Approval after shelf became occupied | covered by re-validation in approve RPC                                       |
| 11  | Approval with expiry now past        | covered by `p_expiry_override_accepted` gate                                  |
| 12  | Reject without note                  | covered by 10-char min validation                                             |
| 13  | Auto-expire 14d                      | ⏳ Phase 3 (A.5 cron)                                                         |
| 14  | Concurrent approve                   | covered by `FOR UPDATE` lock                                                  |
| 15  | Direct INSERT bypass                 | ⏳ Phase 3 (A.6 trigger)                                                      |

UAT for cases 2-12 happens after Phase 2 FE ships (per PRD §11 sequencing).

## Pre-deploy checks recorded

- `pg_proc` callers of `POD_ADD`: only `get_operational_signals` (read-only `get_*` helper). No write-path overlap.
- src/ + supabase/ grep for `POD_ADD`: zero matches outside this PRD's own migrations.
- `tg_audit_pod_inventory` AFTER INSERT/UPDATE/DELETE trigger confirmed live on `pod_inventory` — Article 8 satisfied (writes land in `write_audit_log`).
- `pod_inventory` indexes: `idx_pod_inv_active_shelf` is a UNIQUE partial index on `(machine_id, shelf_id, boonz_product_id) WHERE status='Active'`. Backs the approve RPC's `unique_violation` defense.
- `pod_inventory_edits` snapshot semantics: avg 1.62 snapshot_dates per (machine, shelf, product), max 14. Multi-row history is fine; the Active partial-unique-index enforces "exactly one current Active row" which is what matters for the add flow.

## Blocked or deferred

Nothing blocked. Three Phase 3 items flagged by Cody at review time:

1. **Amendment 008** — `pod_inventory_edits` belongs in Appendix A under the Amendment 007 precedent (it's the proposal substrate for protected entity `pod_inventory`). FE INSERT exception clause must mirror Amendment 007's shape for `inventory_control_attempt`. Tracked as TaskList item #9.
2. **A.5 cron binding** — the cron `auto_expire_pod_add_proposals` (to be drafted at P3.A) must be SECURITY DEFINER, set the three `set_config` markers, and UPDATE rows WHERE `status='pending'` only (no reverse transition from approved/rejected). Cody will enforce at P3.A review time.
3. **A.6 trigger** — once `Amendment 008` lands and `pod_inventory_edits` joins Appendix A, the generic audit trigger gets installed and writes to `write_audit_log` automatically. Defer trigger work to that amendment.

## Pending (next phases)

- **Phase 2** — FE delivery (TaskList #7): B.1 Add Product button on `/field/inventory/[machineId]`, B.2 add-product dialog (product search + shelf picker + qty + expiry + optional notes/photo), B.3 driver-side pending review section, B.4 rejection toast, C.1-C.5 operator-side review queue on `/app/inventory`. Build clean (tsc + build + lint) gate at G3, then Cody Article 3 FE review, then commit.
- **Phase 2 UAT** — Section 9 cases 1-12 with CS after FE ships.
- **Phase 3** — A.5 cron, A.6 trigger (G4 caller-audit), C.6 Inventory Control Session integration, Amendment 008.
- **Phase 3 UAT** — Section 9 cases 13-15.

## Notes for next maintainer

- PRD §6.A.1 wording "when edit_type='add_new_product', pod_inventory_id IS NULL" was ambiguous — it's an INSERT-time invariant (the row doesn't exist yet at propose), not a row-level invariant. The approve RPC links pod_inventory_id post-INSERT for audit traceability. Hotfix #2 dropped the wrong-direction NULL clause.
- Two pre-existing CHECK constraints on `pod_inventory_edits` whitelist `edit_type` and `status` values. Adding any new value to either column requires a forward-only DROP+ADD migration. The live edit_type whitelist now also includes `add_new_product`; the live status whitelist now also includes `expired`.
- `destination_shelf_id` is now dual-purpose: swap/move flow ("the shelf the existing row is moving TO") and add flow ("the shelf the new row is being CREATED on"). Column comment carries the dual semantic. Zero existing data has `destination_shelf_id IS NOT NULL` for any other flow, so reuse is safe.
- All three RPCs follow the Phase G P1 `attempt_inventory_correction` template. New canonical writers should mirror this template (SECURITY DEFINER, `SET search_path TO 'public', 'pg_temp'`, role check via `user_profiles` join, all three `set_config('app.*')` markers, structured `jsonb` return).
