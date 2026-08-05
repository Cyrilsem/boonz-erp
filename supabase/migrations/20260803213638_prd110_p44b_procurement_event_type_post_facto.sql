-- PRD-110 P4.4b Migration B (part 2) — admit the post-facto fill event type.
--
-- Found by the leg's own rolled-back happy-path probe, not by reading source:
-- procurement_events.event_type is CHECK-constrained and the phase-1 write was
-- rejected. ⛔ The tempting fix - reuse 'spot_purchase_created' - would make a
-- post-facto fill INDISTINGUISHABLE from a P4.4 warehouse spot buy in the
-- procurement log, and the two are materially different: one receives into a
-- warehouse, the other puts goods straight on a shelf and leaves them
-- financially unreceived until phase 2. Any consumer filtering on
-- 'spot_purchase_created' would silently absorb them.
--
-- Widening a CHECK is additive: every existing row already satisfies the new
-- predicate, and no row that was legal becomes illegal.
ALTER TABLE public.procurement_events
  DROP CONSTRAINT procurement_events_event_type_check;

ALTER TABLE public.procurement_events
  ADD CONSTRAINT procurement_events_event_type_check
  CHECK (event_type = ANY (ARRAY[
    'po_created','po_line_edited','lines_appended',
    'task_assigned','task_acknowledged','task_collected','task_cancelled',
    'task_pending','task_reopened',
    'goods_received','line_not_purchased',
    'spot_purchase_created','spot_purchase_task_autoclosed',
    -- PRD-110 P4.4b 2026-08-04: goods bought at a counter and put straight on a
    -- shelf; financially unreceived until receive_spot_fill_po_v3 closes the chain.
    'post_facto_fill_recorded']));
