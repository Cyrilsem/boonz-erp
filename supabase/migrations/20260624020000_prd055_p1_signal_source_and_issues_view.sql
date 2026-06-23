-- PRD-055 P1: make Signals (refill_edit_signals) the single notes channel.
-- (a) refill_edit_signals.source is FREE TEXT (no CHECK) -> the new convention values
--     'field_note' (from machine_field_notes) and 'action' (from action_tracker operational
--     entries) are usable directly; no DDL needed for source.
-- (b) Migrated notes are not edit events, but signal_type has a CHECK. Extend it with a neutral
--     'note' value so migrated rows are valid AND inert: engine_swap_pod reads refill_edit_signals
--     ONLY where signal_type='swap_rejected' (verified), so signal_type='note' rows never affect
--     scoring. engine_swap_pod stays byte-identical (md5 90f26896ba7e0a7099fa689e73eaab91).
--     Forward CHECK replacement (drop+add; cannot ALTER a CHECK in place). No row violates it
--     ('note' is new). delta CHECK unchanged (delta only required for qty_raised/qty_lowered).
-- (c) Read-only Issues board view over action_tracker for CS (genuine bugs/actions kept, NOT folded
--     into the engine signal stream). Excludes 'driver_feedback' (those fold into Signals in P2).
-- Cody: Art 1 (read-only view), Art 12 (forward-only), Art 16 n/a. No engine logic change.

ALTER TABLE public.refill_edit_signals DROP CONSTRAINT refill_edit_signals_signal_type_check;
ALTER TABLE public.refill_edit_signals ADD CONSTRAINT refill_edit_signals_signal_type_check
  CHECK (signal_type = ANY (ARRAY['qty_raised','qty_lowered','item_added','item_removed','swap_rejected','note']));

CREATE OR REPLACE VIEW public.v_action_tracker_issues
WITH (security_invoker = true) AS
 SELECT action_id, type, title, description, machine_name, status, priority,
        assignee, due_date, source, created_at, updated_at, resolved_at
   FROM public.action_tracker
  WHERE type <> 'driver_feedback'   -- driver_feedback folds into Signals (source='action'); the rest is the kept issues/actions board
  ORDER BY (status = 'open') DESC, priority NULLS LAST, created_at DESC;

COMMENT ON VIEW public.v_action_tracker_issues IS
  'PRD-055: kept read-only issues/actions board (action_tracker minus driver_feedback). For CS; NOT folded into refill_edit_signals / engine_swap_pod. security_invoker.';

GRANT SELECT ON public.v_action_tracker_issues TO authenticated;
