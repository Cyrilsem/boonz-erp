-- PRD-110 P4.3d — the weekly miner schedule
-- Cody review (leg 89). Article 11: the job calls an RPC, never an INSERT.
--
-- ⛔ WHY MONDAY 01:30 UTC = 05:30 DUBAI. The UAE work week is Mon-Fri, so the
--    findings are freshest at the moment CS could act on them. It sits clear of
--    every other schedule: the refill pipeline runs Stage 1 at 16:00 UTC and
--    the nightly v3 shadow at 21:22 UTC, both the previous day; the only other
--    weekly job (38, refresh_correlation_weekly) is SUNDAY 01:00 UTC. Hour 1
--    otherwise holds only cron 39 at :30 — which is why this takes :30 on a day
--    39 also runs, and the two are 24h-independent read-mostly jobs of ~150 ms
--    and a monitor respectively. Both miners together measured 140 ms live, so
--    no statement_timeout override is warranted.
--
-- ⛔ BOTH MINERS RUN DRY. run_weekly_miners_v3 reads
--    refill_policy_params.miner_weekly_{pick,edit}_dry_run, which default TRUE.
--    The command passes NO override on purpose: the activation CS eventually
--    performs is one UPDATE on the dial, with no migration and no cron edit,
--    and the override path is role-gated so the dial cannot be bypassed.

DO $c$
BEGIN
  PERFORM cron.unschedule('prd110_p43d_weekly_miners_0530_dubai');
EXCEPTION WHEN OTHERS THEN
  NULL;  -- not previously scheduled
END $c$;

SELECT cron.schedule(
  'prd110_p43d_weekly_miners_0530_dubai',
  '30 1 * * 1',
  $cron$SELECT public.run_weekly_miners_v3(p_invoked_by => 'cron');$cron$
);
