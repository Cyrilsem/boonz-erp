-- PRD-110 leg 54 · L54-U1 · S-57 CLOSED — narrow the shadow-telemetry grants
--
-- Both tables carried Supabase's default `GRANT ALL` to `authenticated`
-- (INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER). pod_refills_shadow, the
-- house standard, carries SELECT only. Leg 53 believed shadow_runner_log_v3 had
-- followed that standard because the migration said `GRANT SELECT` — but a GRANT
-- is additive. Only a REVOKE narrows.
--
-- Not currently exploitable: both tables have RLS enabled with SELECT-only
-- policies, so the DML paths are refused anyway. This is the defence-in-depth
-- the rest of the suite already relies on, and it removes the dependence on RLS
-- being the sole line of defence.
--
-- SAFE TO REVOKE — verified live, not assumed. The only writers are
--   refresh_engine_forecast_error_v3  (SECURITY DEFINER, owner postgres)
--   run_nightly_shadow_v3             (SECURITY DEFINER, owner postgres)
-- so every legitimate write executes as postgres and is unaffected by the
-- `authenticated` grant. SELECT is deliberately retained: v_shadow_runner_health_v3
-- and the WMAPE reader views are read by authenticated callers.

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.shadow_runner_log_v3 FROM authenticated;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.engine_forecast_error_v3 FROM authenticated;

-- Prove it landed in the same breath as the change (the registries record the
-- claim; this records the fact).
DO $do$
DECLARE n_write int; n_read int;
BEGIN
  SELECT count(*) INTO n_write FROM information_schema.role_table_grants
   WHERE grantee = 'authenticated' AND table_schema = 'public'
     AND table_name IN ('shadow_runner_log_v3','engine_forecast_error_v3')
     AND privilege_type <> 'SELECT';
  SELECT count(*) INTO n_read FROM information_schema.role_table_grants
   WHERE grantee = 'authenticated' AND table_schema = 'public'
     AND table_name IN ('shadow_runner_log_v3','engine_forecast_error_v3')
     AND privilege_type = 'SELECT';
  IF n_write <> 0 THEN
    RAISE EXCEPTION 'S-57 REVOKE incomplete: % write privileges remain', n_write;
  END IF;
  IF n_read <> 2 THEN
    RAISE EXCEPTION 'S-57 REVOKE went too far: expected 2 SELECT grants, found %', n_read;
  END IF;
END $do$;
