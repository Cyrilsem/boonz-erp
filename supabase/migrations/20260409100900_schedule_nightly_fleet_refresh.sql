-- CC-00c: Schedule nightly fleet refresh at 23:59 Dubai time (19:59 UTC)
-- Dubai is UTC+4 year-round, no DST.
-- Uses pg_cron — CREATE EXTENSION IF NOT EXISTS handles the case where it may already be enabled.
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;

SELECT cron.schedule(
  'nightly-fleet-refresh',
  '59 19 * * *',  -- 19:59 UTC = 23:59 Dubai (UTC+4, no DST)
  $$SELECT public.refresh_fleet_data(90);$$
);
