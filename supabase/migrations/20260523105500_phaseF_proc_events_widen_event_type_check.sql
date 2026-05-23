-- PRD-001 follow-up — widen procurement_events.event_type CHECK to include 'po_line_edited'.
-- Required because the preceding migration (phaseF_proc_edit_po_line_audit) writes this event_type
-- but the existing CHECK constraint enumerated only the pre-PRD-001 vocabulary.
-- Article 12: forward-only DDL — drop then re-add the constraint with the extended value list.

ALTER TABLE public.procurement_events
  DROP CONSTRAINT IF EXISTS procurement_events_event_type_check;

ALTER TABLE public.procurement_events
  ADD CONSTRAINT procurement_events_event_type_check
  CHECK (event_type = ANY (ARRAY[
    'po_created'::text,
    'po_line_edited'::text,
    'task_assigned'::text,
    'task_acknowledged'::text,
    'task_collected'::text,
    'task_cancelled'::text,
    'task_pending'::text,
    'task_reopened'::text,
    'goods_received'::text,
    'line_not_purchased'::text
  ]));
