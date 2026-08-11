-- PRD-003 — procurement_events.event_type is a closed CHECK enum. The three new domain events
-- must be admitted or every set_po_document_totals call and every mirrored addition raises 23514.
-- Caught by the T1 dry-run before merge; without this the first receive after deploy would fail.
--
-- Article 12: forward-only WIDENING. No existing value is removed, so no historical row can be
-- invalidated. The constraint is re-created rather than edited in place (Postgres has no
-- ALTER CONSTRAINT for CHECK), which is the ordinary idiom, not a destructive rewrite.
ALTER TABLE public.procurement_events
  DROP CONSTRAINT IF EXISTS procurement_events_event_type_check;

ALTER TABLE public.procurement_events
  ADD CONSTRAINT procurement_events_event_type_check CHECK (event_type = ANY (ARRAY[
    'po_created','po_line_edited','lines_appended',
    'task_assigned','task_acknowledged','task_collected','task_cancelled','task_pending','task_reopened',
    'goods_received','line_not_purchased',
    'spot_purchase_created','spot_purchase_task_autoclosed',
    'post_facto_fill_recorded','post_facto_fill_received',
    -- PRD-003
    'po_totals_set',              -- document totals captured for the first time
    'po_totals_edited',           -- post-receipt correction, reason >= 10 chars
    'po_addition_line_mirrored'   -- addition mirrored into a real purchase_orders line.
                                  -- Deliberately DISTINCT from 'goods_received': this event
                                  -- creates NO warehouse batch and must never be read as a
                                  -- second warehouse credit (Article 6, C-8).
  ]));
