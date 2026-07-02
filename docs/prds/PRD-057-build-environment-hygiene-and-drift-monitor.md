# PRD-057: Build-environment hygiene + drift monitor (git source-of-truth, branch/worktree cleanup, live orchestrator)

Owner: CS
Date: 2026-06-24
Surface: Repo / devops only (git branches, worktrees, working tree, migration tracking) plus a local monitoring tool (BOONZ Build Orchestrator). No application code, no Supabase RPC, no engine change. `swaps_enabled` untouched. Forward-only. No em dashes.
Governance: Read-only on the engines and backend. The only writes are git operations and committing already-applied migration FILES into version control. Cody review is light (no protected entity is modified); the relevant principle is Article 12/16 spirit: the canonical record of backend state must live in git, not only in the live database and chat memory.

## Why (verified 2026-06-24 by a full repo scan)

PRD throughput (PRD-023 to PRD-056, about 33 initiatives in 13 days) outran the tracking surface. The scan found:

1. SOURCE-OF-TRUTH DRIFT (headline). 305 migration files on disk, 301 tracked by git; 5 already-applied migrations are untracked (`prd049_c`, `prd053a`, `prd056_1/2/3`). Multiple execution logs record work "APPLIED to prod via Supabase MCP only, NOT git-committed" (048, 042/043, 040, 037). The production database is therefore ahead of, and partly divergent from, git. Git cannot currently rebuild prod. This is the only finding that is a real risk rather than housekeeping.
2. STALE LOCAL TRUNK. Local `main` is 40 commits behind `origin/main`, 0 ahead. Because branch comparisons run against this stale ref, work that is already merged on origin shows up as "unmerged", which is most of the "what is still pending" confusion.
3. LOCAL-ONLY BRANCHES (loss risk). A handful of branches exist nowhere but this machine (live count via the script; at scan time: `feat/prd-051`, `feat/prd-052`, `feat/prd-054`). If the disk fails they are gone.
4. WORKTREE SPRAWL. 5 worktrees, 3 prunable (`boonz-erp-prd047`, `boonz-erp-prd055`, `boonz-erp-track-c`), each still pinning a branch.
5. DIRTY TREE. 69 uncommitted files on the prd-052 branch, mixed across docs (44), src (12), supabase (5), skills (4). A feature branch carrying source + migrations + unrelated doc/skill edits is how edits get lost or land on the wrong branch.

## Objective (plain English)

1. ONE SAFE COMMAND TO CLEAN. A dry-run-first script that fetches, fast-forwards local main, pushes every local-only branch, deletes only branches already merged to origin/main, prunes moved worktrees, and reports (never auto-commits) untracked migrations and the dirty tree. Nothing destructive without an explicit `--apply`, and even then only non-destructive git operations.
2. GIT BECOMES SOURCE OF TRUTH FOR BACKEND. A standing rule: a migration is not "done" until its file is committed to git. A weekly PROD-SYNC closes any gap between applied-in-prod and committed-in-git. The drift monitor makes any gap visible immediately.
3. A LIVE MONITORING TOOL. The BOONZ Build Orchestrator gains a drift/health banner (main behind origin, untracked migrations, local-only branches, dirty tree) and an Active vs Stale vs Done view so what is genuinely in-flight is separated from what is finished or abandoned. It refreshes on demand from the real repo.

## Phase A. Safe cleanup script (`boonz-erp/tools/boonz_git_cleanup.sh`)

Lives INSIDE the repo at `boonz-erp/tools/` (not the BOONZ BRAIN parent), so a repo-scoped agent can execute it; the repo root is auto-detected from the script location via git toplevel. Default is DRY RUN: prints the exact plan, changes nothing. `--apply` executes only these, each echoed:

1. `git fetch --prune origin`.
2. Fast-forward local `main` to `origin/main` (ff-only; if local main is ahead, it is skipped and flagged for manual review).
3. Push only local-only branches that carry UNMERGED work. A local-only branch already merged into `origin/main` is redundant to push and is deleted in step 5 instead.
4. `--remove-worktrees` (opt-in): `git worktree remove` the leftover worktrees holding already-merged branches. git refuses if a worktree is dirty, so this is safe; it frees those branches for deletion. Without the flag, worktree removal is skipped and only reported.
5. Delete LOCAL branches already merged into `origin/main` via `git branch -d` (git refuses anything not fully merged; the currently checked-out branch is skipped; failures are tolerated, never abort).
6. `git worktree prune` for any worktree whose directory is already gone.
7. REPORT only: untracked migration files and dirty-tree count. The script never commits and never touches the working tree.

