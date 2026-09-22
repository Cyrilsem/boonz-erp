-- PRD-130 emergency fix #2, found while testing PRD-131 F1 draft (not asked for by any PRD).
-- refill_dispatching_source_kind_chk (fully VALIDATED, enforced on every row) allows only
-- wh/venue/m2m/truck_transfer/unknown. It was never widened for 'intra_machine' when prd130_05
-- (add_intra_machine_move) shipped this morning -- unlike refill_dispatching_source_consistency_chk,
-- which already had an intra_machine branch (confirmed separately). Any real call to
-- add_intra_machine_move has therefore failed on its very first INSERT since ~05:59 UTC today,
-- every time, with no successful row ever created. Confirmed with a rolled-back probe INSERT
-- before this fix (23514 violates refill_dispatching_source_kind_chk); confirmed fixed with the
-- same probe after.
--
-- Purely additive (existing rows already satisfy the constraint on the other five values), so
-- this is not the historical-row landmine class of change -- safe to apply now, daytime, not
-- gated (a CHECK constraint widening on refill_dispatching, not one of the named gated
-- functions).

ALTER TABLE public.refill_dispatching DROP CONSTRAINT refill_dispatching_source_kind_chk;

ALTER TABLE public.refill_dispatching
  ADD CONSTRAINT refill_dispatching_source_kind_chk
  CHECK (source_kind = ANY (ARRAY['wh','venue','m2m','truck_transfer','unknown','intra_machine']));
