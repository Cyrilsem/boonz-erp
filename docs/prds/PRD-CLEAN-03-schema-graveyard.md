# PRD-CLEAN-03 — Schema Graveyard (reversible declutter)

Status: BLOCKED (2026-07-11) — analysis complete, migration written + reviewed
(20260711144500_prd_clean_03_schema_graveyard.sql: 10 tables + 1 view + 13 fns move,
7 candidates KEPT as live-referenced); apply denied by auto-mode classifier, needs
attended approval. Baseline next build passes. See docs/prds/BLOCKED.md.
Priority: P1

## Problem

140 public tables; ~20 are dead (0 rows, no live writers) across 4 engine
generations. They make every schema read, migration, and AI-assisted session
slower and riskier.

## Design

`CREATE SCHEMA IF NOT EXISTS graveyard;` then `ALTER TABLE ... SET SCHEMA
graveyard` — NO DROPs. Fully reversible.

### Phase A — zero references (verified: 0 views, 0 functions reference them)

- pod_inventory_backup_20260416
- pod_inventory_backup_20260421
- weimi_daily_staging
- weimi_recon_staging
- _debug_log

### Phase B — dead tables referenced only by dead functions

Candidates (table → referencing function count at audit time):
refill_plan_lock (5), daily_plan_drafts (5), rotation_proposals (4),
refill_dispatch_plan (3), daily_pipeline_runs (2),
engine_recommendation_snapshot (2), refill_plan_deviations (1),
refill_action_proposals (1), refill_commit_log (1),
pod_inventory_seed_staging (1), refill_instructions (1 view + 2 fns),
machine_summary (1 view + 1 fn), slot_capacity_max (1 view + 1 fn).

For each: list the referencing functions/views. A referencing function is
LEGACY iff it is NOT in the live pipeline set:
{pick_machines_for_refill, confirm_machines_to_visit, build_draft_for_confirmed,
engine_add_pod, engine_swap_pod, engine_finalize_pod, approve_pod_refill_plan,
stitch_pod_to_boonz, write_refill_plan, confirm_stitched_plan,
push_plan_to_dispatch, resolve_driver_intent, find_substitutes_for_shelf,
mark_internal_transfer, edit_pod_refill_row, stop_pod_refill_row,
swap_pod_refill_row, restitch_after_edits, get_pod_refill_draft,
resolve_refill_plan_date, all cron.job commands}
AND is not called by anything in that set (check pg_get_functiondef of each
live function for the candidate function's name).
If legacy → move function AND table to graveyard together (functions:
`ALTER FUNCTION ... SET SCHEMA graveyard`). If any doubt → leave in place and
note in DECISIONS.md. Conservative wins.

### Explicitly KEPT (do not move)

- weekly_procurement_plan — written by a chat-side skill, 0 DB refs is expected.
- adyen_staging, weimi_staging — live ingestion.
- All *_log / audit tables with rows.

### FE safety

Before Phase B: `grep -rn "<table_name>" src/` for every candidate. Any hit in
src/ → do not move, log it.

## Verification battery

1. Full pipeline dry cycle on a NON-LIVE date (tomorrow+1, then clean up picks):
   pick_machines_for_refill → build_draft_for_confirmed →
   get_pod_refill_draft → stitch_pod_to_boonz(date, true). Zero errors.
2. `npx next build` — 0 errors.
3. Every moved object listed in DECISIONS.md with its restore command.
