/goal PRD-052: build a DEFINER RPC convert_removes_to_m2m_transfer and run it to fix the NOVO->MINDSHARE Vitamin Well move that was recorded as plain Removes (draining to the warehouse instead of reaching MINDSHARE). MODE AUTO, no questions. Full spec: boonz-erp/docs/prds/PRD-052-m2m-convert-removes-to-transfer.md. Backend only, touches ONLY refill_dispatching.

CONTEXT (verified): receive_dispatch_line already skips WH when is_m2m=true; the bug is these 7 NOVO removes are is_m2m=false (warehouse-drain path). All 7 item_added=false (WH not yet credited - preventive). driver_confirmed_qty is truth (totals 11); planned quantity stale on 2 rows.

PRE: git pull --rebase main; branch feat/prd-052-convert-m2m. Dara design then Cody (Articles 1/4/6/8/12/14) before applying.

BUILD (forward migration):

1. CREATE DEFINER convert_removes_to_m2m_transfer(p_dispatch_ids uuid[], p_dest_machine_id uuid, p_dest_shelf_id uuid, p_reason text) RETURNS jsonb. Sets app.via_rpc='true' + app.rpc_name. Validate: array non-empty; every id exists, action='Remove', same source machine, item_added=false, cancelled=false, returned=false, is_m2m=false; dest machine + shelf exist. Role: auth.uid() IS NULL OR EXISTS(user_profiles role IN operator_admin/superadmin/manager) - the null branch is trusted server-side remediation, document it in the header.
2. Logic: one shared v_transfer_id=gen_random_uuid(). For each source row: (a) UPDATE source SET quantity=COALESCE(driver_confirmed_qty,quantity), is_m2m=true, m2m_transfer_id=v_transfer_id, comment tagged 'M2M retro'; (b) INSERT dest 'Add New' on p_dest_machine_id/p_dest_shelf_id, same pod_product_id/boonz_product_id, quantity=COALESCE(driver_confirmed_qty,quantity), is_m2m=true, m2m_transfer_id=v_transfer_id, from_warehouse_id=NULL, packed=true, dispatched=true, picked_up=false; (c) link source.m2m_partner_id=dest_id AND dest.m2m_partner_id=source_id. Do NOT touch pod_inventory or warehouse_inventory (both machines reconcile from WEIMI; avoids double-counting the already-physical move). Idempotency: raise if any input row is already is_m2m=true.
3. Add the fn name to the enforce_canonical_dispatch_write allowlist (same migration). Grants authenticated + service_role.

TEST (BEGIN..ROLLBACK first, then real):

- T1 run on the 7 ids -> MINDSHARE: 7 sources is_m2m=true, qty fixed (Zero Peach 1, Upgrade 1); 7 dest Add New on shelf 0d88be35; pairs linked; one transfer_id; total 11.
- T2 no new warehouse_inventory REMOVE-RECEIVE/return row for these boonz ids; item_added stays false.
- T4 item_added=true row -> raise + full rollback. T5 mixed source machine/non-Remove -> raise. T6 re-run on converted ids -> raise. T7 block_orphan_internal_transfer does NOT fire. T8 one write_audit_log row per mutated row.
- STOP and report on any failure; do not run the real conversion on a failing build.

EXECUTE (after tests pass): call convert_removes_to_m2m_transfer with p_dispatch_ids = ['06a5c6ba-d216-4cf8-8efd-3f6dfa4aa7d9','9d8b6691-d372-4bc7-aa15-ddc14f7fb328','ff9afb9e-741b-421c-bf6d-ab0a209ec48a','ae21cdb2-8cf8-494e-a79a-feb753a94bb8','2009dd48-8582-4d7a-b210-d49ff3925037','0a8eefa5-28e7-4f16-ab42-71fbfd0ae23a','958145c4-688d-4ecd-8f85-d0a93b48568d'], p_dest_machine_id='9a09a89b-cb1b-4588-85f3-837c481e287e', p_dest_shelf_id='0d88be35-c24e-484c-99aa-57951ac33264', p_reason='NOVO A16 VW swap -> MINDSHARE (PRD-052 remediation)'.

VERIFY post-run: re-query the 7 sources (is_m2m=true, qty), the 7 MINDSHARE dest legs, the pairing, confirm zero warehouse credit. Print before/after.

CLOSE: update CHANGELOG.md, MIGRATIONS_REGISTRY.md, RPC_REGISTRY.md (new canonical writer), set PRD-052 APPLIED with migration name + verification output.

HARD SAFETY: backend limited to the new RPC + allowlist line; no pod_inventory/warehouse_inventory writes; no picker/engine change; swaps_enabled stays false; no OTHER dispatched/packed rows touched; forward-only migration; rebase --autostash; do NOT push to main without my explicit go-ahead.
