-- PRD-013 P3.D: auto_expire_pod_inventory_edits function + pg_cron at 02:30 Dubai daily.
-- Flips pod_inventory_edits.status from pending to expired for rows older than 14 days.
-- 02:30 Dubai = 22:30 UTC; matches PRD section A.3 + slot one hour off the PRD-012 cron
-- pod_add_proposals_auto_expire (22:00 UTC) to spread DB load.
-- Cody verdict: APPROVE (Articles 4, 5, 8, 11, 12).

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

REVOKE ALL ON FUNCTION public.auto_expire_pod_inventory_edits() FROM public;

COMMENT ON FUNCTION public.auto_expire_pod_inventory_edits() IS
  'PRD-013 P3.D. Daily cron callable. Flips pod_inventory_edits.status from pending to expired after 14 days. Targets ALL edit_types (not just add_new_product). Only transitions pending into expired; never touches approved/rejected/expired rows.';

-- 02:30 Dubai = 22:30 UTC. Idempotency guard so the migration is safely re-runnable.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pod_inventory_edits_auto_expire') THEN
    PERFORM cron.unschedule('pod_inventory_edits_auto_expire');
  END IF;
  PERFORM cron.schedule(
    'pod_inventory_edits_auto_expire',
    '30 22 * * *',
    $cmd$SELECT public.auto_expire_pod_inventory_edits();$cmd$
  );
END $$;
