/goal Run PRD-054 then PRD-055 back-to-back in one session; fully close each before starting the next. MODE AUTO, no questions. Full specs + per-PRD goals (follow them verbatim; this wrapper only sequences + sets shared gates): boonz-erp/docs/prds/PRD-054-returns-queue-m2m-exclusion-and-vox-guard.md (+ PRD-054-goal-command.md) and PRD-055-consolidate-notes-into-signals.md (+ PRD-055-goal-command.md).

SHARED RULES: forward-only migrations; fetch live bodies via pg_get_functiondef before editing; Dara designs, Cody reviews (name the articles); every DEFINER sets app.via_rpc+app.rpc_name and keeps write_audit_log; never touch warehouse_inventory.status (Art 6); mutating tests in BEGIN..ROLLBACK before any apply; NO data loss (migrate/archive, never delete); engine_swap_pod byte-identical; swaps_enabled stays false; a SEPARATE branch per PRD; do NOT push to main without my explicit go-ahead (pause and ask once per PRD).

PHASE 1 - PRD-054 (returns queue, backend only). Branch feat/prd-054-returns-cleanup.

1. CREATE OR REPLACE VIEW v_pending_wh_remove_confirmations adding AND COALESCE(rd.is_m2m,false)=false to its WHERE (read live def first; change ONLY that predicate; keep columns identical).
2. venue_team receive guard in wh_approve_remove_receipt, wh_approve_remove_receipt_multivariant, and the Remove branch of receive_dispatch_line: if the line's machine_id+boonz_product_id is source_of_supply='venue_team', mark received WITHOUT a warehouse_inventory credit (item_added=true, provenance 'venue_owned_no_credit'); do not touch warehouse_inventory.status.
   Run PRD-054 tests T1-T6 (rollback first), apply, VERIFY the 7 PRD-052 M2M rows drop from the queue (before/after count), update CHANGELOG/MIGRATIONS_REGISTRY/RPC_REGISTRY, set PRD-054 APPLIED. STOP, report, ask for go to push branch 1.

PHASE 2 - PRD-055 (notes consolidation, phased; backend + FE). Branch feat/prd-055-notes-consolidation.
P1 Dara/Cody: add refill_edit_signals.source values ('field_note','action') + a read-only Issues view over action_tracker.
P2 data migration (idempotent) - SHOW me the action_tracker split list and PAUSE before running: machine_field_notes(6) -> refill_edit_signals source='field_note'; action_tracker(92) operational -> signals source='action', genuine bugs (e.g. OMDBB-1020) -> Issues view (NOT folded into engine signals). None lost.
P3 Stax FE: remove Field Capture + Tracker tabs, make Signals the single notes entry, keep an Issues link for me; browser-verify 375px (no h-scroll, targets >=44px, axe clean) + self-review vs web-design-guidelines.
P4 deprecate retired writers (machine_field_notes writer; any action_tracker writer being retired): SECURITY INVOKER + REVOKE EXECUTE, 90-day monitor, do NOT DROP.
Run PRD-055 tests T1-T6 (incl. engine_swap_pod byte-identical diff-gate; all rows accounted for). Update registries, set PRD-055 status. STOP, report, ask for go to push branch 2.

CLOSE: one summary covering both - migration/commit per PRD, test pass/fail, anything skipped. Two separate branches; nothing reaches main until I say go for each.

HARD SAFETY: backend changes limited to the objects named above (PRD-054 view + receive guard; PRD-055 signals.source + Issues view + deprecations); no picker/engine logic change; engine_swap_pod byte-identical; swaps_enabled stays false; no auto approve/cancel of real driver-confirmed returns; forward-only migrations; rebase --autostash; pause before the P2 data migration and before each push to main.
