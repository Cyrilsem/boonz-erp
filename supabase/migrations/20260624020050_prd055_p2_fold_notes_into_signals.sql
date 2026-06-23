-- PRD-055 P2: fold field notes + operational tracker entries into refill_edit_signals (Signals).
-- Idempotent (origin tag [mfn:id]/[at:id] + NOT EXISTS guard). NO deletes: source rows kept.
-- All folded rows signal_type='note' -> inert to engine_swap_pod (reads only swap_rejected).
-- machine_field_notes (6) -> source='field_note'; action_tracker driver_feedback (50) -> source='action'.
-- bug/task/decommission (42) stay in v_action_tracker_issues (not folded). CS-confirmed split.

INSERT INTO public.refill_edit_signals (plan_date, machine_id, shelf_id, pod_product_id, signal_type, source, note, created_by, created_at)
SELECT COALESCE(mfn.applied_to_plan_date, mfn.noted_at::date, CURRENT_DATE), mfn.machine_id,
  (SELECT sc.shelf_id FROM public.shelf_configurations sc WHERE sc.machine_id=mfn.machine_id AND sc.shelf_code=mfn.shelf_code LIMIT 1),
  (SELECT pp.pod_product_id FROM public.pod_products pp WHERE pp.pod_product_name=mfn.pod_product_name LIMIT 1),
  'note','field_note','[mfn:'||mfn.note_id||'] '||COALESCE(mfn.note_text,''), mfn.noted_by, COALESCE(mfn.noted_at, now())
FROM public.machine_field_notes mfn
WHERE NOT EXISTS (SELECT 1 FROM public.refill_edit_signals s WHERE s.source='field_note' AND s.note LIKE '[mfn:'||mfn.note_id||']%');

INSERT INTO public.refill_edit_signals (plan_date, machine_id, signal_type, source, note, created_at)
SELECT COALESCE(at.created_at::date, CURRENT_DATE), (SELECT m.machine_id FROM public.machines m WHERE m.official_name=at.machine_name LIMIT 1),
  'note','action','[at:'||at.action_id||'] '||COALESCE(at.title, at.description, ''), COALESCE(at.created_at, now())
FROM public.action_tracker at
WHERE at.type='driver_feedback'
  AND NOT EXISTS (SELECT 1 FROM public.refill_edit_signals s WHERE s.source='action' AND s.note LIKE '[at:'||at.action_id||']%');

UPDATE public.machine_field_notes
SET resolution_note = COALESCE(resolution_note,'') || ' [migrated->refill_edit_signals PRD-055]'
WHERE COALESCE(resolution_note,'') NOT LIKE '%migrated->refill_edit_signals PRD-055%';
