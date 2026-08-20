-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- RC-14 Tier 2b: schedules the nightly catch-up sweep for sweep_inactivate_stale_zero_stock()
-- (see rc14t2_zerostock_reinactivation_and_cache_cadence, 20260719101000). Confirmed live
-- 2026-08-20 as cron.job id 41 "sweep_inactivate_stale_zero_stock_nightly", schedule
-- '10 2 * * *', command "SELECT public.sweep_inactivate_stale_zero_stock('nightly cron sweep');",
-- active=true.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'sweep_inactivate_stale_zero_stock_nightly') THEN
    PERFORM cron.unschedule('sweep_inactivate_stale_zero_stock_nightly');
  END IF;

  PERFORM cron.schedule(
    'sweep_inactivate_stale_zero_stock_nightly',
    '10 2 * * *',
    $c$SELECT public.sweep_inactivate_stale_zero_stock('nightly cron sweep');$c$
  );
END $$;
