-- Rollback for PRD-145 P3-7: unschedules the nightly count and drops the five functions. Rows cleared while it was live
-- stay cleared (each one is in pod_inventory_audit_log with the reason and the old quantity).
SELECT cron.unschedule('prd145_pod_orphan_rows_0400_dubai');
DROP FUNCTION public.get_pod_orphan_summary();
DROP FUNCTION public.record_pod_orphan_counts();
DROP FUNCTION public.clear_pod_orphan_rows(uuid, text);
DROP FUNCTION public.pod_orphan_clear_gate(uuid);
DROP FUNCTION public.get_pod_orphan_rows(uuid);
