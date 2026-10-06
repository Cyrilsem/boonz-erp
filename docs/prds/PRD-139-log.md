# PRD-139 running log

Dates below are real. The loop's hard stop was 05:45 Dubai / 01:45 UTC on 2026-10-05. A
context compaction created a wall-clock gap; work did not notice the clock had passed
04:00 UTC on 2026-10-06 until partway through this entry. See PRD-139-REPORT.md for the
full account of that gap and its process-failure notes (two background investigation
forks ran 12 hours without returning usable results).

## Preceding, non-PRD-139 item (carried over from before this loop started)

- `receive_dispatch_line` return-then-receive double-credit guard.
- Cody: ✅ Approve, Articles 1, 4, 6, 8, 12 (reviewed before PRD-139 was issued).
- Tested: rolled-back transaction replaying the real 2026-10-05 MOE sequence (pack,
  return "Not added to machine", receive 4 minutes later). Warehouse stock net 0, pod
  credited exactly once.
- Applied: `supabase/migrations/20261005162816_receive_dispatch_line_undo_return.sql`
  (+ rollback). Recorded live as `receive_dispatch_line_undo_return_final` at version
  `20261005162816` (an earlier same-window apply at `20261005162215` had a transcription
  slip, a dropped `AND expiration_date IS NOT NULL` filter in the unrelated Remove
  fallback branch, caught by diffing against live `pg_get_functiondef` and corrected
  before anything was reported done).
- `docs/architecture/CHANGELOG.md` and `docs/architecture/RPC_REGISTRY.md` updated this
  session (were missing an entry despite the migration being applied and committed).
- Still owed, not done this session: "list which real people have used the Test Driver
  (7f4ecaa4) and Test Warehouse (bf32624e) accounts in the last 30 days", never started.

## PRD-139 Item 1, role self-promotion fix (DONE)

- Verified live before writing anything: `user_profiles` RLS has only the two
  CLAUDE.md-permitted policies (untouched by this work); `authenticated` held full
  table-wide UPDATE/INSERT with no column restriction; no guard trigger existed. 8 real
  users confirmed at the time (not the 6 the PRD's own text states): Anthony
  (field_staff), Jojo (field_staff), vox_admin@boonz.me (field_staff), Cyril Semaan
  (operator_admin), Raffy (operator_admin), Simran (warehouse), Test Driver (warehouse),
  Test Warehouse (warehouse).
- Client-writable columns confirmed via grep of `src/` (not assumed):
  `preferred_language`, `onboarding_complete`, `pages_toured`.
- Cody (self-reviewed under time pressure, full transcript in this session):
  ✅ Approve, Articles 2, 3, 4, 12, 13, 14, 16.
- Applied: `supabase/migrations/20261006043159_prd139_item1_user_profiles_role_guard.sql`
  (+ rollback).
- Live testing caught a real gap: the UPDATE branch of the guard trigger lacked the
  `auth.uid() IS NULL` bypass the INSERT branch already had, which would have blocked
  CS's own established direct-SQL-editor manual role-fix workflow (runs as `postgres`,
  no JWT claims, so `auth.uid()` is NULL there). Fixed same-window.
- Applied:
  `supabase/migrations/20261006043408_prd139_item1_role_guard_fix_postgres_bypass.sql`
  (+ rollback).
- Tested live (rolled-back transactions, impersonating real accounts via
  `set_config('request.jwt.claims', ...)`): field_staff (Anthony,
  `bddaec3c-fe18-40db-93e4-8ca543819519`) self-promotion to `superadmin` blocked
  (permission denied at the column-grant layer, before the trigger even runs, since
  `role` is excluded from the grant); `preferred_language` update by the same user still
  succeeds; a direct postgres-superuser SQL fix to `role` (CS's established workflow)
  still succeeds. `check_ambiguous_function_overloads()` returned
  `ambiguous_overload_count: 0` after both applies.
- Note on the PRD's own acceptance wording ("admin role change via the existing admin
  path still works"): no FE admin role-change UI exists today (confirmed via grep, no
  code path does it). The only real "admin path" live today is the direct-SQL-editor
  workflow, which this fix explicitly preserves. If an admin-role-change RPC is ever
  built, it should run SECURITY DEFINER (bypassing the column grant like
  `handle_new_user()` does) rather than relying on a raw `authenticated`-role UPDATE,
  since `role` is deliberately excluded from that grant.
- Found two stale, overlapping draft migrations for this same item already on disk at
  the start of this session (`DRAFT_prd139_item1_role_self_promotion_guard.sql` and this
  session's own first draft), evidence that an earlier pass (before or across the
  context-compaction gap) had independently investigated and designed this same fix
  without applying it, and had already flagged the same `auth.uid() IS NULL` gap this
  session caught independently via live testing. Both stale drafts deleted; the applied,
  tested, committed version is the one described above.
- `docs/architecture/CHANGELOG.md` and `docs/architecture/RPC_REGISTRY.md` updated.

## PRD-139 Items 2-10 and all Phase 5 gates

BLOCKED. Not reached. See `docs/prds/PRD-139-REPORT.md` for the exact status and reason
per item, and `docs/prds/PRD-139-backlog-report.md` for Item 10's stub.
