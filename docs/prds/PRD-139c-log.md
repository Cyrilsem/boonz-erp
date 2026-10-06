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
