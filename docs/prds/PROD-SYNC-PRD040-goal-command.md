# Claude Code /goal — Prod-sync #2: commit PRD-040 (+036b/019c) onto main

Paste into Claude Code in `boonz-erp`. Git + docs sync only; commits the now-applied PRD-040 migrations + docs onto `main` so repo == prod.

```
/goal Commit the already-applied PRD-040 (+ now-applied 036b/019c) migrations + docs to PRODUCTION (branch main) so repo matches prod. Supabase eizcexopcuoycuosittm. No em dashes. GIT + READS ONLY: no DB writes, no apply_migration, no function/migration runs. If .git/index.lock is a stale 0-byte file with no git process running, remove it first.

ADD (6 migrations under supabase/migrations/, ALL live in prod):
 20260616130000_prd019c_compact_product_fallback_is_configured.sql
 20260618130000_prd036_b_log_manual_refill_new_purchase.sql
 20260620140000_prd040_b2_family_taxonomy_rule2_narrow.sql
 20260620150000_prd040_b3_product_landed_cost.sql
 20260620160000_prd040_b4_stitch_wh_pickable_unify.sql
 20260620170000_prd040_b3p2_engine_landed_cost_margin.sql
ADD docs: docs/prds/PRD-040-* (refill-closeout, goal-command, EXECUTION-LOG, TRACK-B-DESIGN, TRACK-C-FE-SPECS, PHASE3-ENABLE-RUNBOOK) + docs/prds/PROD-SYNC-PRD040-goal-command.md + docs/prds/PROD-SYNC-2026-06-20-goal-command.md (if untracked).
ADD registries (modified): docs/architecture/CHANGELOG.md RPC_REGISTRY.md METRICS_REGISTRY.md MIGRATIONS_REGISTRY.md (only if modified).

NEVER stage: any src/**/*.tsx; any *.xlsx; docs/prds/refill-pipeline/**; docs/prds/PRD-033-*; docs/prds/prd-034-product-performance-procurement/**; any migration NOT in the ADD list.

STEPS:
1. PRECHECK via supabase MCP: SELECT name FROM supabase_migrations.schema_migrations WHERE name = ANY('{prd019c_compact_product_fallback_is_configured,prd036_b_log_manual_refill_new_purchase,prd040_b2_family_taxonomy_rule2_narrow,prd040_b3_product_landed_cost,prd040_b4_stitch_wh_pickable_unify,prd040_b3p2_engine_landed_cost_margin}'). Assert all 6 present. If any missing, STOP and report (never commit a non-live migration).
2. Confirm on branch main: git fetch origin; git switch main; git pull --ff-only. (Working tree already holds these untracked + modified files.)
3. Stage the explicit ADD list only.
4. GATE: git diff --cached --name-only must contain NONE of: .tsx, .xlsx, refill-pipeline/, PRD-033-, prd-034-product-performance-procurement/, or any migration outside the 6. Unstage any stray; print the final staged list.
5. For the 3-4 registry docs: confirm the staged diff is only PRD-040/036b/019c additive content (append-only); keep everything already on main.
6. git commit -m "chore(prod-sync): PRD-040 closeout migrations + docs live in prod (036b/019c + b2/b3/b4 applied; swaps_enabled off; engine_add_pod v18; FE excluded)".
7. git push origin main.
8. Write + commit + push docs/prds/PROD-SYNC-PRD040-LOG.md: the 6 migrations committed, docs/registries committed, commit SHA, push result, note repo == prod.

HARD RULES: no DB writes / apply_migration / function changes; main is production; only the ADD list lands else abort and report; swaps_enabled stays false (informational, untouched).
```
