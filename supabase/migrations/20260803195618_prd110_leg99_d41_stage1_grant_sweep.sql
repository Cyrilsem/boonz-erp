-- PRD-110 leg 99 · D-41 EXECUTED — revoke anon + PUBLIC EXECUTE from the five
-- legacy Stage-1 functions.
--
-- CS closed D-41 (2026-08-03, Cowork session): "REVOKE ALL FIVE NOW. One
-- Cody-reviewed sweep: REVOKE anon EXECUTE on all five legacy Stage-1 functions
-- carrying the NULL-uid guard inversion. Grant-layer fix only — live function
-- bodies stay byte-untouched (LAW 12); the guard-pattern hardening itself ships
-- with v3, which already implements the correct NULL-refusing check. Verify
-- post-revoke with has_function_privilege('anon', oid, 'EXECUTE') = false on all
-- five, and add the ACL assertion to the standing fixture set so a future grant
-- regression goes red."
--
-- Golden fixture 64 (20260803195429) is that standing assertion. It landed FIRST
-- (LAW 1) and was RED on exactly the 12 grant assertions this migration turns green.
--
-- ⛔ WHY `PUBLIC` IS IN SCOPE. D-41 was raised naming only `anon`. Measured live
-- this leg, FOUR of the five also carry a PUBLIC grant (`=X/postgres`):
-- build_draft_for_confirmed_v3, build_confirmed_now_v3, pick_machines_for_refill,
-- confirm_machines_to_visit. `anon` is a member of PUBLIC, so REVOKE ... FROM anon
-- alone leaves has_function_privilege('anon', oid, 'EXECUTE') = TRUE and CS's own
-- acceptance test FAILS. Revoking PUBLIC is required BY the answer, not drift
-- beyond it. Cody-reviewed on that basis. (_build_draft_core_v3 has no PUBLIC
-- grant; its REVOKE ... FROM PUBLIC is a harmless no-op, kept for symmetry.)
--
-- ⚠️ ARTICLE 4 IS NOT CURED HERE, BY DESIGN. The underlying defect is the guard
-- inversion `IF auth.uid() IS NOT NULL AND NOT EXISTS (...operator_admin...)`,
-- which SKIPS validation when there is no role. This migration removes
-- reachability, not the inversion. CS assigned the guard hardening to v3.
-- Fixture 64 seq 18-22 pin all five bodies by md5(prosrc) so that scope split
-- cannot be silently crossed in either direction.
--
-- S-140 working form: explicit per-role REVOKE, then read proacl BACK and assert
-- the WHOLE string. Supabase grants anon explicitly, so a PUBLIC-only revoke
-- removes nothing — and as found here, an anon-only revoke removes nothing either
-- when a PUBLIC grant is also present. Both are needed.

REVOKE EXECUTE ON FUNCTION public._build_draft_core_v3(date, boolean, boolean) FROM anon;
REVOKE EXECUTE ON FUNCTION public._build_draft_core_v3(date, boolean, boolean) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.build_draft_for_confirmed_v3(date, boolean) FROM anon;
REVOKE EXECUTE ON FUNCTION public.build_draft_for_confirmed_v3(date, boolean) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.build_confirmed_now_v3(date) FROM anon;
REVOKE EXECUTE ON FUNCTION public.build_confirmed_now_v3(date) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.pick_machines_for_refill(date, integer, integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.pick_machines_for_refill(date, integer, integer) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.confirm_machines_to_visit(date) FROM anon;
REVOKE EXECUTE ON FUNCTION public.confirm_machines_to_visit(date) FROM PUBLIC;

-- ── VERIFY IN-MIGRATION (S-140): read proacl BACK and assert the WHOLE string,
-- plus CS's literal acceptance test. Any deviation aborts the migration.
DO $$
DECLARE
  r          record;
  v_expected text := '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}';
  v_n        int  := 0;
BEGIN
  FOR r IN
    SELECT p.oid, p.oid::regprocedure::text AS sig, p.proacl::text AS acl,
           has_function_privilege('anon',         p.oid, 'EXECUTE') AS anon_x,
           has_function_privilege('authenticated',p.oid, 'EXECUTE') AS auth_x,
           has_function_privilege('service_role', p.oid, 'EXECUTE') AS svc_x
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN (
      '_build_draft_core_v3','build_draft_for_confirmed_v3','build_confirmed_now_v3',
      'pick_machines_for_refill','confirm_machines_to_visit')
  LOOP
    v_n := v_n + 1;

    IF r.anon_x THEN
      RAISE EXCEPTION 'D-41 FAILED: % still EXECUTable by anon (acl=%)', r.sig, r.acl;
    END IF;
    IF NOT r.auth_x THEN
      RAISE EXCEPTION 'D-41 OVER-REACH: % lost authenticated EXECUTE (acl=%)', r.sig, r.acl;
    END IF;
    IF NOT r.svc_x THEN
      RAISE EXCEPTION 'D-41 OVER-REACH: % lost service_role EXECUTE (acl=%)', r.sig, r.acl;
    END IF;
    IF r.acl IS DISTINCT FROM v_expected THEN
      RAISE EXCEPTION 'D-41 ACL MISMATCH on %: got % want %', r.sig, r.acl, v_expected;
    END IF;
  END LOOP;

  IF v_n <> 5 THEN
    RAISE EXCEPTION 'D-41 NON-VACUITY FAILED: matched % functions, expected 5', v_n;
  END IF;

  RAISE NOTICE 'D-41 OK: 5/5 revoked from anon+PUBLIC, all three legitimate grants intact';
END $$;
