-- PRD-022 D3b follow-up — allow the 'lines_appended' event_type on procurement_events.
-- Migration name: prd022_d3b_widen_proc_event_type
-- Article 12 (forward-only). Companion to prd022_d3b_add_purchase_order_lines, whose audit
-- writes event_type='lines_appended' (the existing CHECK constraint did not permit it).
-- Same widen pattern as phaseF_proc_events_widen_event_type_check.

ALTER TABLE public.procurement_events
  DROP CONSTRAINT IF EXISTS procurement_events_event_type_check;

ALTER TABLE public.procurement_events
  ADD CONSTRAINT procurement_events_event_type_check
  CHECK (event_type = ANY (ARRAY[
    'po_created'::text,
    'po_line_edited'::text,
    'lines_appended'::text,
    'task_assigned'::text,
    'task_acknowledged'::text,
    'task_collected'::text,
    'task_cancelled'::text,
    'task_pending'::text,
    'task_reopened'::text,
    'goods_received'::text,
    'line_not_purchased'::text
  ]));
