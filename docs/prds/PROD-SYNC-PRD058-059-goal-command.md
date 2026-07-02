/goal PROD-SYNC PRD-058 + PRD-059: get the two already-applied-to-prod commits onto origin/main via a clean PR. This is a CODE sync only — both migrations are ALREADY live on prod (BOONZ SUPA), so NOTHING is re-applied to the DB. CS go-ahead given to push.

VERIFIED git state (read in Cowork 2026-06-24): branch feat/prd-052-convert-m2m has exactly 2 commits not on origin/main: a36f20c (PRD-058 tunable priority weights) and 415a556 (PRD-059 expiry hygiene). Their parent 4996f56 (PRD-052) is ALREADY on origin/main. origin/main is 256 ahead of the old base. Working tree has ~70 uncommitted CS drift files — LEAVE THEM UNTOUCHED (do not commit, do not discard).

PLAN:

1. git stash push -u -m "cs-drift-2026-06-24" to park the 70 dirty files (so the branch switch is clean). Record the stash ref.
2. git fetch origin.
3. git checkout -b feat/prd-058-059-prod-sync origin/main.
4. git cherry-pick a36f20c 415a556 (in that order).
5. Conflicts will likely be ONLY in append-files drifted by the 256 commits: CHANGELOG.md, MIGRATIONS_REGISTRY.md, METRICS_REGISTRY.md. Resolve by KEEPING BOTH sides (union — our PRD-058/059 entries plus main's). No code/migration/FE conflict expected; if a .sql migration file or refill/page.tsx conflicts, STOP and show me the diff before resolving.
6. Sanity after cherry-pick: the only NEW migration files present vs origin/main must be exactly prd058_tunable_priority_weights + the 5 prd059_ws\* files; FE diff limited to refill/page.tsx. Print git diff --stat origin/main...HEAD for my review.
7. git push -u origin feat/prd-058-059-prod-sync. Open a PR titled "prod-sync: PRD-058 priority weights + PRD-059 expiry hygiene (both already live on prod)". Do NOT merge — leave for my review.
8. Restore the parked drift: git checkout feat/prd-052-convert-m2m && git stash pop (the 70 files return to where they were).

HARD SAFETY: code sync only — DO NOT run any migration, DO NOT call apply_migration, DO NOT touch the DB (prod already has all 6 migrations). swaps_enabled stays false. Do NOT merge the PR or push to main directly — push the feature branch + open PR, then STOP. Preserve the 70 drift files via stash/pop, never discard. If cherry-pick hits any conflict outside the 3 registry/changelog files, STOP and show me.

AFTER MERGE (separate, when I say go): Vercel auto-deploys; the PRD-059 FE drawer truth (orphan section + Exp Qty) only goes live then. Hold the 375px/axe QA for the preview/prod deploy.
