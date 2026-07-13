-- P0 FIX1 (2026-07-12, Cody-approved): flip weimi_slot_guard warn -> block.
-- Guard verified row-scoped: rejects only mismatched refill_plan_output rows
-- (operator_status='rejected', dispatched=false only), never raises, never
-- touches sibling rows. Rollback: SET weimi_slot_guard='warn' WHERE id=1.
UPDATE public.refill_policy_params
   SET weimi_slot_guard = 'block'
 WHERE id = 1
   AND weimi_slot_guard IS DISTINCT FROM 'block';

INSERT INTO public.monitoring_alerts(source, severity, payload)
VALUES ('weimi_slot_guard','warning', jsonb_build_object(
  'title','weimi_slot_guard mode flipped warn -> block via migration p0_fix1 (incident 2026-07-12 slot binding drift)',
  'changed_at', now()));
