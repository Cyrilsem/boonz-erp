# PRD-139c running log

Start: 2026-10-06T08:06:57Z. Lock taken cleanly (commit fec01ea, rebased onto
bbb8968 after a benign push race plus CS's own unrelated /logout feature commit
10dadfa, which also touched src/middleware.ts and field/page.tsx -- watched for
conflicts with Items 1 and 3 below).

## Item log

### Item 1: anon default on new functions - DONE

Confirmed ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public
REVOKE EXECUTE ON FUNCTIONS FROM anon, PUBLIC fails as postgres with
"permission denied to change default privileges" (42501). Matches the
PRD-139b finding exactly: postgres cannot alter supabase_admin's own
defaults in this managed project.

Built the documented fallback per spec:

- close_anon_definer_functions(): SECURITY DEFINER, owner postgres, revokes
  EXECUTE from anon and PUBLIC on every public prosecdef function anon can
  execute, logs one monitoring_alerts row per function closed via
  safe_monitoring_alert. EXECUTE revoked from anon, authenticated, and
  PUBLIC on the watchdog itself (it is cron-only infrastructure, not an app
  RPC).
- Cody review flagged one revision: the draft also GRANTed EXECUTE to
  authenticated/service_role on every closed function, which the spec did
  not ask for and which could wrongly widen access on a function meant to
  be postgres/service_role only. Removed; the watchdog now only revokes.
- pg_cron job close_anon_definer_functions scheduled */15 * * * *.
- check_ambiguous_function_overloads() (confirmed via cron.job as the
  existing nightly drift/parity check, 20:50 daily) extended to also
  compute and return anon_executable_definer_count, alerting critical via
  safe_monitoring_alert when nonzero. Same function name, same schedule,
  additive only.

Applied as 20261006081718_prd139c_1_close_anon_definer_watchdog.sql.
Rollback at supabase/rollbacks/prd139c_1_rollback.sql.

Accept test run live: created a throwaway SECURITY DEFINER function
(prd139c_test_anon_definer), confirmed anon could execute it, ran
close_anon_definer_functions() directly (one watchdog cycle), confirmed
anon access was revoked and the anon-executable-definer count returned to
0, confirmed a monitoring_alerts row was logged for the closed function,
then dropped the test function. Also reran
check_ambiguous_function_overloads() post-fix: ambiguous_overload_count 0,
anon_executable_definer_count 0, status ok.

Residual, unchanged from PRD-139b: postgres still cannot alter
supabase_admin's own default privileges. This watchdog is a mitigating
control (closes any new exposure within 15 minutes), not a fix of the
underlying permission ceiling.

### Item 2: 7 dead tables with no RLS and anon SELECT - DONE

Grepped src/ and supabase/functions/ for all 7 names. Zero hits in either
location for any of the 7, including weimi_product_alias. Per the spec's
own branch for that table (RLS + authenticated SELECT only if read by the
app, else revoke like the others), weimi_product_alias is revoked, not
RLS-gated.

Checked pg_class.relacl directly before writing the fix, not just
has_table_privilege: authenticated held full read-write-delete-truncate
(arwdDxtm) on all 7 as a direct grant, not through PUBLIC. Worse than the
spec's own description (anon SELECT only) and a live Article 3 exposure in
its own right. REVOKE ALL FROM anon, authenticated closes both in one
statement. No DROP, per the explicit instruction.

Applied as 20261006090058_prd139c_2_revoke_dead_tables.sql. Rollback at
supabase/rollbacks/prd139c_2_rollback.sql.

Verified post-apply: anon_select, authenticated_select, and
authenticated_insert all false on all 7 tables.

### Item 3: Home KPI cards read v_machine_pack_status - DONE

src/app/(field)/field/page.tsx's local machineStageCounts() re-derivation
(fillable-basis + dispatch-dominance logic over raw refill_dispatching
rows) is removed entirely for both the warehouse/admin branch and the
driver branch. Both now query v_machine_pack_status directly for
dispatch_date = today (machine_id, total_included, is_pack_complete,
is_pickup_complete, is_dispatch_complete), filter to rows with
total_included > 0 (machines with at least one included, non-cancelled
line, matching the old include=true filter), and count is_pack_complete /
is_pickup_complete / is_dispatch_complete directly. This is the same view
and the same three booleans Packing, Pickup, and Dispatching already read
(confirmed by reading those three pages' own queries before writing
anything, not assumed).

