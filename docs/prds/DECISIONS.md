# Clean Ecosystem Loop — DECISIONS

## PRD-CLEAN-01 (2026-07-11, partial: M1 applied, M2 blocked)

### Verified vs claimed state (before)

- Drift confirmed: 30/30 fresh-snapshot machines drifted; ledger 4,677 vs Weimi 5,176 units.
- STALE PRD claims: expired-in-machine Active units = 0 (not 1,095/819 — cleaned by earlier
  drift-kill work); worst machine is AMZ-1038-3001-O1 at 557 vs 160 (not 4,194 vs 160).
- Shelf-grain plan (dry run): 137 shelves to trim (1,319 units), 440 to add (2,903 units,
  246 needing inserts); 54 orphan NULL-shelf Active rows (122 units); 32 Weimi slots on
  1 machine have no shelf_configurations row (250 units unrepresentable in the ledger).

### Judgement calls (all logged in fn behaviour + audit rows)

1. `idx_pod_inv_active_shelf` (UNIQUE machine+shelf+boonz_product WHERE Active) forbids a
   second Active row per product: "insert unattributed batch" therefore (a) tops up an
   existing NULL-expiry row, else (b) inserts a NULL-expiry row for a mapped product with no
   Active row, else (c) converts a zero-stock Active row to the unattributed bucket, else
   merges into the newest dated batch (notes say so).
2. Audit CHECK on source extended with a single value 'drift_resync'; sub-reasons
   ('drift_resync', 'drift_resync_product_mismatch', 'drift_resync_unattributed',
   'drift_resync_orphan_null_shelf') carried in notes; reference_id = 'drift-resync-<run>'
   (deliberately NOT 'manual-refill-%'/'adjust-%' so resyncs never count as visit evidence).
3. Product-mismatch test uses ANY Active product_mapping (machine-scoped or global) — the
   broad match writes off less, the safer direction. product_mapping is many-to-many
   (up to 230 boonz per pod product), so membership, not equality.
4. Write-offs zero current_stock but do NOT flip status (less state change; unique index
   unaffected; fully reversible from audit old_stock).
5. Freshness gate: machine skipped (reported, never zeroed) when latest v_live_shelf_stock
   snapshot_at is NULL or older than 48h. Caught ALHQ-1016 (April snapshot) and
   ALJ-1014_OLD (none).
6. Orphan NULL-shelf Active rows are zeroed (audit: drift_resync_orphan_null_shelf) — they
   can never reconcile to any shelf and inflate machine totals.
7. Added p_dry_run (not in PRD) — used to validate fleet-wide before the real run.

### Rollback

- docs/prds/rollback/pod_inventory_audit_log_source_check_2026-07-11.sql (CHECK restore +
  DROP FUNCTION). Data rollback per row from pod_inventory_audit_log
  WHERE reference_id LIKE 'drift-resync-%'.

### Halt

M2 (fleet data run) denied by the auto-mode permission classifier; not bypassed via
execute_sql on purpose. See docs/prds/BLOCKED.md for resume steps. PRD-CLEAN-02..07 not
started (strict-order rule).

### Git

Working tree had ~30 pre-existing modified files from other sessions (branch
fix/prd-099-approve-return-provenance). Deviation from the goal's `git add -A` + push to
main: committed only loop-created files, no push — sweeping unrelated uncommitted src/
changes into a cleanup commit would deploy unreviewed UI work to prod via Vercel.

### RESOLVED (2026-07-11 ~14:00 UTC): M2 executed + verified attended by CS

- Fleet run at 13:58:22 UTC (single run ref): 37 machines, 1,468 units written off,
  2,793 units added unattributed — 694 audit rows with source='drift_resync'; audit
  delta sums match the ledger delta exactly (battery check 3 PASS).
- Drift = 0 on all touchable machines at run time (battery check 1 PASS); idempotency
  confirmed — second run touched 0 shelves (battery check 4 PASS).
- Expired >30d in machines: already 0 before the run (claim was stale); recorded as
  before=0 / after=0 (battery check 2 PASS trivially).
- Post-run re-check at 14:0x UTC showed 46 shelves drifted against the 14:00:40 snapshot
  (2 min AFTER the resync) — post-resync sales movement, not resync failure. This is the
  expected ongoing decrement gap; per PRD follow-up, watch convergence ~7 days and open
  PRD-CLEAN-08 if fleet drift exceeds 2%.
- Untouchable remainder (by design, never zero on missing data): ALHQ-1016 (stale Apr
  snapshot), ALJ-1014_OLD (no snapshot), and 22 ledger-stocked shelves absent from
  fresh snapshots (AMZ-1029/1038/1057/1068, WH1-2002).
- PRD-CLEAN-01 marked DONE; BLOCKED.md cleared; loop resumes at PRD-CLEAN-02.

## PRD-CLEAN-02 (2026-07-11)

### Verified vs claimed state (before)
- STALE PRD claim: correlation tables were NOT zero-row — 1,119 per-machine +
  1,953 per-loc rows, all computed_at 2026-05-11 (one manual run two months ago,
  never scheduled). The real problem was staleness + no cron.
- find_substitutes_for_shelf signature: (p_plan_date date, p_machine_id uuid,
  p_shelf_id uuid, p_anchor_pod_product_id uuid, p_top_n int, p_aggressiveness_pct int).

### What changed
1. refresh_correlation_pod: day-bucketing fixed from UTC (transaction_date::date,
   now()::date spine) to Asia/Dubai per the non-negotiable timezone rule. Exactly 4
   lines changed (diff-verified); thresholds/pairing/writes untouched. Canonical-writer
   change: original saved to docs/prds/rollback/refresh_correlation_pod_2026-07-11.sql.
2. Ran refresh: 2,751 per-machine + 2,866 per-loc rows in 9.9s (window 60d,
   min_n_days 14, min_sales_per_side 5). No threshold changes needed.
3. cron.schedule('refresh_correlation_weekly', '0 1 * * 0', ...) = Sunday 05:00 Dubai,
   statement_timeout 1200000. Verified active in cron.job.

### Verification battery
1. Row counts > 0: PASS (2,751 / 2,866).
2. Smoke test: PASS 3/3 (AMZ-1029, AMZ-1038, VOXMCC-1005 — all rows
   source='global_basket_fit', pearson 0.36-0.73).
3. cron.job row exists + active: PASS.

### Rollback
- Function: docs/prds/rollback/refresh_correlation_pod_2026-07-11.sql
- Cron: SELECT cron.unschedule('refresh_correlation_weekly');
- Data: derived cache; re-run refresh_correlation_pod() regenerates.
