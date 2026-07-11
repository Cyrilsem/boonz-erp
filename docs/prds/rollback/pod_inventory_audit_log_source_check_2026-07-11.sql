-- Rollback for PRD-CLEAN-01 M1: restore original source CHECK on pod_inventory_audit_log
-- Captured 2026-07-11 before adding 'drift_resync' to the allowed list.
ALTER TABLE public.pod_inventory_audit_log DROP CONSTRAINT pod_inventory_audit_log_source_check;
ALTER TABLE public.pod_inventory_audit_log ADD CONSTRAINT pod_inventory_audit_log_source_check
  CHECK ((source = ANY (ARRAY['seed'::text, 'sale'::text, 'refill'::text, 'manual_edit'::text, 'weimi_sync'::text, 'correction'::text, 'cleanup'::text])));

-- resync_pod_inventory_from_weimi is a NEW function (no prior definition existed 2026-07-11).
-- Full removal:
-- DROP FUNCTION IF EXISTS public.resync_pod_inventory_from_weimi(uuid, boolean);
-- Data rollback: every row this RPC touched is in pod_inventory_audit_log with
-- reference_id LIKE 'drift-resync-%' (old_stock/new_stock/delta per row).
