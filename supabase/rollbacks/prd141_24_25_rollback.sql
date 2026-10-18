-- PRD-141 items 24/25 rollback: restore the row-level approve trigger (reject_plan_lines stays, harmless).
DROP TRIGGER IF EXISTS trg_refill_plan_output_approve_to_dispatch_stmt ON public.refill_plan_output;
CREATE TRIGGER trg_refill_plan_output_approve_to_dispatch AFTER UPDATE OF operator_status ON public.refill_plan_output
  FOR EACH ROW WHEN (((new.operator_status = 'approved'::text) AND (old.operator_status IS DISTINCT FROM 'approved'::text) AND (COALESCE(new.dispatched, false) = false)))
  EXECUTE FUNCTION trg_fire_dispatch_on_approval();