It never force-pushes, never deletes a remote branch, never edits files. Acceptance: a dry run prints a plan that matches the live repo; `--apply --remove-worktrees` leaves the repo with local main = origin/main, zero unmerged local-only branches, zero leftover worktrees, and merged local branches removed, with the working tree untouched.

## Phase B. Source-of-truth discipline

1. Commit the 5 untracked migration files (and any future applied migration) to git. Applied-but-uncommitted is treated as an open defect, surfaced by the monitor.
2. Standing rule recorded in `docs/architecture/CHANGELOG.md` and the team SOP: no migration is closed until committed; run `PROD-SYNC` weekly to reconcile prod-applied vs git-committed. This formalises the existing `PROD-SYNC-*` goal-commands into a cadence rather than an afterthought.
3. The dirty working tree on prd-052 is split: docs/skills committed separately from source/migrations so the feature branch carries only its own change.

## Phase C. Drift monitor (BOONZ Build Orchestrator upgrade)

The existing generator (`boonz_build_refresh.py`) gains:

1. A health banner at the top: local main N behind origin, X untracked migrations, Y local-only branches, Z uncommitted files, each green when zero and amber/red when not.
2. Activity classification for every initiative and branch: ACTIVE (open work touched within 10 days), STALE (open but untouched > 14 days, or a prunable worktree, i.e. needs a decision), DONE (shipped or merged and closed). Filter chips for each.
3. The dashboard stays a self-contained HTML refreshed by the script (or the double-click launcher). It reads the real local git, which a browser-only artefact cannot do, so the refresh model is script + dashboard by design.

Acceptance: opening the dashboard answers, without reading any file, "is my environment clean", "what is genuinely active right now", and "what is finished or abandoned".

## Tests / verification

- T1 DRY RUN on the live repo prints a plan whose branch/worktree/migration counts match an independent `git` inspection.
- T2 `--apply` on a throwaway clone performs steps 1 to 5 and leaves the working tree byte-identical (no file edits, no commits).
- T3 After apply: `git rev-list --count main..origin/main` = 0; no branch absent from origin; `git worktree list` shows no prunable entry; merged branches gone.
- T4 The monitor banner shows the post-cleanup state (all green) after a refresh.
- STOP and report on any failure; never run `--apply` against the real repo until the dry run has been reviewed.

## Close

Update `CHANGELOG.md` and the SOP with the source-of-truth rule and the weekly PROD-SYNC cadence. Set PRD-057 APPLIED with the cleanup date and the resulting clean counts.

### STATUS: APPLIED — 2026-06-25

Clean counts after the run (verified by `tools/boonz_build_refresh.py`):

- **0 dirty files** (was ~70 on `feat/prd-052`; split into concern-grouped commits: source-of-truth, skills, docs, CI, data, src)
- **0 untracked migrations** (committed `20260623120000_prd053a_*`; the other 4 of the original 5 already on main)
- **1 worktree** (main only; 3 leftover worktrees removed)
- **main = origin/main** (was 98 behind; ff-synced)
- merged local branches deleted with `-d` only (7 in APPLY + `feat/prd-047-1a-shelf-grouped` and `feat/prd-053-driver-add-flag`, the latter two via unset-stale-upstream so `-d` could verify against main; never `-D`)
- `BUILD_ORCHESTRATOR.html` gitignored (regenerated by the monitor, not tracked)

Source-of-truth rule + weekly PROD-SYNC cadence recorded in `docs/architecture/CHANGELOG.md` (2026-06-25 entry) and `docs/architecture/00_INDEX.md` (Standing operating rule section).

Not pushed: all commits are on `feat/prd-052-convert-m2m` (7 unpushed); CS reconciles/deploys. No prod writes were made.

## HARD SAFETY

Repo/devops only. No application, RPC, engine, picker or planogram change; `swaps_enabled` stays false. No force-push, no remote-branch deletion, no working-tree edits, no auto-commit of source. Branch deletion is `-d` only (merged-safe). The script is dry-run by default; `--apply` runs only the six safe steps above. Do not delete any branch that is not merged to origin/main. Do not commit the mixed working tree wholesale; split by concern. Review the dry run before applying.
