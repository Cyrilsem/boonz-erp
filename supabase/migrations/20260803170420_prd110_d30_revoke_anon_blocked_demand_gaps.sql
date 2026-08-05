-- PRD-110 · CS DECISION D-30 ("REVOKE NOW"): anon EXECUTE off _blocked_demand_gaps_v3.
-- Answered by CS 2026-08-01 ~08:15 Dubai (Cowork session), executed relay leg 91.
-- S-140: a REVOKE ... FROM PUBLIC would remove NOTHING here (the grants are
-- per-role and explicit), so this revokes FROM anon by name and asserts the
-- resulting proacl string back.

DO $$
DECLARE
  v_n   int;
  v_acl text;
BEGIN
  SELECT count(*) INTO v_n
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = '_blocked_demand_gaps_v3';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'D-30 precondition failed: expected exactly 1 overload of _blocked_demand_gaps_v3, found %', v_n;
  END IF;

  SELECT p.proacl::text INTO v_acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = '_blocked_demand_gaps_v3';
  IF v_acl IS NULL OR v_acl NOT LIKE '%anon=X/%' THEN
    RAISE NOTICE 'D-30: anon grant already absent (acl=%) - revoke is a no-op', v_acl;
  END IF;
END $$;

REVOKE EXECUTE ON FUNCTION public._blocked_demand_gaps_v3(date) FROM anon;

DO $$
DECLARE
  v_acl text;
BEGIN
  SELECT p.proacl::text INTO v_acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = '_blocked_demand_gaps_v3';

  IF v_acl LIKE '%anon=%' THEN
    RAISE EXCEPTION 'D-30 FAILED: anon still present in proacl after revoke: %', v_acl;
  END IF;

  -- the three legitimate callers must SURVIVE the revoke (a revoke that also
  -- stripped service_role would break the nightly runner silently)
  IF v_acl NOT LIKE '%service_role=X/%' OR v_acl NOT LIKE '%authenticated=X/%' OR v_acl NOT LIKE '%postgres=X/%' THEN
    RAISE EXCEPTION 'D-30 FAILED: a legitimate grant was lost, acl=%', v_acl;
  END IF;

  RAISE NOTICE 'D-30 OK: proacl now %', v_acl;
END $$;
