-- P0 FIX14 (2026-07-12, CS): re-enable the swap engine globally now that its
-- substitute brain is rebuilt (p0_fix12 WEIMI identity + scoped drift skip,
-- p0_fix13 real deduped stock + volume-aware ranking + decommission guard).
-- Gate 1 still requires explicit operator approval of every proposed swap.
-- Rollback: UPDATE refill_settings SET setting_value='false'::jsonb WHERE setting_key='swaps_enabled';
UPDATE public.refill_settings
   SET setting_value = 'true'::jsonb, updated_at = now()
 WHERE setting_key = 'swaps_enabled';

INSERT INTO public.monitoring_alerts(source, severity, payload)
VALUES ('refill_settings','warning', jsonb_build_object(
  'title','swaps_enabled flipped false -> true (p0_fix14) after swap-engine rebuild; Gate 1 approval still gates every swap',
  'changed_at', now()));
