-- backported from prod schema_migrations on 2026-07-18, RC-15 parity
-- version: 20260716093730  name: audit_product_mapping_writes
-- Audit trail for product_mapping (canonical for procurement splits + stitching).
-- Incident 2026-07-13 01:33:08 UTC: a 4,280-row bulk status deactivation left
-- ZERO trace because this table was the only major write target with no audit
-- trigger. Wire the existing shared audit_log_write() AFTER trigger (same one
-- on refill_dispatching etc.), keyed on the PK mapping_id. Captures actor,
-- actor_role, via_rpc, rpc_name and full old/new row images to write_audit_log
-- on every INSERT/UPDATE/DELETE. Additive + observational: cannot block writes,
-- no RLS change, no function replacement. Rollback: DROP TRIGGER tg_audit_product_mapping.
CREATE TRIGGER tg_audit_product_mapping
AFTER INSERT OR UPDATE OR DELETE ON public.product_mapping
FOR EACH ROW EXECUTE FUNCTION public.audit_log_write('mapping_id');
