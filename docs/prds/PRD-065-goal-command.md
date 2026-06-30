# Claude Code /goal Command - PRD-065 (design + build, gated apply)

Paste into Claude Code in `boonz-erp`. Supabase eizcexopcuoycuosittm. Builds schema + writers + cron + FE capture, but does NOT auto-apply protected-table writers or enable the cron without Cody sign-off and a CS green light. No em dashes. (/goal block is under 4000 chars.)

```
/goal Implement PRD-065 (docs/prds/PRD-065-field-reconciliation-and-phantom-expiry-sweep.md); read it first. Close the field-action capture gaps (Pillar A) and add a phantom-expired sweep (Pillar B) so driver actions reach the DB and expired ghosts self-clear. AUTO MODE: keep going, self-run Dara then Cody on every writer, build the pieces, but STOP before applying any protected-table writer or enabling the cron until I green-light. No git push.

HARD RULES
- Canonical RPCs only. No direct INSERT/UPDATE/DELETE on pod_inventory / warehouse_inventory / refill_dispatching / pod_inventory_edits from cron/n8n/chat. New writers are SECURITY DEFINER, take an explicit caller id, pass Cody before server use.
- Idempotent + reversible (write-offs = Inactive/0/removal_reason, the backfill_archive pattern, never delete). Detect state first, no-op if already applied.
- Expired = write-off (loss, no WH credit). Returns credit WH. Keep distinct.
- Flag-gated: sweep behind an inventory params flag, default OFF, dry-run first.
- Forward-only. Fetch every existing signature (pg_get_functiondef) before extending it.

BUILD (Dara designs -> Cody reviews -> migration files; present, hold protected writers for my OK):
Pillar A (capture, ship first):
- A1: guard so pod_inventory_edits sold/partial_sold/return_to_warehouse/add_stock/add_new_product cannot be created with quantity_update NULL or <=0 (expired exempt). Plus set_edit_quantity_and_approve(edit_id, qty, caller_id, note) repair RPC (what unblocked JET Pepsi edit 5d5ab4a7 by hand).
- A2: create_field_add_edit(machine_id, pod_product_or_shelf, boonz_product_id, qty, expiry, caller_id, reason): resolve shelf from product_mapping (e.g. M&M Choc Nuts under Chocolate Bar), insert a pending add_stock edit. Approval still via approve_pod_inventory_edit.
- A3: at dispatch close (confirm_machine_packed / receive_dispatch_line) auto-mark any unit with filled_quantity < quantity and not returned as returned for the remainder and credit WH via return_dispatch_line (fixes NOVO Popcorn Salted 4-unit limbo). Idempotent.
Pillar B (sweep):
- B1: v_expired_inventory view = pod + warehouse Active+expired, with location (machine/warehouse), units, expiry, age_days, bucket (zero_stock_residual vs stock_bearing). Make it the dashboard expired source.
- B4: warehouse_expire_writeoff(wh_inventory_id, reason, caller_id) server-callable WH expiry/defective write-off (stock 0, status Inactive, inventory_audit_log), since adjust_warehouse_stock is auth.uid-gated. Unblocks the Al Ain defective case.
- B2: sweep_expired_inventory(p_dry_run, p_caller_id): zero_stock_residual -> auto write-off (pod via backfill_archive_pod_inventory_row, warehouse via warehouse_expire_writeoff); stock_bearing -> push to the To-validate driver queue (extend "past expiry, stock 0, driver verify" to stock>0 = confirm removal). Schedule via pg_cron only after a clean dry-run and my OK.
- B3: driver-confirm closeout that writes off a queued stock_bearing row (no WH credit) on physical-removal confirm. Idempotent.

PROCESS
1. Read the PRD. Fetch live signatures for approve_pod_inventory_edit, backfill_archive_pod_inventory_row, adjust_warehouse_stock, confirm_machine_packed, receive_dispatch_line, return_dispatch_line, log_manual_refill first.
2. Dara designs each; Cody reviews each writer; write migrations under supabase/migrations with up/down.
3. Build A then B. Show me each diff + Cody verdict. Apply only non-protected pieces (view, guard) if Cody is green; STOP before any pod/warehouse writer or the cron. Run B2 dry-run and show what it WOULD clear (should match the 20 rows cleared 29 Jun plus new ones).
4. Output docs/prds/PRD-065-EXECUTION-LOG.md: per object designed/cody-verdict/built/applied|held + the dry-run report + the list awaiting my green light.

Do not git push. Do not enable the sweep cron without my explicit OK.
```

PRD: `boonz-erp/docs/prds/PRD-065-field-reconciliation-and-phantom-expiry-sweep.md`.
