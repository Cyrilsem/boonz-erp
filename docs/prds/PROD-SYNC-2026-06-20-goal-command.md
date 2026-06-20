# Claude Code /goal — Prod-sync commit (PRD-034/035/036/037/039) onto main

Paste into Claude Code in `boonz-erp`. Git + docs sync only; lands prod-applied migrations + docs on `main`.

```
/goal Commit already-applied PRD-034/035/036/037/039 migrations + docs to PRODUCTION (branch main) so repo matches prod. Supabase eizcexopcuoycuosittm. No em dashes. GIT + READS ONLY: no DB writes, no apply_migration, no function/migration runs.

ADD (13 migrations, all under supabase/migrations/, all live in prod):
 20260618090000_prd034_a_vox_return_log.sql
 20260618090100_prd034_b_receive_dispatch_line_vox_guard.sql
 20260618093000_prd035_a_stitch_wh_aware_variant_fallback.sql
 20260618094000_prd035_c_refill_session_readiness.sql
 20260618095000_prd035_b_engine_relative_score_band.sql
 20260618096000_prd035_d_picker_vox_calendar_saturday.sql
 20260618097000_prd035_e_engine_score_driven_swap.sql
 20260618120000_prd036_a_v_dispatch_pickable.sql
 20260619140000_prd037_p0_coexistence_rules_brand_owner.sql
 20260619140100_prd037_p1_engine_swap_pod_v12.sql
 20260620120000_prd039_p0_product_slot_capacity.sql
 20260620120100_prd039_p0_get_candidate_affinity.sql
 20260620130000_prd039_p1_engine_swap_pod_v13.sql
ADD docs: docs/prds/PRD-034-* PRD-035-* PRD-036-* PRD-037-* PRD-039-*
ADD registries: docs/architecture/CHANGELOG.md RPC_REGISTRY.md METRICS_REGISTRY.md

NEVER stage: supabase/migrations/20260618130000_prd036_b_log_manual_refill_new_purchase.sql and 20260616130000_prd019c_compact_product_fallback_is_configured.sql (both NOT applied); any src/**/*.tsx; any *.xlsx; docs/prds/refill-pipeline/**; docs/prds/PRD-033-*; docs/prds/prd-034-product-performance-procurement/**.

STEPS:
1. PRECHECK via supabase MCP: SELECT name FROM supabase_migrations.schema_migrations WHERE name = ANY of the 13 names above. Assert all 13 present AND prd036_b + prd019c ABSENT. If a listed migration is missing, STOP and report (never commit a non-live migration).
2. git fetch origin; git switch main; git pull --ff-only. The 13 migrations + PRD docs are untracked and carry to main cleanly. The 3 registry docs are tracked-modified vs feat/prd-033: if they diverge from main, do NOT force-carry feat/prd-033 copies; re-apply only the PRD-034..039 additive entries onto main's current files (append-only; keep everything already on main).
3. Stage the explicit ADD list only.
4. GATE: git diff --cached --name-only must contain NONE of: prd036_b, prd019c, .tsx, .xlsx, refill-pipeline/, PRD-033-, prd-034-product-performance-procurement/. Unstage any that appear. Print the final staged list.
5. git commit -m "chore(prod-sync): prod-applied migrations + docs for PRD-034/035/036/037/039 (live in prod; swaps_enabled off; FE + unapplied 036b/019c excluded)"
6. git push origin main.
7. Write + commit + push docs/prds/PROD-SYNC-2026-06-20-LOG.md: the 13 committed, docs/registries committed, the 2 excluded migrations + why, commit SHA, push result.

HARD RULES: no DB writes / apply_migration / function changes; main is production (do not leave on feat/prd-033); only the ADD list lands, else abort and report; swaps_enabled stays false (informational).
```
