-- Rollback for PRD-137 F1 (auto-pickup for lines packed after mark_picked_up, 2026-09-29/30).
-- Drops the two triggers and the trigger function this migration added. Does NOT undo the
-- one-time backfill UPDATE in the migration (that corrected ~25 old, already-delivered
-- historical rows to match physical reality; reverting it would reintroduce a known-false state
-- and serves no purpose).
DROP TRIGGER IF EXISTS trg_auto_pickup_on_insert ON public.refill_dispatching;
DROP TRIGGER IF EXISTS trg_auto_pickup_on_pack ON public.refill_dispatching;
DROP FUNCTION IF EXISTS public.tg_auto_pickup_after_first_pickup();
