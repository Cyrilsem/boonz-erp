# BLOCKED — Clean Ecosystem Loop halted at PRD-CLEAN-03 apply (2026-07-11 ~14:50 UTC)

## Why

The auto-mode permission classifier denied the graveyard migration (moving 10 tables,
1 view, 13 functions out of public in prod). Not bypassed via execute_sql, per the
established pattern (PRD-CLEAN-01 M2, PROGRAM-2026-05-25).

## State

- PRD-CLEAN-01: DONE. PRD-CLEAN-02: DONE (committed).
- PRD-CLEAN-03: analysis COMPLETE, migration WRITTEN and reviewed, NOT applied.
  - Migration: supabase/migrations/20260711144500_prd_clean_03_schema_graveyard.sql
  - Restore: docs/prds/rollback/graveyard_restore_2026-07-11.sql
  - Full decision matrix in DECISIONS.md (what moves, what stays and why).
- Baseline `npx next build`: PASSES (0 errors) before any move.
- Nothing was moved; prod schema unchanged by PRD-03 so far.

## To resume

1. Attended: apply supabase/migrations/20260711144500_prd_clean_03_schema_graveyard.sql
   via Supabase MCP apply_migration (name: prd_clean_03_schema_graveyard).
2. Verification battery (avoid 15:45-16:30 UTC draft-cron window):
   a. Pipeline dry cycle on a NON-LIVE date (CURRENT_DATE+2):
   pick_machines_for_refill -> build_draft_for_confirmed -> get_pod_refill_draft ->
   stitch_pod_to_boonz(date, true); zero errors; then clean up the test picks
   (pending rows only).
   b. npx next build - 0 errors.
3. Continue at PRD-CLEAN-04.
