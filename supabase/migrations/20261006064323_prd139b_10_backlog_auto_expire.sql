-- PRD-139b Item 10: operational backlogs, part 1 (auto-expire nightly jobs).
--
-- Investigated before writing this: auto_expire_pod_inventory_edits() already
-- exists and is already scheduled nightly at 22:30 (cron job
-- pod_inventory_edits_auto_expire, active) -- but with a 14-day threshold, not the
-- spec's 7 days. No driver_feedback auto-expire exists at all (8 unresolved rows
-- older than 30 days confirmed live, matching the PRD's stated fact).

-- Tighten the existing job from 14 days to the spec's 7.
CREATE OR REPLACE FUNCTION public.auto_expire_pod_inventory_edits()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_expired_count int;
BEGIN
  PERFORM set_config('app.via_rpc',         'true', true);
  PERFORM set_config('app.rpc_name',        'auto_expire_pod_inventory_edits', true);
  PERFORM set_config('app.mutation_reason', 'cron_auto_expire_pod_inventory_edits_7d', true);

  WITH updated AS (
    UPDATE public.pod_inventory_edits
       SET status = 'expired',
           reviewed_at = now(),
           notes = COALESCE(notes || E'\n[cron] ', '[cron] ')
                   || format('auto_expired after 7 days at %s', now())
     WHERE status = 'pending'
       AND created_at < now() - interval '7 days'
    RETURNING edit_id
  )
  SELECT count(*) INTO v_expired_count FROM updated;

  RETURN jsonb_build_object(
    'result',        'success',
    'expired_count', v_expired_count,
    'ran_at',        now()
  );
END;
$function$;

-- New: driver_feedback auto-expire, 30 days unresolved per spec.
CREATE OR REPLACE FUNCTION public.auto_expire_driver_feedback()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_expired_count int;
BEGIN
  PERFORM set_config('app.via_rpc',         'true', true);
  PERFORM set_config('app.rpc_name',        'auto_expire_driver_feedback', true);
  PERFORM set_config('app.mutation_reason', 'cron_auto_expire_driver_feedback_30d', true);

  WITH updated AS (
    UPDATE public.driver_feedback
       SET resolved = true,
           resolved_at = now(),
           resolved_by_engine = 'auto-expired PRD-139'
     WHERE resolved = false
       AND created_at < now() - interval '30 days'
    RETURNING feedback_id
  )
  SELECT count(*) INTO v_expired_count FROM updated;

  RETURN jsonb_build_object(
    'result',        'success',
    'expired_count', v_expired_count,
    'ran_at',        now()
  );
END;
$function$;

SELECT cron.schedule(
  'driver_feedback_auto_expire',
  '0 22 * * *',
  $$SELECT public.auto_expire_driver_feedback();$$
);
