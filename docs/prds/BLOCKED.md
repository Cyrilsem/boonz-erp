# BLOCKED — Clean Ecosystem Loop halted at PRD-CLEAN-01 M2 (2026-07-11 ~06:45 UTC)

## Why

The Claude Code auto-mode permission classifier denied the M2 data run
(`SELECT * FROM resync_pod_inventory_from_weimi(NULL, false)` via apply_migration):

> [Production Deploy] Running a fleet-wide destructive data migration (zeroing/trimming
> pod_inventory across all machines, p_dry_run=false) against the live production Supabase DB;
> the user's own standing rule requires per-row CS approval for destructive writes on
> protected entities - run outside auto mode so the user can review the permission prompt.

Routing the same write through execute_sql would bypass the intent of that denial, so the
loop stopped here instead (same pattern as PROGRAM-2026-05-25: classifier blocks unattended
destructive applies; document and queue for attended execution).

## State of the system (safe, consistent)

- APPLIED to prod: PRD-CLEAN-01 M1 (DDL only, no data touched)
  - `resync_pod_inventory_from_weimi(p_machine_id uuid DEFAULT NULL, p_dry_run boolean DEFAULT false)`
    (verified in pg_proc)
  - pod_inventory_audit_log source CHECK extended with 'drift_resync'
    (rollback: docs/prds/rollback/pod_inventory_audit_log_source_check_2026-07-11.sql)
  - mirrored: supabase/migrations/20260711063500_prd_clean_01_resync_pod_inventory_from_weimi.sql
- NOT RUN: M2 data run (supabase/migrations/20260711064000_prd_clean_01_resync_data_run.sql)
- PRD-CLEAN-02..07: not started (strict-order rule).

## Dry-run evidence (fleet-wide, 2026-07-11 06:40 UTC, snapshots fresh at 06:00)

- 37 machines would be processed; 2 correctly skipped (ALHQ-1016-0000-O1 stale snapshot
  2026-04-07; ALJ-1014-0200-O1_OLD no snapshot) - skip-not-zero behaviour confirmed.
- Totals: ~1,468 units written off (incl. 55 orphan NULL-shelf rows / 122 units),
  ~2,756 units added as unattributed NULL-expiry stock.
- Shelves holding ledger stock but absent from the Weimi snapshot are skipped and reported:
  AMZ-1029 (5), AMZ-1057 (6), AMZ-1068 (6), AMZ-1038 (3), WH1-2002 (2). These machines will
  not reach |ledger-weimi|=0 until those shelves are resolved (never zero on missing data).
- PRD claims re-verified before acting: drift is real (30/30 fresh-snapshot machines,
  ledger 4,677 vs physical 5,176) but the "1,095 expired / 819 >30d" claim is STALE -
  Active-row expired units are already 0 (cleaned by earlier drift-kill work), and the
  "4,194 vs 160" outlier is now 557 vs 160 (AMZ-1038-3001-O1).

## To resume

1. In an attended session (not auto mode), run and approve:
   `SELECT * FROM resync_pod_inventory_from_weimi(NULL, false);`
   (as apply_migration `prd_clean_01_resync_data_run`, outside 15:45-16:30 / 01:45-02:30 UTC)
2. Run the PRD-CLEAN-01 verification battery (in the PRD; re-run the RPC to prove
   idempotency - second run must touch 0 shelves).
3. Continue the loop at PRD-CLEAN-02.

## Note on the working tree

The repo had ~30 pre-existing modified files (docs + src) from other sessions when this loop
started, on branch fix/prd-099-approve-return-provenance. Only files created by this loop were
committed; the pre-existing modifications were left untouched (a blanket `git add -A` on a
dirty tree would have swept unrelated, possibly unfinished work into a cleanup commit and
deployed it to prod via Vercel).
