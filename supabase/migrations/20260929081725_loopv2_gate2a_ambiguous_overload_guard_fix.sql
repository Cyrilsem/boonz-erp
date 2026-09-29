-- Fix for check_ambiguous_function_overloads() applied minutes ago (loopv2_gate2a_ambiguous_
-- overload_guard): the first version compared pg_proc.proargtypes cast to oid[] directly with
-- array slicing ([1:n]). proargtypes::oid[] always has a lower bound of 0 (an oidvector artifact),
-- so a [1:n] slice silently grabbed the WRONG elements (positions 2..n+1, not 1..n), and even
-- after fixing the slice, comparing a 0-based array to a normally-1-based array with "=" is FALSE
-- in Postgres even when the elements are identical (array equality considers bounds). Caught this
-- during the function's own rolled-back smoke test (a synthetic 2-arg/3-arg overload pair was not
-- detected). Fixed by normalizing BOTH sides through unnest()+array_agg() before comparing, which
-- always produces a plain 1-based array regardless of the source's bounds.
--
-- Re-verified after the fix: the synthetic smoke test now correctly detects its planted pair, and
-- a fresh run against real prod schema finds a genuine pre-existing case that the buggy first
-- version missed: propose_decommission_plan has a 5-arg and a 6-arg overload (the 6-arg adds
-- p_min_pearson DEFAULT 0.30), the same CREATE OR REPLACE-adds-a-default-arg pattern as tonight's
-- insert_driver_remove_line incident. Not fixed here (out of scope for this gate migration,
-- reported to CS instead); this migration only corrects the detector's own logic.
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