-- Nightly assertion (incident follow-up, K1 cap fix): no `machines_to_visit`
-- row with status='picked' should be more than 30 days ahead of today.
-- Same family as check_expiry_unvalidated / assert_sales_names_resolved.
--
-- Why 30, not the guard's own 60-day lookback or 21-day cap: this is a data-
-- quality tripwire, not a re-statement of the guard's defenses. The guard
-- (20260908191503) already protects approve_refill_plan even if a bad row
-- exists; this assertion exists so a far-future picked row gets caught and
-- fixed at the SOURCE within a day, instead of silently sitting in
-- machines_to_visit until it (or a similar future gap elsewhere that also
-- reads status='picked') causes the next incident. 30 days is comfortably
-- past any real routing horizon this fleet plans on.
--
-- Root cause (documented in 20260908191503, not fixed here): CS can call
-- pick_machines_for_refill with any p_plan_date -- no upper bound exists.
-- This assertion is the detection half of containing that gap until (if
-- ever) the RPC itself gets an upper-bound check.
--
-- Verified in a rolled-back transaction: clean (status='ok') against the
-- real fleet immediately after the 64-row incident cleanup (unpicked via
-- unpick_machine_to_visit, the canonical writer -- not a direct UPDATE);
-- fires correctly (status='violation') against a synthetic 2030-01-01
-- picked row.
--
-- Cody: approve, Article 16, no writes (alerts via safe_monitoring_alert
-- only).
CREATE OR REPLACE FUNCTION public.check_far_future_picked_visits()
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_rows jsonb;
  v_n    int;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'machine_id', mtv.machine_id, 'official_name', mtv.official_name,
           'plan_date', mtv.plan_date, 'days_ahead', mtv.plan_date - CURRENT_DATE,
           'add_source', mtv.add_source, 'picked_at', mtv.picked_at)), '[]'::jsonb),
         COUNT(*)
    INTO v_rows, v_n
  FROM public.machines_to_visit mtv
  WHERE mtv.status = 'picked'
    AND mtv.plan_date > CURRENT_DATE + 30;

  IF v_n > 0 THEN
    PERFORM public.safe_monitoring_alert('far_future_picked_visit', 'critical',
      jsonb_build_object('checked_at', now(), 'count', v_n, 'rows', v_rows));
  END IF;

  RETURN jsonb_build_object('checked_at', now(), 'status', CASE WHEN v_n=0 THEN 'ok' ELSE 'violation' END,
                             'far_future_picked_count', v_n, 'rows', v_rows);
END;
$function$;

SELECT cron.schedule(
  'check_far_future_picked_visits_nightly',
  '20 20 * * *',
  $$ SELECT public.check_far_future_picked_visits(); $$
);
