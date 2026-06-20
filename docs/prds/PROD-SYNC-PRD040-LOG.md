# Prod-Sync Log — PRD-040 Closeout (2026-06-20)

Git + docs sync so `main` (production) matches Supabase `eizcexopcuoycuosittm`. **No database change**: git operations + read-only prod precheck only. `swaps_enabled` untouched (`false`).

## Commit

- **SHA:** `d9951d3728b6413348ad50a61210045eead49bb0`
- **Branch:** `main` (fast-forwarded `120f987` → `cd96377` from origin before commit; pushed `cd96377..d9951d3`).
- **Message:** `chore(prod-sync): PRD-040 closeout migrations + docs live in prod (036b/019c + b2/b3/b4 applied; swaps_enabled off; engine_add_pod v18; FE excluded)`
- **Push:** ✅ `origin/main` updated; local == origin == `d9951d3`. **Repo == prod.**

## Precheck (prod truth, read-only)

`supabase_migrations.schema_migrations` confirmed all 6 in-scope migrations present in prod before commit.

## Migrations committed (6, all live in prod)

- `20260616130000_prd019c_compact_product_fallback_is_configured.sql`
- `20260618130000_prd036_b_log_manual_refill_new_purchase.sql`
- `20260620140000_prd040_b2_family_taxonomy_rule2_narrow.sql`
- `20260620150000_prd040_b3_product_landed_cost.sql`
- `20260620160000_prd040_b4_stitch_wh_pickable_unify.sql`
- `20260620170000_prd040_b3p2_engine_landed_cost_margin.sql`

## Docs committed (10)

PRD-040 docs: refill-closeout, goal-command, EXECUTION-LOG, TRACK-B-DESIGN, TRACK-C-FE-SPECS, TRACK-C-goal-command, TRACK-D-goal-command, PHASE3-ENABLE-RUNBOOK; plus PROD-SYNC-2026-06-20-goal-command, PROD-SYNC-PRD040-goal-command.

## Registries committed (3, append-only)

- `CHANGELOG.md` (+26/-0) — PRD-040 Track A (036b/019c), B2, B3+B4 entries.
- `RPC_REGISTRY.md` (+6/-0) — PRD-040 Track A closeout section.
- `METRICS_REGISTRY.md` (+1/-0) — candidate-basket-affinity canonical row.

Registry handling: origin/main (cd96377) was 100 commits ahead and held NONE of these. Only the PRD-040/036b/019c **additive** entries were re-applied onto cd96377's current registry files (purely additive, 0 deletions, 0 conflict markers); everything already on main preserved. `MIGRATIONS_REGISTRY.md` was not modified, so not staged.

## Deliberately EXCLUDED (not staged)

Per the directive: FE `src/**/*.tsx`, `*.xlsx`, `docs/prds/refill-pipeline/**`, `docs/prds/PRD-033-*`, `docs/prds/prd-034-product-performance-procurement/**`, any migration outside the 6. GATE verified: 0 forbidden paths staged, only the 6 migrations.

## Notes

- A stale 0-byte `.git/index.lock` was removed before git work (no git process running).
- The working tree held extensive **unrelated** uncommitted modifications from other sessions (src/**, SOPs, .claude/skills, architecture HTML, etc.). These were **stashed\*\* (`prd040-prodsync-preserve-other-work`, non-destructive) to allow the fast-forward; they remain recoverable via `git stash list` / `git stash apply` and were NOT committed.
- `refill_settings.swaps_enabled` stays `false`; `engine_add_pod` v18; `engine_swap_pod` v14_landed_cost_margin; `stitch_pod_to_boonz` v25_wh_pickable_unified (all live in prod, now in repo).
