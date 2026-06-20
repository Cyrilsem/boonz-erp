# Claude Code /goal Command - PRD-034 (condensed)

Paste the block into Claude Code in `boonz-erp`. Supabase eizcexopcuoycuosittm. Phased; STOP per phase for CS sign-off. Forward-only. No em dashes. Apply nothing to prod.

```
/goal Implement PRD-034 (docs/prds/PRD-034-vox-return-no-wh-credit.md); read it first. Goal: approving a REMOVE for a VOX-supplied product (product_mapping.source_of_supply='venue_team') archives the pod and logs the return, but does NOT credit warehouse_inventory. Boonz-supplied ('boonz') returns keep crediting WH exactly as today.

RULES
- Fetch live bodies via pg_get_functiondef before editing; base the migration on the live receive_dispatch_line, never guess. It may have changed since 2026-06-04.
- Forward-only migrations (ts prefix); no _v2/edit-in-place. The DEFINER writer keeps app.via_rpc+app.rpc_name and the audit trigger; validate nothing new on role (reuse existing gate).
- Protected: warehouse_inventory + pod_inventory via receive_dispatch_line, and the new vox_return_log table. Cody verdict on the table AND on the receive_dispatch_line diff before apply.
- No deletes; the only warehouse_inventory change is to STOP a credit for venue_team, never touch warehouse_inventory.status (Article 6).
- Migration FILES only; apply nothing to prod. Per phase: live body + SQL + diff + Cody verdict, then STOP for CS. Log ACs in an EXECUTION-LOG.md.

STATE (verify live, do not assume):
- /app/inventory approve REMOVE -> wh_approve_remove_receipt(_multivariant) -> receive_dispatch_line. In the action='Remove' branch it CREDITS warehouse_inventory.warehouse_stock by verified qty (by expiry batch, else inserts REMOVE-RECEIVE-<date>), then archives pod_inventory. No source_of_supply check anywhere.
- VOX flag is product_mapping.source_of_supply: 'boonz' (7776 rows/236 products) vs 'venue_team' (65 rows/18 products). NOT machine venue_group, NOT dispatch.source_origin (which is 'warehouse' on all rows incl VOX machines).
- item_added=true already guards double-receive (idempotent).

PHASE A (ledger table): create public.vox_return_log per PRD (cols: vox_return_id pk, dispatch_id, machine_id fk, boonz_product_id fk, qty>=0, expiry_date, source_of_supply, received_by fk, received_at, reason). RLS on; append-only policies (select/insert true, update/delete false). Indexes (machine_id,received_at desc) and (dispatch_id). Dara design -> Cody -> file. Register nothing as a writer (table only).

PHASE B (guard receive_dispatch_line): in the Remove branch ONLY, before the WH-credit block, resolve:
  SELECT source_of_supply INTO v_supply FROM product_mapping
   WHERE boonz_product_id=v_dispatch.boonz_product_id AND status='Active'
     AND (machine_id=v_dispatch.machine_id OR is_global_default)
   ORDER BY (machine_id=v_dispatch.machine_id) DESC, is_global_default ASC LIMIT 1;
  IF v_supply='venue_team' THEN skip the ENTIRE WH-credit block, INSERT vox_return_log(dispatch_id,machine_id,boonz_product_id,qty=p_filled_quantity,expiry=v_effective_expiry,source_of_supply=v_supply,received_by=p_received_by,reason), set v_path='remove_venue_team_no_wh_credit', still run the pod archive + dispatch-received UPDATE; return jsonb adds wh_credit_skipped='venue_team'. ELSE existing behavior byte-for-byte. Add the v_supply text DECLARE. Refill/Add New branches untouched. Cody verdict required (Articles 1,4,6,8).

CONFIRM in report, pass/fail each AC from the PRD:
(1) venue_team REMOVE receipt: warehouse_inventory net delta = 0, pod archived, one vox_return_log row, jsonb wh_credit_skipped='venue_team' - prove with a rolled-back test on a real venue_team SKU.
(2) boonz REMOVE receipt: WH credited as before, no vox_return_log row (regression).
(3) supply resolution prefers per-machine then global default.
(4) diff touches only the Remove branch + the new DECLARE.
(5) vox_return_log append-only + RLS on.
(6) re-receive refused (item_added guard), no dup ledger row.

Start with Phase A. Show the migration file + Cody verdict before applying anything.
```

PRD: `boonz-erp/docs/prds/PRD-034-vox-return-no-wh-credit.md`.
