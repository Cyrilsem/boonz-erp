---
id: PRD-012-refill-pipeline
program: PROGRAM-2026-05-25
title: Rescue — re-apply record_variant_correction RPC migration
status: Done
severity: P1
reported: 2026-05-25
shipped_at: 2026-05-26
source: PROGRAM-2026-05-25 V4 verification (semantic name PRD-005-refill-pipeline-rescue)
routing: [Cody (re-validated against current pg_proc), CS (approved + applied)]
done_summary: |
  Resolved a name collision with the existing Jaccard-clustering
  `public.product_families` table (102 rows, in use by
  v_product_lifecycle_global_enriched). New migration
  `phaseF_prd012_rescue_curated_product_families` introduces a new
  `curated_product_families` table for the manually-curated variant lookup,
  repoints `variant_action_log.product_family_id` FK from the Jaccard table
  to the curated one (safe: variant_action_log was empty), adds
  `boonz_products.product_family_id` FK, recreates
  `v_product_family_members` view, and ships the
  `record_variant_correction(uuid,uuid,uuid,numeric,text,text,text)` RPC
  that PRD-002 originally promised. Original 20260521233552_prd002_006_product_families.sql
  and 20260522095532_prd002_record_variant_correction_rpc.sql are now
  historical artifacts (never applied; superseded by this migration).
verification:
  curated_product_families_table: present
  boonz_products_product_family_id: present
  record_variant_correction_rpc: present (SECURITY DEFINER)
  variant_action_log_fk_repoint: confirmed (now references curated_product_families)
followup:
  - Backfill curated_product_families (Hunter Ridges, YoPro, Be Kind Cluster, Perrier, McVities Mini families) — CS-curated.
  - FE: returns split UI reads v_product_family_members + calls record_variant_correction.
  - WH-side adjust_warehouse_stock when a return crosses a different batch (deferred).
---

## Problem

PRD-002 was marked `status: Done` on 2026-05-22 with a done_summary claiming
three migrations had shipped. Verification against pg_proc on 2026-05-25
shows the canonical writer RPC `record_variant_correction` does NOT exist.
The on-disk migration file
`supabase/migrations/20260522095532_prd002_record_variant_correction_rpc.sql`
is complete and Cody-reviewed at draft time, but was never applied to prod.

Drivers still cannot correct same-family variant returns inline — the
21-May OMDCW Hunter Truffle/Sea Salt incident remains unresolved.

## Verification (live 2026-05-25)

```sql
-- pg_proc check
SELECT proname FROM pg_proc
WHERE pronamespace='public'::regnamespace
  AND proname='record_variant_correction';
-- Returns: 0 rows.

-- Migrations registry check
SELECT version, name FROM supabase_migrations.schema_migrations
WHERE version='20260522095532' OR name ILIKE '%record_variant%';
-- Returns: 0 rows.

-- Supporting infra check (both shipped):
SELECT version, name FROM supabase_migrations.schema_migrations
WHERE name IN ('prd002_006_variant_action_log','prd002_006_product_families');
-- Returns: 2 rows, both present.
```

## Action

Re-apply the on-disk migration file via the Supabase MCP `apply_migration`
tool with migration name `prd002_record_variant_correction_rpc`. Body is the
full contents of `20260522095532_prd002_record_variant_correction_rpc.sql`.

Pre-apply Cody re-validation (mandatory):

1. The RPC writes to `pod_inventory.current_stock` and `status`. Per Article
   6 / Amendment 002, `warehouse_inventory.status` is manager-only; for
   `pod_inventory.status` confirm the same propose-then-confirm rule does
   NOT apply (Article 6 names warehouse_inventory specifically).
2. The reduction of `pod_inventory.current_stock` is a "fix the data"
   activity (correcting a wrong-variant record), permitted by the hard rule
   "DO NOT reduce stock unless fixing data or adding data" in the parent
   program.
3. Confirm the RPC sets `app.via_rpc` and `app.rpc_name` (yes — lines 57-58
   of the file).
4. Confirm role gate is present (yes — lines 62-67).
5. Confirm append-only audit shape is correct against current
   `variant_action_log` schema (`action_type / refill_dispatching_id /
machine_id / planned_variant_id / new_variant_id / product_family_id /
qty / reason_code / free_text / created_by`).

## Post-apply verification

- `SELECT proname FROM pg_proc WHERE proname='record_variant_correction';`
  must return 1 row.
- Smoke (read-only check that the RPC signature matches what the FE
  expects):
  `pg_get_function_identity_arguments('public.record_variant_correction(uuid,uuid,uuid,numeric,text,text,text)'::regprocedure);`
- Update PRD-002 frontmatter back to `status: Done` with a corrected
  `done_summary` once verified.
- Update [[MEMORY.md]] entry for PRD-002.

## Why this was not auto-applied tonight

The hard rule in PROGRAM-2026-05-25 requires Cody approval on every
migration. The migration file is Cody-reviewed at draft time, but the
intervening 3 days of schema changes (Phase G P1-P4, PRD-011, PRD-012
pod_inventory archival) may have changed the surrounding contract. A fresh
Cody pass is mandatory before re-apply. Spec'd, ready, queued for daylight
review.

## Out of scope

- The driver-FE variant correction dialog. Original PRD-002 footer notes
  "FE deferred". Surface remains: a button on the returns drawer that opens
  a same-family variant picker calling this RPC. Tracked as PRD-013
  follow-up.
