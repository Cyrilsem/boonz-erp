-- PRD-141 item 23 rollback: stop the nightly drift report (the view and function stay, unreferenced).
SELECT cron.unschedule('prd141_pod_weimi_drift_0350_dubai');
