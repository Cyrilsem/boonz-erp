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
