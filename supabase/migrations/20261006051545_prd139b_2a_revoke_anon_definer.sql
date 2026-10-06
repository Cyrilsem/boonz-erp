-- PRD-139b Item 2A: close anon EXECUTE on SECURITY DEFINER functions in public.
--
-- Facts verified live before writing this: 321 public SECURITY DEFINER functions are
-- executable by anon (has_function_privilege('anon', oid, 'EXECUTE')). Allowlist proof
-- (grep of src/ and supabase/functions/ for .rpc( calls reachable without a session, and
-- for anon-key usage server side): empty. Every browser RPC call happens after login
-- (role authenticated). The VOX API routes use SUPABASE_SERVICE_ROLE_KEY, not anon. The
-- one route using the anon key (api/machines/repurpose) only forwards the caller's own
-- JWT to an edge function via functions.invoke, it makes no direct .rpc() call itself,
-- and the edge function's actual RPC call runs on a service_role client after verifying
-- that JWT. So the allowlist below is intentionally empty.
--
-- Exact pre-revoke snapshot: supabase/rollbacks/prd139b_2a_anon_list.txt (321 functions,
-- schema.name(args), generated from this exact query, not hand-typed).
-- Rollback: supabase/rollbacks/prd139b_2a_rollback.sql (re-grants exactly those 321).

DO $$
DECLARE
  r RECORD;
  n INT := 0;
BEGIN
  FOR r IN
    SELECT p.oid, n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosecdef
      AND has_function_privilege('anon', p.oid, 'EXECUTE')
  LOOP
    EXECUTE format(
      'REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM anon, PUBLIC',
      r.nspname, r.proname, r.args
    );
    EXECUTE format(
      'GRANT EXECUTE ON FUNCTION %I.%I(%s) TO authenticated, service_role',
      r.nspname, r.proname, r.args
    );
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'PRD-139b 2A: revoked anon EXECUTE on % functions', n;
END $$;

-- Close the hole for every future function too. ALTER DEFAULT PRIVILEGES with no FOR ROLE
-- clause applies to the role running this migration. Also try postgres and supabase_admin
-- explicitly in case either differs from the executing role; log rather than fail if one
-- lacks permission to set another role's defaults.
DO $$
BEGIN
  EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon, PUBLIC';
  RAISE NOTICE 'PRD-139b 2A: set default privileges for role postgres';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PRD-139b 2A: skipped ALTER DEFAULT PRIVILEGES FOR ROLE postgres (insufficient privilege)';
WHEN undefined_object THEN
  RAISE NOTICE 'PRD-139b 2A: skipped ALTER DEFAULT PRIVILEGES FOR ROLE postgres (role not found)';
END $$;

DO $$
BEGIN
  EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon, PUBLIC';
  RAISE NOTICE 'PRD-139b 2A: set default privileges for role supabase_admin';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PRD-139b 2A: skipped ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin (insufficient privilege)';
WHEN undefined_object THEN
  RAISE NOTICE 'PRD-139b 2A: skipped ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin (role not found)';
END $$;

ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon, PUBLIC;
