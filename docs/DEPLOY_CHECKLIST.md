# Deploy Checklist — the 3 layers

"Committed" is not "live". This repo ships across **three independent layers**, and a change
is only truly done when all three agree. Drift happens when one layer moves and the others
do not (code merged but migration unrecorded, or DB object live but FE still old).

Run the one-screen status check any time:

```bash
bash scripts/deploy-status.sh
```

Every goal that touches code, the database, or the FE ends by ticking all three boxes below.

## Layer 1 — Git (code)

- [ ] Work is merged to `origin/main` (not just committed on a feature branch).
- [ ] `main == origin/main` locally (`git rev-parse main origin/main` match).
- [ ] No feature branch silently carries unique commits. Check every branch:
      `git log --cherry-pick --right-only --oneline origin/main...<branch>`.
      EMPTY = redundant (safe to delete). NON-EMPTY = unique work, open a PR, never force-delete.

## Layer 2 — Supabase (database)

- [ ] The migration is actually applied (object exists live), verified by querying
      `pg_proc` / `pg_class`, not by the presence of a `.sql` file in the repo.
- [ ] The migration ledger is aligned: `supabase migration list` shows Local and Remote
      matched for every version (no Local-only, no Remote-only rows).
- [ ] **Ledger version == repo filename version.** When a migration is applied through the
      Supabase MCP `apply_migration` (no local CLI), the ledger row is stamped with the
      _apply time_, not the repo filename timestamp. That row must be realigned to the
      filename version, otherwise `migration list` reports false drift forever.
- [ ] Ledger repair MARKS applied only. It never re-runs DDL and never touches business data.
      Do not `supabase db push` to "fix" a recorded-but-misversioned migration — it will try
      to recreate live objects.

## Layer 3 — Vercel (frontend)

- [ ] Production SHA is auto-recorded by `record-prod-deploy.yml`. Confirm
      [docs/DEPLOYMENTS.md](DEPLOYMENTS.md) (or the commit status `live/production` on that SHA)
      shows the merged SHA. Visual smoke of the two routes still requires a logged-in browser.

## Why this exists

Backend (DB) and FE (Vercel) are separate ships from the git commit. PRD-019 drifted exactly
this way: the 9 migrations were live in the DB and the FE was merged to `main`, but the
migration ledger had the rows under apply-time versions instead of the repo filenames, so
`migration list` looked like 9 unapplied migrations. The fix was a ledger version realign
(no DDL). Run `scripts/deploy-status.sh` first and last on any deploy-touching goal so this
never goes unnoticed again.
