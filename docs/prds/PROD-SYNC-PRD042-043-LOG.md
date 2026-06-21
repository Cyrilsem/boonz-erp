# Prod-Sync Log — PRD-042 + PRD-043 (2026-06-21)

Git + docs sync so `main` (production) matches Supabase `eizcexopcuoycuosittm`. **No database change**: git operations + a read-only precheck only. `swaps_enabled` untouched (`false`); `engine_add_pod` untouched.

## Commit

- **SHA:** `08b117f8f463635d7ec317c1237be35c19cf845b`
- **Branch:** `main` (fast-forwarded `66e8964` → `873c159` from origin before commit; pushed `873c159..08b117f`).
- **Message:** `chore(prod-sync): PRD-042 slot-profile swap engine v15 + PRD-043 picker v11 VOX gate (live in prod; swaps_enabled off; engine_add_pod byte-identical; FE excluded)`
- **Push:** ✅ `origin/main` updated; local == origin == `08b117f`. **Repo == prod.**

## Precheck (prod truth, read-only)

`supabase_migrations.schema_migrations` confirmed all 4 in-scope migrations present in prod before commit:
`prd042_p0_slot_profile_pools`, `prd042_p1_engine_swap_pod_v15_slot_profile`, `prd043_p0_days_until_next_vox_day`, `prd043_p1_pick_machines_for_refill_v11`.

## Migrations committed (4, all live in prod)

- `20260620210000_prd042_p0_slot_profile_pools.sql`
- `20260620220000_prd042_p1_engine_swap_pod_v15_slot_profile.sql`
- `20260620230000_prd043_p0_days_until_next_vox_day.sql`
- `20260620240000_prd043_p1_pick_machines_for_refill_v11.sql`

## Docs committed (7)

PRD-042/043 docs: PRD-042-swap-slot-profile-pools, PRD-042-goal-command, PRD-042-EXECUTION-LOG, PRD-042-043-goal-command, PRD-043-vox-calendar-gate-picker, PRD-043-EXECUTION-LOG, PROD-SYNC-PRD042-043-goal-command. (This log committed in a follow-up.)

## Registries committed (3, append-only)

- `CHANGELOG.md` — PRD-043 + PRD-042 APPLIED entries (newest-first, above Track C). One Track C line was reflowed +2 spaces by the repo formatter; text byte-identical, no content lost.
- `RPC_REGISTRY.md` — PRD-042 (rebuild_slot_profile_pool, engine_swap_pod v15_slot_profile) + PRD-043 (days_until_next_vox_day, pick_machines_for_refill v11) sections.
- `MIGRATIONS_REGISTRY.md` — the 4 migration rows.
- `METRICS_REGISTRY.md` **not** staged: its working-tree change was a PRD-039 entry from another context, not PRD-042/043.

Registry handling: origin/main (`873c159`) already held the PRD-040 Track C entries. Only the PRD-042/043 **additive** entries were re-applied onto `873c159`'s current registry files (append-only; everything already on main preserved).

## Deliberately EXCLUDED (not staged)

Per the directive: FE `src/**/*.tsx`, `*.xlsx`, `docs/prds/refill-pipeline/**`, `docs/prds/PRD-033-*`, `docs/prds/prd-034-product-performance-procurement/**`, any migration outside the 4, `METRICS_REGISTRY.md`. GATE verified: 0 forbidden paths staged, only the 4 migrations.

## Notes

- A stale 0-byte `.git/index.lock` was removed before git work (no git process running).
- The working tree held extensive **unrelated** uncommitted modifications from other sessions. These were **stashed** (`prd042-043-prodsync-preserve-2026-06-21`, non-destructive, `git stash -u`) to allow the fast-forward; they remain recoverable via `git stash list` and were NOT committed. The 4 migrations + 7 docs were restored from a `/tmp` backup after the ff; registry entries re-applied by hand.
- `refill_settings.swaps_enabled` stays `false`; `engine_swap_pod` v15_slot_profile (Pass-3 a no-op until PRD-040 Track D); `pick_machines_for_refill` v11 (live pick now enforces the VOX Wed/Fri calendar); `engine_add_pod` byte-identical (md5 `244de950d278df3490ea20955d4448a9`).
