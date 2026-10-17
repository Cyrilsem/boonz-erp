-- PRD-141 item 11 rollback: restore the 375 pre-normalisation split_pct values and drop the nightly job.
DO $rb$
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'prd141_11_rollback', true);
  UPDATE public.product_mapping pm SET split_pct = b.old_split_pct
    FROM public.prd141_mapping_split_backup b WHERE b.mapping_id = pm.mapping_id;
END $rb$;
SELECT cron.unschedule('prd141_mapping_split_sums_0340_dubai');
