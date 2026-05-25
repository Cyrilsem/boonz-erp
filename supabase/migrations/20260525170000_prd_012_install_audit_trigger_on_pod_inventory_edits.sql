-- PRD-012 Phase 3 closeout: install generic audit trigger on pod_inventory_edits.
-- Amendment 008 promoted pod_inventory_edits to Appendix A; this migration is
-- the commitment Cody flagged at amendment review (F2): without the trigger,
-- the canonical writers' app.via_rpc markers go nowhere.
-- Pattern mirrors tg_audit_pod_inventory installed by A.4.

DROP TRIGGER IF EXISTS tg_audit_pod_inventory_edits ON public.pod_inventory_edits;

CREATE TRIGGER tg_audit_pod_inventory_edits
  AFTER INSERT OR UPDATE OR DELETE ON public.pod_inventory_edits
  FOR EACH ROW EXECUTE FUNCTION audit_log_write('edit_id');
