-- PRD-012 P3.A: auto_expire_pod_add_proposals function + daily cron job.
-- D6 enforcement: pending add proposals older than 14 days flip to expired.
-- Cody review: approve with revisions (idempotency guard for cron.schedule).
-- Bound by Cody at P1.A hotfix review: cron must be SECURITY DEFINER, set
-- all three set_config markers, and UPDATE WHERE status='pending' only.

CREATE OR REPLACE FUNCTION public.auto_expire_pod_add_proposals()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_expired_count int;
BEGIN
  PERFORM set_config('app.via_rpc',         'true', true);
  PERFORM set_config('app.rpc_name',        'auto_expire_pod_add_proposals', true);
  PERFORM set_config('app.mutation_reason', 'cron_auto_expire_pod_add_14d', true);

  WITH updated AS (
    UPDATE public.pod_inventory_edits
       SET status = 'expired',
           expired_at = now(),
           notes = COALESCE(notes || E'\n[cron] ', '[cron] ')
                   || format('auto_expired after 14 days at %s', now())
     WHERE edit_type = 'add_new_product'
       AND status = 'pending'
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

REVOKE ALL ON FUNCTION public.auto_expire_pod_add_proposals() FROM public;

COMMENT ON FUNCTION public.auto_expire_pod_add_proposals() IS
  'PRD-012 A.5. Daily cron callable. Flips pod_inventory_edits add_new_product rows from pending to expired after 14 days (D6). Only transitions pending into expired; never touches approved or rejected rows. Returns jsonb with expired_count.';

-- 02:00 Dubai = 22:00 UTC. Idempotency guard so the migration is safely
-- re-runnable (cron.schedule raises if jobname already exists).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pod_add_proposals_auto_expire') THEN
    PERFORM cron.unschedule('pod_add_proposals_auto_expire');
  END IF;
  PERFORM cron.schedule(
    'pod_add_proposals_auto_expire',
    '0 22 * * *',
    $cmd$SELECT public.auto_expire_pod_add_proposals();$cmd$
  );
END $$;
