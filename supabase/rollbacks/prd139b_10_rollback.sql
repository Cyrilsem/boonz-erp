-- Rollback for 20261006064323_prd139b_10_backlog_auto_expire.sql
SELECT cron.unschedule('driver_feedback_auto_expire');
DROP FUNCTION IF EXISTS public.auto_expire_driver_feedback();

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
  PERFORM set_config('app.mutation_reason', 'cron_auto_expire_pod_inventory_edits_14d', true);

  WITH updated AS (
    UPDATE public.pod_inventory_edits
       SET status = 'expired',
           reviewed_at = now(),
           notes = COALESCE(notes || E'\n[cron] ', '[cron] ')
                   || format('auto_expired after 14 days at %s', now())
     WHERE status = 'pending'
       AND created_at < now() - interval '14 days'
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
