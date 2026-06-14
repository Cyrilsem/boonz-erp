-- PRD-030 step 3a: durable "warehouse confirmed packing" record.
-- Grain (machine_id, dispatch_date) — NOT machines_to_visit (planning artifact, plan_date).
-- Written only by confirm_machine_packed (DEFINER). RLS read-all, no authenticated write.
CREATE TABLE IF NOT EXISTS public.dispatch_pack_confirmation (
  machine_id    uuid        NOT NULL REFERENCES public.machines(machine_id),
  dispatch_date date        NOT NULL,
  confirmed_by  uuid,
  confirmed_at  timestamptz NOT NULL DEFAULT now(),
  reason        text,
  summary       jsonb,
  PRIMARY KEY (machine_id, dispatch_date)
);
ALTER TABLE public.dispatch_pack_confirmation ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS dpc_select_authenticated ON public.dispatch_pack_confirmation;
CREATE POLICY dpc_select_authenticated ON public.dispatch_pack_confirmation
  FOR SELECT TO authenticated USING (true);
DROP TRIGGER IF EXISTS audit_dispatch_pack_confirmation ON public.dispatch_pack_confirmation;
CREATE TRIGGER audit_dispatch_pack_confirmation
  AFTER INSERT OR UPDATE OR DELETE ON public.dispatch_pack_confirmation
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_write();
