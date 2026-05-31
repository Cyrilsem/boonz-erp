# Claude Code /goal Command — PRD-015 (condensed, <4000 chars)

```
/goal Implement PRD-015 for boonz-erp (Next.js + Supabase eizcexopcuoycuosittm). Read it first; phases A→B→C→D: docs/prds/refill-pipeline/PRD-015-refill-reliability-and-machine-toggle.md

RULES
- The 2026-05-30 diagnostic report is fabricated; do NO bulk "pod_inventory=WEIMI" overwrite.
- RPC bodies live in Supabase, not the repo. Fetch via pg_get_functiondef before editing; base the migration on it. Never guess.
- Issue 1 Bug 1 (picker TABLE->jsonb) already shipped (phaseF_fix_auto_generate_draft_picker_contract). Skip.
- Forward-only migrations (ts prefix); no _v2/edit-in-place. DEFINER writers set app.via_rpc/app.rpc_name, validate role+inputs, use audit trigger.
- Protected tables (machines_to_visit, pod_inventory, pod_refill_plan, planned_swaps): Cody verdict per writer.
- NEVER delete pod_inventory rows (archive only); never cut a qty without a per-row diff.
- Write migration FILES only; apply NOTHING to prod. Per phase output SQL+diff, STOP for sign-off.
- Never auto-confirm machines in cron/trigger/n8n; confirm_machines_to_visit stays operator-initiated.

PHASE A — machine toggle (AC#10-13)
A1 ALTER TABLE machines_to_visit ADD COLUMN is_included boolean NOT NULL DEFAULT true; patch pick_machines_for_refill ON CONFLICT to reset is_included=true.
A2 DEFINER RPCs (operator_admin/superadmin/warehouse, by machine_id): set_machine_inclusion(plan_date,machine_id,is_included); bulk_set_machine_inclusion(plan_date,is_included). No raw FE writes.
A3 FE RefillPlanningTab (/refill): checkbox per card (default on); unchecked collapses to 1 line + sinks under "Excluded (N)", opacity .5; bar "N of M selected" + Include/Exclude all; Commit btn disabled at 0; sync via set_machine_inclusion; sort included(severity) then excluded; npx next build.

PHASE B — decouple pick from engine (AC#1-3; needs A1)
B1 build_draft_for_confirmed(plan_date) jsonb (DEFINER): _assert_gate_zero in BEGIN/EXCEPTION -> on fail RETURN {status:'awaiting_confirmation'}; else engine_add_pod(d,14) then engine_swap_pod(d,2,0.30,14); return draft_ready shape. MUST NOT call pick_machines_for_refill.
B2 Repoint cron 13 (phaseF_stage1_prep_8pm_dubai) -> build_draft_for_confirmed(CURRENT_DATE+1); keep schedule. auto_generate_draft = manual-only (re-picks).

PHASE C — launch gate + alert (AC#8-9)
C1 assert_product_launch_ready(pod_product_id, expected_weimi_names text[]) jsonb: blocked unless (a) product_mapping sums 100% and (b) every expected WEIMI name resolves. Precondition on the planned_swaps launch insert; reject with detail.
C2 cron_unmatched_weimi_alert() jsonb: scan v_live_shelf_stock match_method='unmatched' AND is_eligible_machine; one finding per distinct goods_name_raw into the findings ledger (reuse phantom_pod_alert infra). Daily cron.
C3 (AC#14) Add 'warehouse' to role check of edit_pod_refill_row, stop_pod_refill_row, restitch_after_edits (keep operator_admin/superadmin). Tier-only, no logic change; locked-row guards intact.

PHASE D — pod_inventory reconciliation (AC#4-7; gated, NO mutation without per-shelf OK)
D1 View v_pod_inventory_shelf_mismatch: per (machine_id,shelf_id) compare Active pod_inventory product (via product_mapping) vs v_live_shelf_stock.pod_product_id, resolved IDs, DISTINCT ON; verdict product_mismatch|multi_active_rows|no_pod_row|weimi_unmatched|ok.
D2 reconcile_pod_inventory_shelf(machine_id,shelf_id,new_pod_product_id,reason,confirm bool DEFAULT false): confirm=false->return diff, no write; confirm=true->archive Active rows (status='Inactive'+removal_reason, NO DELETE), insert one Active row. Refuse if shelf past 'pending' or new id NULL.
D3 One-time: per mismatch shelf whose WEIMI product is Plaay, call confirm=false, print diff, STOP per shelf. ~14 shelves; no fleet loop.
D4 AFTER D3 applied: partial unique index uniq_active_pod_per_shelf ON pod_inventory(machine_id,shelf_id) WHERE status='Active'. Not before single-Active.

OUTPUT: per phase: Cody verdicts, diffs, apply order, STOP. Log ACs in EXECUTION-LOG.md.
```
