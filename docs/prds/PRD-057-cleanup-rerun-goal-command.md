/goal PRD-057 cleanup re-run: de-drift the build environment to its clean baseline. MODE SUPERVISED (show a dry read, wait for my go-ahead before any write). Repo/devops only. No app, no RPC, no engine. No em dashes.

CONTEXT (scan 2026-07-01, HEAD feat/prd-065-field-reconciliation): local main ~210 behind origin/main, 0 ahead (ff-syncable). A stale .git/index.lock (size 0) from a concurrent editor is likely present. 3 branches merged to origin/main are deletable: docs/prod-sync-prd058-059-closeout, feat/prd-058-059-prod-sync, feat/prd-063-picker-urgency. NO loss risk: both local-only branches (prd-063, prd-065) are already ancestors of origin/main. Leave untouched: supabase/migrations/_HELD_prd070_m2m_approve_to_destination.sql (intentionally held) and the ~78 uncommitted files on prd-065 (live WIP). The Build Orchestrator monitor now lives in the BOONZ BRAIN parent (branch-independent) and a 7:10am scheduled check regenerates it, so NO in-repo monitor action is needed.

PRE: confirm I am OUT of the FE and that no other session (Cursor / Claude Code) is mid-commit. Confirm no rebase/merge in progress.

RUN (in order, STOP between groups):

1. DRY READ: report git status without changing anything. Print: main behind/ahead vs origin/main; the exact merged-to-origin branches that are deletable (exclude the current branch); whether .git/index.lock exists and its age/size; confirm prd-063 and prd-065 are ancestors of origin/main (no loss risk); count uncommitted files. STOP for my go-ahead.

2. CLEAR STALE LOCK once I confirm no session is active: if boonz-erp/.git/index.lock exists, is size 0, and no git process is running, remove it. If anything suggests a live session, STOP and tell me.

3. FF-SYNC main: git fetch origin. Then bring local main to origin/main WITHOUT switching off prd-065: run `git fetch origin main:main` (fast-forward the ref while HEAD stays on prd-065). If it reports non-fast-forward, STOP and show me (do not force).

4. DELETE merged branches: for each of docs/prod-sync-prd058-059-closeout, feat/prd-058-059-prod-sync, feat/prd-063-picker-urgency (skip the current branch), run `git branch -d`. If -d refuses one that IS an ancestor of origin/main (squash-merged, stale upstream), unset its upstream (`git branch --unset-upstream <b>`) and retry `git branch -d`. NEVER `git branch -D`, never delete a branch that is not an ancestor of origin/main.

5. VERIFY + report: `git rev-list --left-right --count origin/main...main` = 0 0; the 3 branches gone; _HELD_ migration still present and uncommitted; the ~78 WIP files still present and uncommitted. Confirm nothing was pushed and no remote branch was touched.

DO NOT: push anything; delete any remote branch; force-delete; commit, stage, or stash the ~78 WIP files; commit or apply the _HELD_ migration; touch any engine/RPC/migration; run --apply-style destructive steps before the DRY READ is approved. STOP per group and on any error or lock ambiguity.
