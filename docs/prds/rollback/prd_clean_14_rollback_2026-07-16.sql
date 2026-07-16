-- Rollback for PRD-CLEAN-14 (2026-07-16). Nothing was replaced — the trigger and its
-- function are NEW objects. Full removal:
DROP TRIGGER IF EXISTS trg_rebind_slot_on_add_confirm ON public.refill_dispatching;
DROP FUNCTION IF EXISTS public.tg_rebind_slot_lifecycle_on_add_confirm();
