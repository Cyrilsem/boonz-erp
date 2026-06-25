/goal FINALIZE PROD-SYNC PRD-058 + PRD-059 (post-merge close-out). PR #5 (prod-sync: PRD-058 + PRD-059) has been MERGED to origin/main via the GitHub UI. This goal does the LOCAL close-out only. NO DB writes (all 6 migrations already live on prod). NO force-push.

PRECONDITION: confirm PR #5 is merged — git fetch origin && git log origin/main --oneline | grep -E "0bf597d|13f69c0|058|059" (or check the merge commit). If NOT merged yet, STOP and tell me (the merge is a GitHub UI click, not something to automate).

STEPS:

1. git fetch origin; git checkout main; git pull --ff-only origin main. Verify the 12 prod-sync files are on main: the prd058_tunable_priority_weights migration + the 5 prd059_ws\* migrations, FE refill/page.tsx, 3 registries, 2 PRD docs. Print git show --stat of the merge.
2. Verify prod parity (read-only): the migrations are already applied on prod (BOONZ SUPA) — do NOT re-apply. Just confirm MIGRATIONS_REGISTRY on main lists all 6 with their applied status. Do not call apply_migration.
3. Prod-deploy record: once Vercel finishes the prod deploy of main, add the deploy-record line following the repo's existing pattern (.github/workflows/record-prod-deploy.yml / "chore(deploy): record production <sha> [skip ci]"). If the workflow auto-records, just confirm it ran; do not hand-fake a sha.
4. Update doc status → "merged to main via PR #5; prod-deployed": PRD-058-tunable-priority-weights.md, PRD-059-expiry-batch-hygiene.md, PROD-SYNC-PRD058-059-goal-command.md. Commit on main (or a tiny docs branch + PR if main is protected) — if main is protected and you cannot push directly, STOP and tell me.
5. Stash cleanup: the prod-sync parked CS drift via stash. CONFIRM WITH ME that feat/prd-052-convert-m2m is the authoritative home for the 70 drift files BEFORE dropping anything. Only after my yes: git stash list, then drop ONLY the redundant cs-drift-\* duplicates, keeping at least one backup until I confirm feat/prd-052 has them committed. Never drop a stash that isn't a confirmed duplicate.
6. Leave feat/prd-058-059-prod-sync branch in place (don't delete) until I confirm; it can be deleted post-merge on GitHub later.

HARD SAFETY: NO DB writes / NO apply_migration (prod already synced). NO force-push, NO history rewrite on main. Do NOT delete branches or drop stashes without my explicit confirmation (step 5/6). If main is branch-protected and direct push is blocked, STOP and report rather than working around it. swaps_enabled stays false.

AFTER: remind me the PRD-059 drawer FE is now live on prod → run the 375px/axe QA on the prod (or preview) URL.
