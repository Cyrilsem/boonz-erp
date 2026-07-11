-- PRD-CLEAN-07: config single pane + graveyard of the two dead config tables.
-- Folding of refill_policy_params (readers: engine_add_pod, assert_weimi_slot_match)
-- and refill_settings (readers: engine_swap_pod, set_swaps_enabled,
-- sweep_expired_inventory) DEFERRED - their readers are live pipeline-critical
-- functions; patching them for a P3 convenience repeats the Wave-1/2 failure mode.
CREATE OR REPLACE VIEW public.v_refill_config AS
SELECT 'pick_urgency_params'::text AS source_table, j.key AS param, j.value AS value
FROM public.pick_urgency_params t, LATERAL jsonb_each_text(to_jsonb(t)) j
UNION ALL
SELECT 'refill_policy_params', j.key, j.value
FROM public.refill_policy_params t, LATERAL jsonb_each_text(to_jsonb(t)) j
UNION ALL
SELECT 'refill_settings', s.setting_key, s.setting_value::text
FROM public.refill_settings s;

COMMENT ON VIEW public.v_refill_config IS
'PRD-CLEAN-07: read-only single pane over the live engine configuration (long format: source_table, param, value). Tables covered: pick_urgency_params (picker urgency tuner), refill_policy_params (base-stock sizing tuner), refill_settings (feature flags). refill_priority_params and service_priority_params were dead (0 readers) and moved to graveyard 2026-07-11.';

-- dead config tables (0 functions, 0 FE, 0 cron readers; v_machine_service_priority
-- itself had 0 consumers) -> graveyard, reversible
ALTER TABLE public.refill_priority_params SET SCHEMA graveyard;
ALTER TABLE public.service_priority_params SET SCHEMA graveyard;
ALTER VIEW public.v_machine_service_priority SET SCHEMA graveyard;
