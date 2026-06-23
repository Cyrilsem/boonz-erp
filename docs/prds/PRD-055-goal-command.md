/goal PRD-055: consolidate field notes into ONE engine-aware channel (Signals = refill_edit_signals), retire the Field Capture + Tracker tabs, preserve all data. MODE AUTO but STOP for CS before any data migration. Full spec: boonz-erp/docs/prds/PRD-055-consolidate-notes-into-signals.md. FE (Stax) + backend deprecation (Article 13). No engine logic change.

CONTEXT (verified): only Signals (refill_edit_signals, 655 rows) feeds the engine (engine_swap_pod + trigger tg_capture_refill_edit_signal). Tracker (action_tracker, 92) and Field Capture (machine_field_notes, 6) are NOT read by the engine; driver_feedback_notes (0) is display-only. strategic_machine_tags + v_machine_health_signals stay as-is.

PRE: git pull --rebase main; branch feat/prd-055-notes-consolidation.

BUILD (phased; STOP for CS between phases):
P1 Dara design + Cody review: add refill_edit_signals.source values ('field_note','action'); design a kept read-only "Issues" view over action_tracker for genuine bugs. Forward-only.
P2 Data migration (forward, idempotent) - SHOW CS the split list first, do not run unprompted:

- machine_field_notes (6): migrate into refill_edit_signals as source='field_note' (or archive); none lost.
- action_tracker (92): operational machine notes -> refill_edit_signals (source='action'); genuine bugs/issues (e.g. OMDBB-1020 packing FE) -> stay in the Issues view, NOT folded into the engine signal stream (avoid polluting engine_swap_pod input). Confirm the split rule with CS.
  P3 Stax FE: remove Field Capture + Tracker tabs from the field app; make Signals the single notes entry point; keep an Issues link for CS. Browser-verify 375px (no h-scroll, targets >=44px, axe clean); self-review vs web-design-guidelines.
  P4 Deprecate retired writers (machine_field_notes writer; any action_tracker writer being retired): SECURITY INVOKER + REVOKE EXECUTE, log for 90-day monitoring (Article 13). Do NOT DROP.

TEST (all must pass):

- T1 engine_swap_pod output byte-identical before/after (diff-gated) - we only add/redirect note SOURCES, never change signal scoring.
- T2 all 6 machine_field_notes accounted for (migrated/archived), none lost.
- T3 all 92 action_tracker rows accounted for (operational->signals, bugs->Issues), none lost.
- T4 field app: one notes entry (Signals); Field Capture + Tracker tabs gone; Issues view reachable.
- T5 retired writers INVOKER+REVOKEd, monitored, not dropped.
- T6 a11y/375px on changed screens.
- STOP and report on any failure or before any data migration.

CLOSE: update CHANGELOG.md, MIGRATIONS_REGISTRY.md, RPC_REGISTRY.md; set PRD-055 APPLIED (or per-phase status) with migration names + FE commit.

HARD SAFETY: engine_swap_pod byte-identical; swaps_enabled stays false; NO data loss (migrate/archive, never delete); deprecate not drop (Article 13); forward-only migrations; rebase --autostash; do NOT push to main without my explicit go-ahead; pause for CS before the P2 data migration.
