-- CS ask 2026-09-29: a nightly, standalone alert for the exact class of bug that just hit prod
-- (insert_driver_remove_line 7-arg vs 8-arg overload, hotfixed 2026-09-29 06:34 Dubai per
-- 20260929063422_hotfix_drop_ambiguous_insert_driver_remove_line_7arg.sql). This mirrors the
-- "gate 2a" query added to docs/REFILL-DAILY-LOOP.md as a mandatory end-of-run check, so the
-- same class of bug is also caught on any night nobody runs a loop at all.
--
-- Detects any pair of same-named public functions where the shorter argument-type list is an
-- exact prefix of the longer one, and every argument on the longer one past that prefix has a
-- default -- exactly the shape CREATE OR REPLACE silently creates a NEW overload instead of
-- replacing an existing function, the moment someone adds a new DEFAULT-valued trailing
-- parameter without also dropping the old signature.
--
-- Severity: monitoring_alerts.severity only allows info/warning/critical (verified live via
-- pg_constraint before writing this); CS asked for "high", mapped to 'critical' here since this
-- class of bug breaks live RPC calls outright (ambiguous function call errors), not a soft warning.
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
      AND f_short.proargtypes::oid[] = (f_long.proargtypes::oid[])[1:f_short.pronargs]
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

SELECT cron.schedule(
  'check_ambiguous_function_overloads_nightly',
  '50 20 * * *',
  $$ SELECT public.check_ambiguous_function_overloads(); $$
);