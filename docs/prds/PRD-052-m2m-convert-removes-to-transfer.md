# PRD-052 - Convert plain Removes into an M2M transfer (NOVO Vitamin Well, and the reusable remediation path)

**Status:** Shipped 2026-06-23 (convert_removes_to_m2m_transfer verified live in prod 2026-07-02; approve-path normalize guard added by PRD-071 WS-C3). Migration `prd052_convert_removes_to_m2m_transfer` (file `supabase/migrations/20260623120000_prd052_convert_removes_to_m2m_transfer.sql`). Backend (new DEFINER RPC + forward migration). Touches only `refill_dispatching`. swaps_enabled untouched (false).

> **Applied result (transfer_id `1538f35f-c386-405b-9cb1-dbc1fba94277`):** 7 NOVO-1023 Removes converted to is_m2m=true (qty fixed: Upgrade 0->1, Zero Peach 12->1; total 11); 7 paired MINDSHARE-1009 Add New legs on shelf A16 (0d88be35), born-state packed+dispatched+picked_up=false, from_warehouse_id NULL, total 11; 7 bidirectional pairs; one transfer_id; item_added stays false on all sources; ZERO warehouse credit (0 REMOVE-RECEIVE/return rows); 14 write_audit_log rows.
> **Tests T1-T8 (rolled back) all PASS** before apply. The rolled-back tests caught the real `m2m_consistency` CHECK before the live run: flipped/created is_m2m rows need `source_machine_id` set, `source_kind='m2m'`, `from_warehouse_id` NULL (all within refill_dispatching). Not pushed to main (awaiting CS go-ahead).
> **Owner:** CS (cyrilsem@gmail.com)
> **Created:** 2026-06-23
> **Severity:** HIGH (data integrity). A machine-to-machine move recorded as plain Removes drains stock to the warehouse instead of the destination machine.

## 0. Concrete case (2026-06-23)

NOVO-1023-0000-W0 shelf A16 was swapped (Vitamin Well out, Dubai Popcorn in). 11 Vitamin Well units were pulled, but recorded as plain `Remove` lines (`is_m2m=false`). They were physically carried to MINDSHARE-1009-4500-O1, yet the system has them queued to be received into Central warehouse ("Receiving at warehouse"). Driver-confirmed truth (`driver_confirmed_qty`) totals 11; two stale planned `quantity` values are wrong (Zero Peach 12, one Upgrade 0).

The 7 source dispatch_ids (NOVO, dispatch_date 2026-06-23, action Remove):

| dispatch_id                          | Variant              | driver_confirmed_qty | stale quantity |
| ------------------------------------ | -------------------- | -------------------- | -------------- |
| 06a5c6ba-d216-4cf8-8efd-3f6dfa4aa7d9 | Antioxidant          | 1                    | 1              |
| 9d8b6691-d372-4bc7-aa15-ddc14f7fb328 | Care                 | 2                    | 2              |
| ff9afb9e-741b-421c-bf6d-ab0a209ec48a | Reload (exp 12 Jul)  | 4                    | 4              |
| ae21cdb2-8cf8-494e-a79a-feb753a94bb8 | Reload (exp 23 Aug)  | 1                    | 1              |
| 2009dd48-8582-4d7a-b210-d49ff3925037 | Upgrade (exp 05 Jul) | 1                    | 0              |
| 0a8eefa5-28e7-4f16-ab42-71fbfd0ae23a | Upgrade (exp 02 Aug) | 1                    | 1              |
| 958145c4-688d-4ecd-8f85-d0a93b48568d | Zero Peach           | 1                    | 12             |

Total driver-confirmed = 11. All 7 are `item_added=false` (warehouse NOT yet credited - this is preventive, not corrective).

Destination: MINDSHARE machine_id `9a09a89b-cb1b-4588-85f3-837c481e287e`, Vitamin Well shelf_id `0d88be35-c24e-484c-99aa-57951ac33264`.

## 1. Root cause (verified)

- The canonical cross-machine writer is `swap_between_machines` (writes a paired Remove + Add New, both `is_m2m=true`, shared `m2m_transfer_id`, `from_warehouse_id=NULL`, zero WH movement).
- `flag_remove_with_transfer_intent` already warns that a Remove without `is_m2m` "drains stock to the warehouse instead of reaching the destination machine".
- `receive_dispatch_line` is M2M-aware since 2026-05-18: when `is_m2m=true` it SKIPS warehouse ops. So the accounting layer is fine; the gap is that this move was created as plain Removes, never flagged `is_m2m`.
- `swap_between_machines` cannot be reused here: it only creates fresh pairs, validates source pod stock (already physically removed), and is role-gated to an authenticated operator. We need a path that converts existing dispatched Removes.

