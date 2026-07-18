# Batch 0 closeout — RC-15 repo/prod parity + RC-06 swap-engine revival
**Applied to prod: 2026-07-18 ~03:40 UTC · Cody-approved (conditional) · CS green-lit**
Part of the gated remediation program from the 2026-07-16 forensic audit (see `Boonz_Forensic_Remediation_Plan.html` in BOONZ BRAIN).

## What shipped

### RC-15 — repo/prod parity
- **16 backported migration files** (wave1 ×3, wave2 ×2, monitors ×2, gate_pass3, fixA/fixD/fixCE/fixD2, audit_product_mapping_writes, f1/f2 PRD-100, phasef_machine_warehouse_canonical_writer). Byte-identical payload to `supabase_migrations.schema_migrations.statements` + a 2-line provenance header. **Git-only — never re-apply** (versions already in the prod ledger; `db push` treats them as applied).
- **`20260718033821_rc15_parity_backport_live_functiondefs.sql`** — 7 live-only function defs (adjust_pod_inventory, apply_inventory_correction, confirm_stitched_plan, edit_dispatch_qty, edit_dispatch_product, repack_machine, reset_approved_undispatched) captured byte-faithful and applied to prod as a **proven no-op** (all 7 md5s + owner + ACL + proconfig unchanged post-apply).
- **`scripts/check_prod_repo_drift.py`** — CI drift check hashing live `pg_get_functiondef` vs repo (offline `--from-json` mode included; `PATCHED_EXPECTED` updates must cite a migration).

### RC-06 — swap engine revived
- **`20260718034118_rc06_engine_swap_pod_version_agnostic_tags.sql`** — exactly 2 clauses changed in `engine_swap_pod`: `reasoning->>'tagged_by' IN ('engine_add_pod_v15','engine_add_pod_v16')` → `LIKE 'engine_add_pod%'` (opening DELETE preserve-clause + dead-resolution loop). The