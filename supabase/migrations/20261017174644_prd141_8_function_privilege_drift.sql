-- PRD-141 Item 8: function privilege drift + watchdog fix.
--
-- close_anon_definer_functions() (PRD-139c) revoked anon and PUBLIC execute
-- on every anon-executable SECURITY DEFINER function, but never re-granted
-- authenticated afterward. That is exactly how PRD-139c's own closing report
-- caught authenticated silently losing execute on 14 functions when the
-- watchdog last ran against a function it hadn't seen before. Fix: after
-- revoking, grant authenticated back unless the function name is in
-- access_internal_functions (the PRD-140 Item 1 allowlist, already seeded
-- with the 14 legitimately-internal names).
CREATE OR REPLACE FUNCTION public.close_anon_definer_functions()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM anon, PUBLIC', r.nspname, r.proname, r.args);
    IF NOT EXISTS (SELECT 1 FROM public.access_internal_functions aif WHERE aif.proname = r.proname) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %I.%I(%s) TO authenticated', r.nspname, r.proname, r.args);
    END IF;
    PERFORM public.safe_monitoring_alert(
      'prd139c_close_anon_definer_functions',
      'warning',
      jsonb_build_object(
        'function', r.nspname || '.' || r.proname,
        'args', r.args,
        'closed_at', now(),
        'granted_to_authenticated', NOT EXISTS (SELECT 1 FROM public.access_internal_functions aif WHERE aif.proname = r.proname)
      )
    );
    n := n + 1;
  END LOOP;
  RETURN jsonb_build_object('result', 'success', 'closed_count', n, 'ran_at', now());
END;
$function$;

-- New standing check: (a) definer functions in public executable by anon;
-- (b) functions referenced by any .rpc("name" call in src that lack an
-- authenticated execute grant (or do not exist). (b) needs the live list of
-- RPC names, generated at check time via scripts/rpc-names.txt (grep across
-- src/ and supabase/functions/ for .rpc("<name>"), not something a static
-- cron schedule can keep current as new RPC call sites are added later, so
-- this is a plain function meant to be called with a freshly generated list,
-- not wired into pg_cron the way check_ambiguous_function_overloads is.
CREATE OR REPLACE FUNCTION public.check_function_privileges(p_rpc_names text[] DEFAULT NULL)
RETURNS TABLE(check_type text, proname text, detail text)
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  SELECT 'anon_executable_definer'::text, p.proname::text,
         'anon can execute this SECURITY DEFINER function'::text
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef
    AND has_function_privilege('anon', p.oid, 'EXECUTE');

  IF p_rpc_names IS NOT NULL THEN
    RETURN QUERY
    SELECT 'rpc_missing_authenticated_grant'::text, names.name::text,
           'referenced via .rpc() in src but authenticated cannot execute any function with this name'::text
    FROM unnest(p_rpc_names) AS names(name)
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = names.name
        AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
    );
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.check_function_privileges(text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.check_function_privileges(text[]) TO authenticated;
