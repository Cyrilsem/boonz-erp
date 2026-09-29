-- Rollback for PRD-137 F8 (driver Pending Reviews: dedupe/escalate check, 2026-09-30). Drops the
-- new function and its nightly cron job -- there is no prior version to restore.
SELECT cron.unschedule('check_stale_pending_reviews_nightly')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'check_stale_pending_reviews_nightly');
DROP FUNCTION IF EXISTS public.check_stale_pending_reviews();
