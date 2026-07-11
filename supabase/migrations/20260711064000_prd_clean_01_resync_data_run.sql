-- PRD-CLEAN-01 M2 (data): fleet-wide Weimi-authoritative resync.
-- Idempotent: re-running after convergence touches 0 shelves.
-- Executed 2026-07-11 ~06:40 UTC (outside the 15:45-16:30 and 01:45-02:30 UTC cron windows).
SELECT * FROM public.resync_pod_inventory_from_weimi(NULL, false);
