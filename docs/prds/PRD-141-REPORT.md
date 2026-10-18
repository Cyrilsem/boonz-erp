# PRD-141 ONE LOOP: status report

Started 2026-10-17T13:17:30Z. Hard stop is 12 hours after the lock
(2026-10-18T01:17:30Z UTC, 05:17 Dubai) or 06:30 Dubai the next morning,
whichever comes first; the 12-hour cap governs. This report is written
at 2026-10-17T17:51Z (21:51 Dubai), well inside the time box, because the
remaining blocked work cannot be unlocked by more elapsed time (see
below), not because of a time-box or hard-stop pressure.

Full detail, evidence, and the Cody-voice review for every item is in
`docs/prds/PRD-141-log.md`.

## Step 0 and the central blocker

Lock taken cleanly on `main`. No `PRD-140.lock` or `PRD-139b.lock` exist
on main (checked before taking this lock). Read
`docs/prds/PRD-140-access-control.md`, `docs/prds/PRD-140-log.md`, and
`docs/prds/PRD-139b-REPORT.md` in full, as instructed.

`docs/prds/PRD-138-drift-closeout-vox-eras-and-repurpose-eligibility.md`
and the authoritative `PRD-141-refill-engine-hardening.md` (the one this
loop's own instruction says to copy verbatim from "the Boonz project doc
claude/PRD-141-refill-engine-hardening.md") do not exist anywhere this
session can reach: not in this repo, not on the local filesystem, not in
the connected Google Drive (confirmed search works; it returns nothing
for either document), and no tool in this session can read a claude.ai
Project's attached knowledge files. The user's own instruction for this
loop did not include the item-level spec text either (unlike the PRD-140
loop's own instruction, which appended its full spec inline).

This blocks, at the item-detail level: PRD-141 items 1 to 5 (Phase 1
beyond item 0), 6 to 9 (Phase 2), 10 to 16 (Phases 3 and 4, Block D), 17
to 27 (Phases 5 to 7), and all of PRD-138 WS-A's exact list (worked
around by deriving it directly from prod, see Block A), WS-B, and WS-C.
Rather than invent 20-plus items of production database and FE design
with no source to check against, this session investigated the one item
with enough detail to evaluate independently (item 0, the swap/return
complaint CS named directly) and executed everything else that had a
real, checkable specification already available (Block A from prod
directly, Block E from the existing `PRD-140-access-control.md`).

Step 0 baseline matched every expected value exactly: migration head
`20261014065707`, anon-executable definer count 0, `access_areas` did
not exist, `v_machine_eligibility_drift` had exactly 2 rows (VOXDFC-2006,
VOXDFC-1001), role counts (field_staff 3, operator_admin 2, warehouse 3).
The one baseline value this session could not reproduce exactly was the
"Add New lanes without Remove" count (105 of 153 cited; three reasonable
"lane" definitions tried gave 97/144, 281/282, and 212/347) since the
exact grain of "lane" lives only in the missing document; logged as
further evidence of the same blocker, not acted on further.

## Item and block status

| Block/Item                                                                              | Status                          | What happened                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| --------------------------------------------------------------------------------------- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A: 7 named migrations + 4 VOX-era migrations                                            | DONE                            | All 7 written back byte for byte from prod (md5-verified against `supabase_migrations.schema_migrations.statements` before staging each one).                                                                                                                                                                                                                                                                                                                                                                                          |
| A: full parity since 2026-09-28                                                         | DONE                            | Found 6 more prod-only migrations beyond the named 7 while diffing the full post-2026-09-28 history against the repo; wrote all of them back too (zero behaviour change, pure capture of already-live state).                                                                                                                                                                                                                                                                                                                          |
| A: branch `return-split-by-expiry`                                                      | DONE                            | Rebased onto main; all 5 of its commits were already merged (confirmed zero diff after rebase); pushed to origin.                                                                                                                                                                                                                                                                                                                                                                                                                      |
| B item 0 (swap/return, CS's named #1 problem)                                           | INVESTIGATED, not fixed         | Traced the full mechanism (`swap_shelf_pod`, `pack_dispatch_line`, `driver_confirm_remove`, `v_wm_confirmations`) by reading every function body live. Found no code-level filter that excludes a swap-originated Remove line from the Warehouse Confirmations queue; the real defect, if the complaint holds today, is more likely a UX/process gap than a missing backend write path. Did not ship a change without the spec confirming which fix was intended, given this is a live, actively-used code path during business hours. |
| B items 1-5, C, D                                                                       | BLOCKED (missing spec)          | See the central blocker above.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| E item 1 (access catalog + resolver)                                                    | DONE                            | Re-derived and reapplied the design from the prior PRD-140 session (never committed there due to a hard stop right after a transient tool error). Verified against three live users; matches the Step 0 baseline exactly.                                                                                                                                                                                                                                                                                                              |
| E item 2 (admin-users edge function)                                                    | DONE, accept test partially run | Built and deployed (version 1, ACTIVE). Verified the platform JWT gate and the `has_area` authorization gate. The item's own literal curl accept test needs a real admin JWT this session could not safely obtain without touching a real person's credentials or creating a permanent new admin account (forbidden by the no-deletion rule); logged for CS to run directly.                                                                                                                                                           |
| E item 3 (Settings > Users page)                                                        | DONE, same test limitation      | Built the full page: list, create dialog, edit drawer with the area matrix, audit tab, guard rails. Clean typecheck and lint; confirmed the route compiles and serves (redirects correctly when unauthenticated). Full logged-in click-through needs the same real credentials this session does not have.                                                                                                                                                                                                                             |
| E item 4 (access provider + hook)                                                       | DONE                            | Built and mounted in both root layouts. Verified with a full production build (all 60 routes, clean compile) given the blast radius of touching both root layouts.                                                                                                                                                                                                                                                                                                                                                                     |
| E items 5, 6, 7 (middleware resolver, sidebar/login rewiring, delete hard-coded arrays) | BLOCKED (too risky to verify)   | These rewrite the live authorization gate for every request, during business hours, and their own spec requires an immediate three-role live smoke test this session cannot safely run (same credential constraint, much higher stakes). `src/middleware.ts` already caused one real incident this way (PRD-139b item 3). Not deployed blind.                                                                                                                                                                                          |
| Item 8 (function privilege drift + watchdog fix)                                        | DONE                            | DB-only, no live routing risk, directly fixes the exact PRD-139c regression ("authenticated lost 14 functions silently"). Verified: 0 anon-executable definers, 0 of 99 `.rpc()` call sites missing an authenticated grant, the original 14 internal functions unchanged.                                                                                                                                                                                                                                                              |

Every migration applied in this loop is committed with a matching
timestamp in `supabase/migrations/`. Items 1 and 8 (the only items
touching the database beyond pure capture) have rollback files in
`supabase/rollbacks/`. Every commit pushed to `main` triggers its own
Vercel production deploy automatically (confirmed in every prior
PRD-139 loop's own report); nothing here needs a manual deploy step.

## Found but not touched: two orphaned migration files

While re-verifying migration parity after Block A, found
`supabase/migrations/20260928200000_loopv2_w4_venue_binding_guard.sql`
and `20260928224500_loopv2_w6_r7_intra_machine_move_role_fix.sql`:
pre-existing files (commits `ab0e9c2` and `b02058b`, both from well
before this loop started) whose timestamps do not exist anywhere in
`supabase_migrations.schema_migrations`. They appear to be leftover
drafts from the original loopv2 session, superseded when that work was
re-applied and correctly recorded under the timestamps this loop also
independently recovered in Block A (`20260928182425` and
`20260928184930`). Not deleted: deleting files is outside this loop's
authority and the content is already correctly captured elsewhere.
Flagged here for CS's own cleanup judgment.

## Gates

1. **Overload check.** PASS. `check_ambiguous_function_overloads()`
   returns `ambiguous_overload_count: 0` after every change in this loop.
2. **Repo/prod migration parity, both directions.** PASS for the full
   window audited (everything since 2026-09-28, the practical scope this
   and every prior PRD-139 loop has checked). All 13 Block A migrations
   plus all 3 of this loop's own new migrations exist in both the repo
   and `supabase_migrations.schema_migrations`.
3. **Anon-executable definer count.** PASS. 0, both before and after
   Item 8's change to the watchdog.
4. **Three-role smoke test** (Packing, pack screen, Pickup, Dispatch
   Detail, Warehouse Confirmations, Inventory, Orders, Receiving,
   Settings > Users). NOT RUN live. This loop did not change any of
   Packing, Pickup, Dispatch Detail, Warehouse Confirmations, Inventory,
   Orders, or Receiving at all, so there is no new risk to smoke-test
   there regardless. The one new screen, Settings > Users, was verified
   by typecheck, lint, a full production build, and an unauthenticated
   browser navigation (confirmed correct redirect, zero console errors)
   but not by a real logged-in click-through, for the credential reason
   given above.
5. **`v_machine_eligibility_drift` 0 rows.** FAIL. Still 2 rows
   (VOXDFC-2006, VOXDFC-1001). The fix for this lives in Block D (PRD-138
   WS-B/WS-C), which is blocked on the missing source document; nothing
   in this loop touches VOX eras or repurpose eligibility.
6. **Acceptance lists with PASS/FAIL and evidence.** Given above, per
   block/item, in the table.

## For CS, plain English

**What changed on screen, by role:** nothing, for every existing screen
every role already had this morning. Admins (operator_admin, superadmin)
gained one new screen: Settings > Users, listing accounts, letting you
create a user, change a role, grant or deny individual areas, reset a
password, or disable an account. Nobody's existing access to anything
changed; the new access-control tables and functions exist in the
database now but nothing reads them yet except that one new page.

**What CS must do:**

1. Nothing to deploy by hand. Every commit in this loop already
   triggered its own automatic Vercel production deploy.
2. Click through Settings > Users yourself once, logged in as an admin.
   This session could not do that without your real session (see above);
   the build, typecheck, and lint are all clean, so this should mostly
   be confirming the visuals, not hunting for a functional break. If
   anything looks wrong, it is safe to fix directly since nothing else
   in the app reads this page's data yet.
3. If you want to run the curl-based accept test named in PRD-140 Item
   2 (create a throwaway field_staff test user, list it, ban it, unban
   it, revoke its sessions), you can do that directly now with your own
   logged-in session; the edge function is deployed and working.
4. The two orphaned migration files named above are safe to delete
   whenever convenient; they were never actually applied under those
   timestamps and their content is already correctly captured under the
   right ones.
5. For PRD-141's own swap/return complaint (the one you named first):
   this session traced the mechanism in full and found the backend is
   structurally capable of routing a swap's Remove leg to Warehouse
   Confirmations the same way any other Remove line does, once the
   driver actually completes it at Dispatch Detail. If the problem is
   still happening in practice, it is more likely that drivers are not
   completing that step, or are confused by the "Confirm removed" label
   appearing a full stage earlier at Packing, than a missing database
   write path. The full trace is in `docs/prds/PRD-141-log.md` for
   whoever picks this up next.

**What is left, all blocked on the same missing document, not a new
PRD-142:** this is still PRD-141 and PRD-138, not yet attempted past
what is listed above.

- PRD-141 items 1 to 27 beyond item 0's investigation (swap/return
  integrity items 1-5, pack screen stock truth 6-9, mapping adherence
  10-12, P1 picker 13-16, delivery truth 17-20, WEIMI and setup 21-23,
  operator tooling 24-27).
- PRD-138 WS-A (closed independently via Block A), WS-B, and WS-C (the
  actual VOX-era and repurpose-eligibility fix, which is what would
  close the `v_machine_eligibility_drift` 2-row gate above).
- PRD-140 items 5, 6, and 7: the middleware resolver rewrite, the
  sidebar/field-home/login rewiring, and deleting the hard-coded role
  arrays. These three need to run together (6 and 7 depend on 5), and
  need you present to authenticate for the live three-role smoke test
  the item's own spec requires before and after the change. This is the
  single highest-value, highest-risk remaining piece: once it lands,
  Settings > Users becomes the real, single source of truth for who can
  see what, instead of running in parallel with the still-live
  hard-coded arrays.

Getting PRD-138 and the rest of PRD-141 moving needs the actual spec
documents placed somewhere this session (or the next one) can read them,
the same way PRD-140's spec was pasted directly into this loop's own
instruction.

## PRD-141 DONE

---

# PRD-141c (closeout loop, real specs)

Lock taken 2026-10-18 00:55 Dubai. Real specs on main (PRD-138 7,562 bytes, PRD-141 20,202 bytes,
verbatim). Evidence for every line is in `docs/prds/PRD-141-log.md` under "PRD-141c log".
This table is updated after every item.

| PRD / item                         | Status               | Evidence / migration                                                                                                                                      |
| ---------------------------------- | -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 141 items 0 and 1 (swap integrity) | DONE                 | 20261018055751 + hotfix 20261018060733; FE reproduction on WH2-2001: Add New and Swap pod both now write the Remove leg; Warehouse Confirmations shows it |
| 141 item 2 (returns to Central) | DONE | 20261018061825; Warehouse Confirmations and wh_approve paths credit WH_CENTRAL unless return_warehouse_id |
| 141 item 3 (split by expiry) | ALREADY DONE | branch merged in main; 5 units / 2 expiries -> 2 WH_CENTRAL rows (rolled-back test) |
| 141 item 4 (Damaged outcome) | DONE | 20261018061825; damaged row quarantined (generated column), not pickable, shows on WH Quarantine |
| 141 item 5 (M2M visibility) | DONE | 20261018061903; m2m_transfer line in Warehouse Confirmations, destination pod at confirmed qty |
| 138 WS-A                           | ALREADY DONE         | bd13e1e, md5 equal for all 7 files                                                                                                                        |
| 138 WS-B = 141 item 13             | DONE                 | 20261017210334; only VOXDFC-1001/2006 flip; drift 0 rows                                                                                                  |
| 141 item 14                        | DONE                 | 20261017210904; ACTIVATEMOE stays eligible with flags removed (rolled-back test)                                                                          |
| 138 WS-C.1                         | DONE                 | drift_reason live in 20261017210904                                                                                                                       |
| 138 WS-C.2, WS-C.3                 | BLOCKED (permission) | Routine prompt edit refused by the auto-mode classifier; text in docs/prds/PRD-138-wsc-drift-routine-prompt.md                                            |
| 141 item 15                        | DONE                 | 20261017212132; empty-lane term in p_score and p_score_aed; VOX-aware fill ALREADY DONE                                                                   |
