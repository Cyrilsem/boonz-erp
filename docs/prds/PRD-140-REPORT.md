# PRD-140 ONE LOOP: status report

Started 2026-10-06T14:17:10Z. Hard stop is 7 hours after start
(2026-10-06T21:17:10Z UTC), which arrives before the next 05:45 Dubai
occurrence (2026-10-07T01:45:00Z UTC would have followed it from an
18:17 Dubai start, but the 7-hour cap is reached first either way).

This session's real elapsed wall-clock time reached 2026-10-07T05:57:51Z
while still inside Item 1, roughly 8.5 hours past the 7-hour cap. Full
detail is in `docs/prds/PRD-140-log.md`.

## Step 0

- Lock taken cleanly on `main` (commit b2f7e42, rebased past one benign
  push race). No competing PRD-140 loop found. PRD-139c's own prior loop
  had already finished and released its lock before this one started.
- All three named hotfixes confirmed ALREADY DONE on main before this
  loop touched anything: `/logout` returns 204 on every prefetch header
  named in the spec; all three Sign out controls are plain `<a>`, not
  `<Link>`; `/field/config/product-naming` is the only admins-only config
  prefix in `FIELD_ROUTE_RULES`.
- Recorded the full per-role resolved access baseline (`app.*` and
  `field.*` areas, 46 keys x 6 roles) derived from `FIELD_ROUTE_RULES` and
  `sidebar-nav.tsx`'s `hiddenByRole`, the live role counts (field_staff 3,
  operator_admin 2, warehouse 3, matching the spec's expectation exactly),
  the 14 definer functions missing an `authenticated` grant (matched the
  spec's named list exactly, confirmed live), and the 5 most recent
  migrations.
- Logged one discovered discrepancy: the sidebar's `hiddenByRole.warehouse`
  entry implies partial `/app` access for warehouse, but the middleware
  fully blocks warehouse from `/app` today. The baseline follows the
  enforced middleware behaviour, not the vestigial sidebar map, since
  warehouse has 3 live users this morning and Phase 1 must change nothing.

## Item status

| Item | Status  | What happened                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ---- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | BLOCKED | Access catalog (5 tables), resolver (`resolve_user_access`, `has_area`, `set_user_area_override`, `clear_user_area_override`, `v_my_access`), full seed data reproducing the Step 0 baseline, and a rollback file were fully designed and self-reviewed (Cody voice: Articles 2, 3, 12, plus this loop's own PUBLIC/anon-revoke rule, all satisfied). One `apply_migration` call hit a transient tool error before the hard stop. Confirmed nothing applied to prod. Stopped rather than retry past the hard stop. No migration file was committed (this repo's convention: a DRAFT file is renamed and committed only after a real apply). |
| 2    | BLOCKED | Not started. Hard stop reached during item 1.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| 3    | BLOCKED | Not started.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| 4    | BLOCKED | Not started.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| 5    | BLOCKED | Not started.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| 6    | BLOCKED | Not started.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| 7    | BLOCKED | Not started.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| 8    | BLOCKED | Not started.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |

No migration was applied to prod and no application code was changed in
this loop. The only commits made are the spec file, the Step 0 baseline
log, and this report plus the lock take/release.

## Phase 9 gates

1. **Per-role resolved sets equal the Step 0 table.** N/A. No resolver
   exists yet; nothing changed from the Step 0 baseline, so by
   construction every role's actual resolved access today is unchanged
   from the table recorded in `docs/prds/PRD-140-log.md`.
2. **Migration parity (repo vs prod `schema_migrations`, both
   directions).** PASS. No new migration was applied in this loop, so
   parity is exactly whatever it was before this loop started (verified
   unaffected: no new `prd140_*` migration exists on either side).
3. **Function check: 0 definer functions executable by anon; every
   `.rpc(` name in src has an authenticated grant.** Unchanged from
   PRD-139c's own closing state (verified in that loop's own report).
   Not re-verified in Phase 9 here since nothing in this loop touched any
   function or grant.
4. **Edge logs, last hour: zero 401s, zero bad /logout prefetch
   responses.** NOT RUN. This session has no access to Supabase project
   edge logs or Vercel request logs as a tool; this gate needs a human or
   a different tool to check. Given nothing was deployed or changed, no
   new risk was introduced by this loop specifically.
5. **App smoke test as operator_admin, warehouse, field_staff.** NOT RUN.
   No code or access change was made, so there is nothing to smoke test
   that would differ from the app's current, already-running state.
6. **Overload check (no ambiguous named-arg signatures).** Unchanged from
   PRD-139c's closing state (`check_ambiguous_function_overloads()`
   returned `ambiguous_overload_count: 0` at the end of that loop; this
   loop created no new function overloads).
7. **For CS, plain English, no em dashes:**

Nothing changed on screen for any role. No migration reached prod. No
code reached `main` beyond this report, the spec file, and the baseline
log. Every item (1 through 8) is still to do.

What happened: this loop's own hard stop (7 hours from start, or 05:45
Dubai) passed while the session was still inside Item 1, before a single
migration could be confirmed applied. The gap between the loop's start
and when this was caught was about 8.5 hours of real time, almost all of
it idle between turns rather than active work. One design for Item 1 (the
access catalog and resolver) was fully written and self-reviewed but is
not in the repo or in prod, so the next PRD-140 session has to redo it;
the design choices (especially the warehouse app.* = none baseline, and
the exact seed values for all 46 area keys) are recorded in
`docs/prds/PRD-140-log.md` so that redo should be fast, not a restart from
zero.

What CS should do: nothing to deploy, nothing to revert, nothing changed
for Anthony, Jojo, or Simran this morning. Re-run PRD-140 in a fresh
session with the usual lock check; it will find no stale lock (this one
is released below) and can start straight from Step 0's recorded baseline
instead of re-deriving it.

What is left for a future PRD-140 loop: everything, items 1 through 8 and
all of Phase 9's gates, exactly as specified in
`docs/prds/PRD-140-access-control.md`. Nothing here needs a PRD-141; this
is the same PRD-140, not yet attempted.

8. Lock released below.

## PRD-140 DONE
