-- PRD-072 P3: writers-vs-constraint drift guard for warehouse provenance reasons.
--
-- History: wh_provenance_reason_enum (CHECK on warehouse_inventory.provenance_reason)
-- was not updated when credit_dispatch_remainder ('dispatch_partial_remainder') and
-- warehouse_expire_writeoff ('expiry_writeoff') shipped; their INSERTs violated the
-- constraint and killed drivers' partial-return saves until the 2026-07-03 hotfix
-- (wh_provenance_enum_add_missing_values). This guard makes that drift impossible to
-- reintroduce silently: it statically scans every public function body for
-- set_config('app.provenance_reason', '<literal>') and checks each literal against
-- the live constraint. Run it in CI/health checks; this migration also asserts once
-- at apply time and fails the apply if drift exists.
CREATE OR REPLACE FUNCTION public.check_provenance_reason_registry()
RETURNS TABLE (function_name text, provenance_reason text, registered boolean)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $$
  WITH allowed AS (
    SELECT array_agg(m[1]) AS reasons
    FROM pg_constraint c,
         regexp_matches(pg_get_constraintdef(c.oid), '''([a-z_]+)''::text', 'g') m
    WHERE c.conname = 'wh_provenance_reason_enum'
  ),
  writers AS (
    SELECT p.proname::text AS function_name, m[1] AS reason
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace,
         regexp_matches(p.prosrc, 'set_config\(\s*''app\.provenance_reason''\s*,\s*''([^'']+)''', 'g') m
    WHERE n.nspname = 'public'
  )
  SELECT w.function_name, w.reason,
         w.reason = ANY (a.reasons) AS registered
  FROM writers w CROSS JOIN allowed a
  ORDER BY registered, w.function_name;
$$;

REVOKE ALL ON FUNCTION public.check_provenance_reason_registry() FROM public;
GRANT EXECUTE ON FUNCTION public.check_provenance_reason_registry() TO authenticated, service_role;

COMMENT ON FUNCTION public.check_provenance_reason_registry() IS
  'PRD-072: returns every set_config(app.provenance_reason, literal) across public functions with whether the literal is registered in the wh_provenance_reason_enum CHECK. Any registered=false row is drift that will fail writes at runtime.';

-- Apply-time assertion: fail this migration if any writer stamps an unregistered reason.
DO $$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(function_name || ' -> ' || provenance_reason, ', ')
    INTO v_bad
  FROM public.check_provenance_reason_registry()
  WHERE registered = false;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'provenance drift: unregistered app.provenance_reason value(s): %', v_bad;
  END IF;
END $$;
