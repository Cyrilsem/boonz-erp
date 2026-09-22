-- PRD-130 step 11 rollback. NOT APPLIED -- reference only. Restoring this recreates the bug
-- (add_intra_machine_move cannot insert). Only roll back if F5 is being reverted too.

ALTER TABLE public.refill_dispatching DROP CONSTRAINT refill_dispatching_source_kind_chk;

ALTER TABLE public.refill_dispatching
  ADD CONSTRAINT refill_dispatching_source_kind_chk
  CHECK (source_kind = ANY (ARRAY['wh','venue','m2m','truck_transfer','unknown']));
