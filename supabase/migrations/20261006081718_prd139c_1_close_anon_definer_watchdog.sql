-- PRD-139c Item 1: anon default on new functions.
--
-- Confirmed before writing this: ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin
-- IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon, PUBLIC fails with
-- "permission denied to change default privileges" (42501) when run as postgres.
-- Matches the PRD-139b finding: postgres cannot alter supabase_admin's own
-- defaults in this managed environment. Any function created under
-- supabase_admin is still born anon-executable. Building the documented fallback:
-- a scheduled watchdog that closes the gap within 15 minutes of any new exposure,
-- plus logging one monitoring_alerts row per function it closes.

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

-- This is a background watchdog, not an app RPC. No execute for anon or
-- authenticated at all -- only the pg_cron schedule (running as the function
-- owner, postgres, via SECURITY DEFINER) ever calls it.
REVOKE EXECUTE ON FUNCTION public.close_anon_definer_functions() FROM anon, authenticated, PUBLIC;

SELECT cron.schedule(
  'close_anon_definer_functions',
  '*/15 * * * *',
  $$SELECT public.close_anon_definer_functions();$$
);

-- Add the anon-executable-definer count to the existing nightly drift/parity
-- check (check_ambiguous_function_overloads, already cron-scheduled at 20:50).
-- Same name, same schedule, additive field only.
CREATE OR REPLACE FUNCTION public.check_ambiguous_function_overloads()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rows jsonb;
  v_n int;
  v_anon_definer_count int;
BEGIN
  WITH pairs AS (
    SELECT f_short.proname,
           pg_get_function_identity_arguments(f_short.oid) AS short_sig,
           pg_get_function_identity_arguments(f_long.oid) AS long_sig
    FROM pg_proc f_short
    JOIN pg_proc f_long
      ON f_short.proname = f_long.proname
     AND f_short.pronamespace = f_long.pronamespace
     AND f_short.oid <> f_long.oid
     AND f_short.pronargs < f_long.pronargs
    WHERE f_short.pronamespace = 'public'::regnamespace
      AND (SELECT array_agg(val ORDER BY ord) FROM unnest(f_short.proargtypes::oid[]) WITH ORDINALITY AS t(val, ord))
          =
          (SELECT array_agg(val ORDER BY ord) FROM unnest(f_long.proargtypes::oid[]) WITH ORDINALITY AS t(val, ord)
            WHERE ord <= f_short.pronargs)
      AND (f_long.pronargs - f_long.pronargdefaults) <= f_short.pronargs
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'function', proname, 'shorter_signature', short_sig, 'longer_signature', long_sig)), '[]'::jsonb),
         COUNT(*)
    INTO v_rows, v_n
    FROM pairs;

  IF v_n > 0 THEN
    PERFORM public.safe_monitoring_alert('ambiguous_function_overload', 'critical',
      jsonb_build_object('checked_at', now(), 'count', v_n, 'rows', v_rows,
        'note', 'CS asked for severity high; monitoring_alerts only allows info/warning/critical, mapped to critical'));
  END IF;

  -- PRD-139c Item 1: anon-executable-definer count, same place as the
  -- overload gate so both drift checks surface from one call.
  SELECT count(*) INTO v_anon_definer_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef
    AND has_function_privilege('anon', p.oid, 'EXECUTE');

  IF v_anon_definer_count > 0 THEN
    PERFORM public.safe_monitoring_alert('anon_executable_definer_functions', 'critical',
      jsonb_build_object('checked_at', now(), 'count', v_anon_definer_count));
  END IF;

  RETURN jsonb_build_object('checked_at', now(), 'status', CASE WHEN v_n=0 AND v_anon_definer_count=0 THEN 'ok' ELSE 'violation' END,
                             'ambiguous_overload_count', v_n, 'rows', v_rows,
                             'anon_executable_definer_count', v_anon_definer_count);
END;
$function$;
