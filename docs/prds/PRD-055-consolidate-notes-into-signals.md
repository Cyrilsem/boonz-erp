# PRD-055 - Consolidate field notes into one engine-aware channel (Signals)

**Status:** Shipped 2026-06-23..24 (P1/P2/P4/P5 in prod); P3 FE still pending on branch feat/prd-055-notes-consolidation. PRD-071 sweep 2026-07-02. FE (Stax) + backend deprecation (Article 13) + driver-writer redirect. No engine logic change.

> **Applied result:** P1 `prd055_p1_signal_source_and_issues_view` (signal_type +`'note'` inert; `v_action_tracker_issues` view). P2 `prd055_p2_fold_notes_into_signals` (idempotent, no deletes): 6 field notes -> Signals source='field_note', 50 driver_feedback -> source='action', 42 bug/task/decommission kept in Issues view; all 98 accounted. P3 FE: Field Capture + Tracker tabs removed; Signals = single notes channel; Tracker -> Issues (reads the view). P4 `prd055_p4_deprecate_machine_field_notes_writes` (Art 13): write path REVOKEd (no DB/FE writer existed), table kept, 90-day monitor. **P5 `prd055_p5_redirect_driver_writers_to_signals` (2026-06-24, Art 1/4/8/12): `driver_propose_adjustment` + `driver_report_dispatch_outcome` no longer INSERT `action_tracker`; their driver-feedback / re-dispatch note now writes `refill_edit_signals` (source='action', signal_type='note', engine-inert), so NEW driver feedback lands in Signals — closing the going-forward gap. Other writes (driver_recommendations, driver_feedback, refill_dispatching outcome) + validation + app.via_rpc preserved. Rolled-back test: at_delta=0, sig_delta=2, engine md5 pinned.** engine_swap_pod byte-identical (md5 90f26896… unchanged). Tests T1-T5 green; T6 self-reviewed (tab removal; live axe not run — no browser tool).

**Owner:** CS (cyrilsem@gmail.com)
**Created:** 2026-06-23
**Severity:** MEDIUM. Notes are written across three tabs but only one feeds the engine, so signal is lost and operators do not know where to write.

## 0. Findings (verified 2026-06-23)

Mapped each note channel to what reads it:

| Tab               | Table                   | Rows | Read by the refill engine?                                                                                   |
| ----------------- | ----------------------- | ---- | ------------------------------------------------------------------------------------------------------------ |
| Signals           | `refill_edit_signals`   | 655  | YES - `engine_swap_pod` consumes it; trigger `tg_capture_refill_edit_signal` writes one on every refill edit |
| Tracker           | `action_tracker`        | 92   | NO - human bug/action board (written by `driver_propose_adjustment`, `driver_report_dispatch_outcome`)       |
| Field Capture     | `machine_field_notes`   | 6    | NO - written, read by NOTHING (dead-end)                                                                     |
| (driver feedback) | `driver_feedback_notes` | 0    | display-only (`get_machine_feedback_summary`), never in planning                                             |

Engine inputs that are NOT one of these tabs and stay as-is: `strategic_machine_tags` (weekly session) and `v_machine_health_signals` (picker).

## 1. The change (decided: consolidate into Signals only)

Make `refill_edit_signals` (Signals) the single operator-notes channel surfaced in the field app; retire the other two tabs. Preserve all existing data - no destructive loss.

1. **Field Capture (`machine_field_notes`, dead-end):** migrate its 6 rows into `refill_edit_signals` (as `source='field_note'`) or archive them, then retire the tab and deprecate its writer per Article 13 (SECURITY INVOKER + REVOKE EXECUTE, monitor 90 days, then DROP). Read by nothing, so zero engine risk.
2. **Tracker (`action_tracker`, 92 rows):** this is a bug/action board, semantically different from refill-edit signals. Split: entries that are operational machine notes fold into `refill_edit_signals`; entries that are genuine bugs/issues (e.g. the OMDBB-1020 packing FE item) are preserved in a kept read-only "Issues" view (NOT collapsed into the engine signal stream, to avoid polluting `engine_swap_pod` input). The Tracker tab is removed from the field flow; its bug items remain accessible to CS. Confirm the split rule before migrating.
3. **Signals tab:** becomes the one place operators add a machine/refill note. Document that this is the channel the engine reads. No change to `engine_swap_pod` logic or to the `tg_capture_refill_edit_signal` trigger.

## 2. Testing / acceptance

- T1 `engine_swap_pod` output is byte-identical before/after (no behaviour change - we only add/redirect note sources, not change how signals are scored). Diff-gated.
- T2 the 6 `machine_field_notes` rows are accounted for (migrated or archived) - none lost.
- T3 the 92 `action_tracker` rows are accounted for (operational -> signals; bugs -> Issues view) - none lost.
- T4 FE: field app shows one notes entry point (Signals); Field Capture + Tracker tabs gone; Issues view still reachable by CS.
- T5 deprecated writers (`machine_field_notes` writer, and any `action_tracker` writer being retired) are INVOKER + REVOKEd, logged for 90-day monitoring (Article 13), not dropped yet.
- T6 a11y/375px on the changed field screens; self-review vs web-design-guidelines.

## 3. Phasing / gates

- P1 Dara: design the `refill_edit_signals.source` enum addition (`field_note`, `action`) + the kept Issues view over `action_tracker`. Cody review.
- P2 Data migration (forward, idempotent): fold field notes + operational tracker entries into signals; keep bug entries in Issues view. Show CS the split list before running.
- P3 Stax FE: remove Field Capture + Tracker tabs, make Signals the single notes entry, keep an Issues link for CS. Browser-verify 375px.
- P4 Deprecate retired writers (Article 13). No DROP for 90 days.
- No git push to main without explicit CS go-ahead. `engine_swap_pod` stays byte-identical; swaps_enabled untouched.
