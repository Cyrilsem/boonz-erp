# Claude Code /goal — Prod-sync: commit PRD-042 + PRD-043 onto main

Paste into Claude Code in `boonz-erp`. Git + docs sync only; commits the now-applied PRD-042/043 migrations + docs onto `main` so repo == prod.

```
/goal Commit the already-applied PRD-042 + PRD-043 migrations + docs to PRODUCTION (branch main) so repo matches prod. Supabase eizcexopcuoycuosittm. No em dashes. GIT + READS ONLY: no DB writes, no apply_migration, no function/migration runs. If .git/index.lock is a stale 0-byte file with no git process running, remove it first.

ADD (4 migrations under supabase/migrations/, ALL live in prod):
 20260620210000_prd042_p0_slot_profile_pools.sql
 20260620220000_prd042_p1_engine_swap_pod_v15_slot_profile.sql
 20260620230000_prd043_p0_days_until_next_vox_day.sql
 20260620240000_prd043_p1_pick_machines_for_refill_v11.sql
ADD docs: docs/prds/PRD-042-swap-slot-profile-pools.md, PRD-042-goal-command.md, PRD-042-EXECUTION-LOG.md, PRD-042-043-goal-command.md, PRD-043-vox-calendar-gate-picker.md, PRD-043-EXECUTION-LOG.md, PROD-SYNC-PRD042-043-goal-command.md
ADD registries (only if modified): docs/architecture/CHANGELOG.md RPC_REGISTRY.md MIGRATIONS_REGISTRY.md METRICS_REGISTRY.md

NEVER stage: any src/**/*.tsx; any *.xlsx; docs/prds/refill-pipeline/**; docs/prds/PRD-033-*; docs/prds/prd-034-product-performance-procurement/**; any migration NOT in the ADD list; anything from other sessions' stashes.

STEPS:
1. PRECHECK via supabase MCP: SELECT name FROM supabase_migrations.schema_migrations WHERE name = ANY('{prd042_p0_slot_profile_pools,prd042_p1_engine_swap_pod_v15_slot_profile,prd043_p0_days_until_next_vox_day,prd043_p1_pick_machines_for_refill_v11}'). Assert all 4 present. If any missing, STOP and report (never commit a non-live migration).
2. git fetch origin; git switch main; git pull --ff-only. (Working tree already holds these untracked + modified files.)
3. Stage the explicit ADD list only.
4. GATE: git diff --cached --name-only must contain NONE of: .tsx, .xlsx, refill-pipeline/, PRD-033-, prd-034-product-performance-procurement/, or any migration outside the 4. Unstage strays; print the final staged list.
5. Registry docs: confirm staged diffs are only PRD-042/043 additive content (append-only); keep everything already on main.
6. git commit -m "chore(prod-sync): PRD-042 slot-profile swap engine v15 + PRD-043 picker v11 VOX gate (live in prod; swaps_enabled off; engine_add_pod byte-identical; FE excluded)".
7. git push origin main.
8. Write + commit + push docs/prds/PROD-SYNC-PRD042-043-LOG.md: the 4 migrations committed, docs/registries committed, commit SHA, push result, note repo == prod.

HARD RULES: no DB writes / apply_migration / function changes; main is production; only the ADD list lands else abort and report; swaps_enabled stays false (informational, untouched); engine_add_pod untouched.
```
