-- PRD-CLEAN-02 M2: weekly correlation refresh, Sunday 01:00 UTC = 05:00 Dubai.
-- cron.schedule upserts by jobname, so re-running is safe.
SELECT cron.schedule(
  'refresh_correlation_weekly',
  '0 1 * * 0',
  $$SET statement_timeout='1200000'; SELECT public.refresh_correlation_pod();$$
);