Daily Refills "Machines packed/picked up/dispatched" and the admin Field
Operations "Ready to collect" / "To dispatch" cards all derive from this
same shared result, so they move together automatically.

Checked live against today's data: v_machine_pack_status gives 8 machines
with total_included > 0, 8 packed, 8 picked up, 3 dispatched for today's
dispatch_date. Cross-checked independently: a plain count of distinct
machine_id in refill_dispatching with include=true and cancelled=false for
today's date is also 8, matching total_included > 0's machine count
exactly.

npx tsc --noEmit clean. npx eslint on this file: zero problems. Full repo
npm run lint has 151 pre-existing problems in unrelated files
(PendingRemoveApprovalsPanel.tsx, WarehouseConfirmationsPanel.tsx,
supabase/functions/evaluate-lifecycle/index.ts), none introduced by this
change.

No DB migration, no Cody review, no rollback file for this item (pure FE
read-path change, not DDL/DEFINER/RLS, and the spec's Cody+rollback
requirement names only items 1 and 2).

### Item 4: pack screen in-app Back guard - DONE

The PRD-139b Item 9 beforeunload warning only fires on a reload or closed
tab, not on a Next.js client-side navigation, so the pack detail screen's
own "Back" link (rendered by the shared FieldHeader component) could
silently discard unsaved pack decisions. Added an optional onBackAttempt
prop to FieldHeader: if provided, it runs on click of the Back link, and
returning false cancels the navigation via e.preventDefault(). Left every
other FieldHeader call site unchanged (prop is optional, default
no-op).

In the pack detail page, added handleBackAttempt(), the same unsaved-count
check already used by the beforeunload effect (lines with action !== null,
skipped entirely once saved is true), showing window.confirm with the
exact message "You have N unsaved packs. Leave anyway?" and wired it to
the loaded-state FieldHeader via onBackAttempt. The loading-state
FieldHeader (lines are always empty while loading) is left without the
guard since there is nothing to lose yet.

Browser/OS-level back (history popstate) is out of scope here, matching
the PRD's own wording ("in-app Back guard") and the existing PRD-139b-log
note it resolves ("In-app Back-button guard deferred") - both refer to the
app's own Back link, not browser chrome.

npx tsc --noEmit clean. npx eslint on both modified files: zero new
problems (one pre-existing, unrelated lint error on an unrelated
fetchData() effect at line 1571 of the pack detail page, confirmed via
git diff to be outside this change).

No DB migration, no Cody review, no rollback file (pure FE change, not
named in the spec's Cody+rollback requirement).

### Item 5: Machine Stock Expiry To validate toggle - DONE

Confirmed before editing (not assumed) that the existing `to_validate`
filter case is defined entirely over 0-unit rows (current_stock <= 0 AND
past expiry - the ghost-row definition). Literally hiding 0-unit rows in
that view by default would empty it completely, which is the exact
conflict flagged in PRD-139b-log.md. The user's own resolution in this
PRD-139c spec is the toggle, implemented as given, not re-litigated.

Added a showZeroUnitRows state (default false). The to_validate filter
branch now returns no rows unless the toggle is on; every other filter is
untouched. A "Show 0-unit rows" checkbox renders only when the To
validate pill is active, directly under the filter pills. The pill's own
badge count (filterCounts.to_validate) is unaffected by the toggle, so the
count is always visible even while the list itself defaults to hidden.

The generic empty-state ("No items in this category / All clear for this
range") would have been misleading here (rows exist, they are just
hidden, not actually clear), so this exact case gets its own message:
"N rows hidden / Check Show 0-unit rows above to validate them".

npx tsc --noEmit clean. npx eslint on this file: zero problems.

No DB migration, no Cody review, no rollback file (pure FE change, not
named in the spec's Cody+rollback requirement).

## PRD-139c item work complete

All 5 items done. Phase 5-equivalent gates (accept criteria) run next:
anon definer count after a real cron cycle, anon SELECT denied on all 7
Item 2 tables, Home-vs-Pickup/Dispatching count parity for today, and the
operator_admin/warehouse/field_staff smoke test.
