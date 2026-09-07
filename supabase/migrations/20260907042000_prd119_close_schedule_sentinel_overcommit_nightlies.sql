-- PRD-119/PRD-120 close-out, item 8 (nightly assertions audit): PRD-118
-- named three nightly guards -- sentinel-bindable, over-commit,
-- expiry_unvalidated. `check_expiry_unvalidated` was already scheduled
-- (PRD-119 P4). `check_consignment_sentinel_integrity` and
-- `check_dispatch_batch_overcommit` both EXIST, are pure read-only
-- reporting functions (SELECT + conditional safe_monitoring_alert, no
-- business-data writes), but neither was ever added to cron.job -- the
-- exact same "written but never wired" pattern already found and fixed for
-- check_expiry_unvalidated in PRD-119 P4.
--
-- Run live before scheduling: both are currently dirty.
-- check_consignment_sentinel_integrity: 55 live dispatch rows bound to a
-- phantom (2099-sentinel) batch. check_dispatch_batch_overcommit: 54
-- overcommitted batches. Both are real, pre-existing data conditions --
-- flagged for CS in the close-out report, not blind-fixed here. Scheduling
-- them makes these conditions visible going forward via monitoring_alerts;
-- it does not remediate the existing violations.
--
-- Cody: approve, Article 11 (cron calls the RPC only), matches the
-- check_expiry_unvalidated_nightly precedent exactly.
SELECT cron.schedule('check_consignment_sentinel_integrity_nightly', '15 20 * * *',
  $$ SELECT public.check_consignment_sentinel_integrity(); $$);
SELECT cron.schedule('check_dispatch_batch_overcommit_nightly', '30 20 * * *',
  $$ SELECT public.check_dispatch_batch_overcommit(); $$);
