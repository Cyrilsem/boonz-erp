# Prod-Sync Log — 2026-06-20

Git + docs sync so `main` (production) matches what is already live in Supabase `eizcexopcuoycuosittm`. **No database change**: nothing applied, no migration run, no function altered. Git operations + read-only prod checks only.

## Commit

- **SHA:** `18bd34d95c5b9175497ab83c3a3678e51d862b71`
- **Branch:** `main` (fast-forwarded from `00f2142` before commit; pushed `00f2142..18bd34d`).
- **Message:** `chore(prod-sync): prod-applied migrations + docs for PRD-034/035/036/037/039 (live in prod; swaps_enabled off; FE + unapplied 036b/019c excluded)`
- **Push:** ✅ `origin/main` updated.

## Precheck (prod truth, read-only)

Queried `supabase_migrations.schema_migrations`. All 13 in-scope migrations present in prod; the 2 excluded migrations absent.

## Migrations committed (13, all live in prod)

- `20260618090000_prd034_a_vox_return_log.sql`
- `20260618090100_prd034_b_receive_dispatch_line_vox_guard.sql`
- `20260618093000_prd035_a_stitch_wh_aware_variant_fallback.sql`
- `20260618094000_prd035_c_refill_session_readiness.sql`
- `20260618095000_prd035_b_engine_relative_score_band.sql`
- `20260618096000_prd035_d_picker_vox_calendar_saturday.sql`
- `20260618097000_prd035_e_engine_score_driven_swap.sql`
- `20260618120000_prd036_a_v_dispatch_pickable.sql`
- `20260619140000_prd037_p0_coexistence_rules_brand_owner.sql`
- `20260619140100_prd037_p1_engine_swap_pod_v12.sql`
- `20260620120000_prd039_p0_product_slot_capacity.sql`
- `20260620120100_prd039_p0_get_candidate_affinity.sql`
- `20260620130000_prd039_p1_engine_swap_pod_v13.sql`

## Docs committed (18)

PRD docs `docs/prds/PRD-034-*`, `PRD-035-*`, `PRD-036-*`, `PRD-037-*`, `PRD-039-*` (execution logs, goal-command snapshots, APPLY runbooks, spec docs).

## Registries committed (3, append-only)

- `docs/architecture/CHANGELOG.md` — added PRD-039 (P1 + P0) and PRD-037 entries (PRD-034/035/036 have no CHANGELOG entries).
- `docs/architecture/RPC_REGISTRY.md` — added `get_refill_session_readiness` (PRD-035 WS-D), the PRD-037 swap-engine section, and the PRD-039 P0/P1 sections.
- `docs/architecture/METRICS_REGISTRY.md` — PRD-035 WS-A redefinition row + PRD-036 `v_dispatch_pickable` row + PRD-035 stitch-WH TODO note.

Registry handling: `main` carried NONE of PRD-033..039 entries. Only the PRD-034..039 additive entries were re-applied onto `main`'s current files (3-way for METRICS/RPC which applied cleanly; CHANGELOG resolved by hand because the feat-only anchor `PRD-023j` is absent on `main`). Everything already on `main` preserved. **PRD-033 and PRD-023i/j registry entries were deliberately NOT brought to main** (out of scope; PRD-033 lives on its own branch).

## Deliberately EXCLUDED (not committed)

- `20260618130000_prd036_b_log_manual_refill_new_purchase.sql` — **NOT applied to prod** (absent from `schema_migrations`). Committing it would put a dormant migration in the repo ahead of prod.
- `20260616130000_prd019c_compact_product_fallback_is_configured.sql` — **NOT applied to prod** (absent). Same reason.
- FE `src/**/*.tsx` working-tree edits, `*.xlsx`, `docs/prds/refill-pipeline/**`, `docs/prds/PRD-033-*`, `docs/prds/prd-034-product-performance-procurement/**` — out of scope per the sync directive. (FE + PRD-033 + other branch-local work remain on `feat/prd-033-operator-flexibility` / stash, untouched.)

## Notes

- `refill_settings.swaps_enabled` stays `false` (informational; this sync did not touch the database).
- Branch `feat/prd-033-operator-flexibility` working-tree modifications (3 registries + 4 FE files) were stashed (`prodsync-feat-wt-2026-06-20`) to switch cleanly; they remain in stash for that branch.
- A stale `.git/index.lock` (0 bytes) was removed before the git work (no git process running).
