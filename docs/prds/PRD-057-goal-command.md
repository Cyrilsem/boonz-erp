/goal PRD-057: clean and de-drift the build environment, then keep it clean with a live monitor. MODE SUPERVISED (show the dry run, wait for my go-ahead before any --apply). Full spec: boonz-erp/docs/prds/PRD-057-build-environment-hygiene-and-drift-monitor.md. Repo/devops only. No app, no RPC, no engine. No em dashes.

TOOLING (inside the repo so a repo-scoped session can run it):

- boonz-erp/tools/boonz_git_cleanup.sh (auto-detects repo root)
- boonz-erp/tools/boonz_build_refresh.py (writes boonz-erp/BUILD_ORCHESTRATOR.html)
  Run from inside boonz-erp. Not in the BOONZ BRAIN parent (outside file-access = Operation not permitted).

CONTEXT (scan 2026-06-24): 5 applied-but-untracked migrations (prd049_c, prd053a, prd056_1/2/3). Local main ~68 behind origin/main, 0 ahead. 3 local-only branches, all already merged to origin/main (delete candidates, not push). 3 leftover worktrees (boonz-erp-prd047, -prd055, -track-c) pinning merged branches, dirs intact so plain prune is a no-op (use git worktree remove). ~75 dirty files on feat/prd-052.

DECISIONS (already baked into the script, do not re-ask): (1) push ONLY local-only branches with unmerged work; merged ones are deleted not pushed (so likely 0 to push). (2) remove the 3 leftover worktrees via --remove-worktrees (git refuses if dirty = safe), which frees their branches to delete. (3) dirty-tree split is its own gated group, never a blanket git add.

PRE: confirm I am OUT of the FE and not mid-commit elsewhere; no rebase/merge in progress; no index lock.

RUN (in order, STOP between groups):

1. DRY RUN: from boonz-erp run `./tools/boonz_git_cleanup.sh --remove-worktrees` (no --apply). Print the plan; summarise branches to push (expect 0), worktrees to remove (expect 3), merged branches to delete, main-behind count, untracked migrations, dirty count. STOP for my go-ahead.

2. APPLY once approved: `./tools/boonz_git_cleanup.sh --apply --remove-worktrees`. Does only: fetch, ff-only sync main, push unmerged local-only branches, git worktree remove leftovers, git branch -d merged branches, prune. No force-push, no remote-branch delete, no file edits, no commits. STOP and report post-state (expect main = origin/main, 0 local-only, 0 leftover worktrees, merged branches gone).

3. SOURCE-OF-TRUTH: stage+commit the 5 untracked migrations on their proper branch, message `chore(migrations): commit applied-but-untracked PRD-049/053/056 migrations (PRD-057 source-of-truth)`. Also commit boonz-erp/tools/\*. Do NOT change SQL or re-apply to prod. If any untracked migration does not match the live function body, FLAG it instead of committing. STOP before push.

4. DIRTY-TREE SPLIT: on feat/prd-052 group the ~75 files by concern (docs, .claude skills, src, supabase) and commit each group separately, or move files to the branch they belong to. Show me the grouping first. No blanket git add -A.

5. MONITOR: from boonz-erp run `python3 tools/boonz_build_refresh.py`. Confirm the drift banner is all-green and Active/Stale/Done counts look right. Dashboard: boonz-erp/BUILD_ORCHESTRATOR.html.

CLOSE: append the source-of-truth rule (a migration is not done until committed; weekly PROD-SYNC) to boonz-erp/docs/architecture/CHANGELOG.md and the SOP index. Mark PRD-057 APPLIED with clean counts and date.

HARD SAFETY: repo/devops only; swaps_enabled stays false; no force-push; no remote-branch deletion; no working-tree edits by the script; branch deletion is -d only; worktree removal is git worktree remove only (refuses dirty); never --apply before I have seen the dry run; never commit the mixed tree wholesale; do not re-apply migrations to prod; STOP per group and on any error.