## 2. The change (decided)

New DEFINER RPC `convert_removes_to_m2m_transfer(p_dispatch_ids uuid[], p_dest_machine_id uuid, p_dest_shelf_id uuid, p_reason text)`, atomic in one transaction:

1. Validate: every dispatch_id exists, `action='Remove'`, same source machine, `item_added=false`, `cancelled=false`, `returned=false`, `is_m2m=false`; dest machine + shelf exist; `p_dispatch_ids` not empty.
2. Validate role: `auth.uid() IS NULL OR EXISTS(user_profiles role IN operator_admin/superadmin/manager)`. The null-uid branch is the trusted server-side remediation path (same posture as cron/n8n DEFINER calls); document it.
3. Set `app.via_rpc='true'`, `app.rpc_name='convert_removes_to_m2m_transfer'`. Add the name to the `enforce_canonical_dispatch_write` allowlist (forward migration).
4. One shared `v_transfer_id := gen_random_uuid()`. For each source row:
   a. UPDATE source: `quantity = COALESCE(driver_confirmed_qty, quantity)` (fixes the stale Zero Peach 12 and Upgrade 0), `is_m2m=true`, `m2m_transfer_id=v_transfer_id`, comment tagged `M2M retro <source> -> <dest>`.
   b. INSERT a dest `Add New` on `p_dest_machine_id` / `p_dest_shelf_id`, same `pod_product_id`/`boonz_product_id`, `quantity = COALESCE(driver_confirmed_qty, quantity)`, `is_m2m=true`, `m2m_transfer_id=v_transfer_id`, `from_warehouse_id=NULL`, `packed=true`, `dispatched=true`, `picked_up=false` (mirror `swap_between_machines` born-state).
   c. Bidirectional link: source `m2m_partner_id = dest_id`, dest `m2m_partner_id = source_id`.
5. Do NOT touch `pod_inventory` or `warehouse_inventory`. Both machines reconcile physical stock from WEIMI; this avoids a double-count vs `swap_between_machines`'s pod adjustment (the physical move already happened). Document this divergence in the RPC header.
6. Audit row written by the generic trigger (Article 8). Return the transfer_id + per-line result.

Grants: authenticated, service_role. Cody Articles 1, 4, 6, 8, 12, 14.

## 3. Testing rules (all must pass; mutating tests in BEGIN..ROLLBACK first)

| #   | Test                                             | Expected                                                                                                                                                                      |
| --- | ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| T1  | run on the 7 NOVO ids -> MINDSHARE               | 7 source rows now `is_m2m=true`, qty = driver_confirmed (Zero Peach 1, Upgrade 1); 7 dest Add New on MINDSHARE shelf 0d88be35; pairs linked; one shared transfer_id; total 11 |
| T2  | warehouse untouched                              | no new `warehouse_inventory` REMOVE-RECEIVE/return row for these boonz ids after the run; `item_added` stays false on sources                                                 |
| T3  | receive an is_m2m source (sim)                   | `receive_dispatch_line` skips WH ops (no Central credit)                                                                                                                      |
| T4  | guard: a row with `item_added=true` in the batch | RPC raises, whole tx rolls back (atomic)                                                                                                                                      |
| T5  | guard: mixed source machines or a non-Remove row | RPC raises                                                                                                                                                                    |
| T6  | re-run on already-converted ids (`is_m2m=true`)  | RPC raises (idempotency guard, no duplicate dest legs)                                                                                                                        |
| T7  | orphan check                                     | `block_orphan_internal_transfer` does not fire (both legs present + linked)                                                                                                   |
| T8  | audit                                            | one `write_audit_log` row per mutated dispatch row, `rpc_name='convert_removes_to_m2m_transfer'`                                                                              |

## 4. Phasing / gates

- P1 Dara design + Cody review (Articles 1/4/6/8/12/14) of the RPC + allowlist migration.
- P2 Apply forward migration; run T1-T8 in a rolled-back tx, then execute for real on the 7 ids.
- P3 Verify warehouse uncredited + MINDSHARE legs present; update CHANGELOG, MIGRATIONS_REGISTRY, RPC_REGISTRY, this PRD.
- No git push to main without explicit CS go-ahead. No FE change required (this is data remediation + a reusable RPC).
