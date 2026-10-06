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
