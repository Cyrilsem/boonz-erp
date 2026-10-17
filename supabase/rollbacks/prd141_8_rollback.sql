-- Rollback for 20261017174644_prd141_8_function_privilege_drift.sql
DROP FUNCTION IF EXISTS public.check_function_privileges(text[]);

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
    PERFORM public.safe_monitoring_alert(
      'prd139c_close_anon_definer_functions',
      'warning',
      jsonb_build_object(
        'function', r.nspname || '.' || r.proname,
        'args', r.args,
        'closed_at', now()
      )
    );
    n := n + 1;
  END LOOP;
  RETURN jsonb_build_object('result', 'success', 'closed_count', n, 'ran_at', now());
END;
$function$;
