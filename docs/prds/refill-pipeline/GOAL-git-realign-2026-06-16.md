# /goal - realign local git to origin without losing work (<4000 chars). Paste into Claude Code in boonz-erp.

```
/goal Realign this repo to origin/main safely. origin/main is canonical (PRD-019 cf52c03, PRD-031 cherry-picks, PRD-020 c99f7e1, tracker). Local diverged. Do NOT lose unique work, do NOT force-push main, do NOT delete a branch that holds a unique commit. Print state and STOP if any precheck fails.

VERIFIED FACTS (re-confirm, do not assume):
- HEAD is on feat/prd-020-packing-partial @ ec20217 "Performance tab". That commit is on NO other ref (not origin/main, not local main). It is unique work to preserve.
- Local main's 5 PRD-031 commits (626a153..70cf846) are ALL cherry-equivalents already on origin/main: `git log --cherry-pick --right-only --oneline origin/main...main` returned EMPTY. So local main has no unique content.
- Untracked working-tree files include the whole PRD-019 set that is TRACKED on origin/main: supabase/migrations/20260616110411..110419, docs/architecture/RPC_EXECUTION_KIT.md, docs/prds/refill-pipeline/PRD-019-conductor-capacity-commit-visibility.md. These collide on reset and are redundant local copies.
- 37 modified TRACKED files are genuine WIP (tracker-client.tsx, several page.tsx, .claude/skills/*/SKILL.md, docs/architecture/*). Preserve these.

STEPS (stop on any failure, report, do not improvise a destructive workaround):
1. PRECHECK: `git fetch origin` (must succeed). Re-run the cherry-pick check above; if it is NOT empty, STOP and show the unique commits, do not reset.
2. PRESERVE the branch: `git push origin feat/prd-020-packing-partial`. Confirm ec20217 is now on origin. This is the safety net for the Performance-tab work.
3. STASH everything incl untracked so reset is clean: `git stash push -u -m "realign-wip-2026-06-16"`. Verify `git status` is clean after.
4. REALIGN main: `git checkout main && git reset --hard origin/main`. Confirm `git rev-parse main` == `git rev-parse origin/main`.
5. INTEGRITY CHECK on origin: confirm origin's commit_refill_plan_atomic is the CORRECTED version. `git grep -n "engine_finalize_pod" -- supabase/migrations/20260616110417_prd019_e_commit_refill_plan_atomic.sql` must return NOTHING (finalize removed). If it still calls engine_finalize_pod, STOP and flag: the bad version was pushed.
6. RECOVER WIP without re-creating the dupes: do NOT blind `stash pop`. Instead `git stash show -p stash@{0} > /tmp/realign-wip.patch`, then restore ONLY the genuine WIP (the 37 tracked-file edits) by applying that patch and discarding the redundant untracked paths (the 9 migrations + RPC_EXECUTION_KIT.md + PRD-019 doc, which are already tracked on origin). Prefer: `git checkout -b wip/realign-2026-06-16` then `git stash pop` there, resolve, and delete the now-duplicate untracked files. Keep main clean.
7. REPORT: branches and tips (main, origin/main, feat/prd-020-packing-partial, wip branch), confirmation that main==origin/main, that ec20217 is on origin, that no unique commit was dropped, and a list of WIP files restored vs duplicates discarded.

RULES: never `push --force` to main; never delete feat/prd-020-packing-partial until ec20217 is confirmed on origin; no commits to main in this task (realign only); if a stash pop conflicts, resolve on the wip branch, never on main. No em dashes in any commit/PR text.
```
