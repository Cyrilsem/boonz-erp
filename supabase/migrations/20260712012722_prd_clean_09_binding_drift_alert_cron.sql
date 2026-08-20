-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- PRD-CLEAN-09 binding-drift guard (Clean Ecosystem Loop, incident session 2026-07-12).
-- Registers the nightly cron job that runs cron_slot_binding_drift_alert() against
-- v_slot_binding_drift. The function BODY itself was later fully replaced by
-- p0_fix4_drift_monitor_v2 (already committed to git, see docs/architecture/CHANGELOG.md
-- ~line 2899) -- this migration only recreates the cron.job registration. Confirmed live
-- 2026-08-20 as cron.job id 39 "slot_binding_drift_nightly", schedule '30 1 * * *',
-- command 'SELECT public.cron_slot_binding_drift_alert();', active=true.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'slot_binding_drift_nightly') THEN
    PERFORM cron.unschedule('slot_binding_drift_nightly');
  END IF;

  PERFORM cron.schedule(
    'slot_binding_drift_nightly',
    '30 1 * * *',
    'SELECT public.cron_slot_binding_drift_alert();'
  );
END $$;
