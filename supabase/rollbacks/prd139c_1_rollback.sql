-- Rollback for 20261006081718_prd139c_1_close_anon_definer_watchdog.sql
SELECT cron.unschedule('close_anon_definer_functions');
DROP FUNCTION IF EXISTS public.close_anon_definer_functions();

CREATE OR REPLACE FUNCTION public.check_ambiguous_function_overloads()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rows jsonb;
  v_n int;
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

  RETURN jsonb_build_object('checked_at', now(), 'status', CASE WHEN v_n=0 THEN 'ok' ELSE 'violation' END,
                             'ambiguous_overload_count', v_n, 'rows', v_rows);
END;
$function$;
