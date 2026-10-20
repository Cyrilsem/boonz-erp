-- PRD-142b 5.5 item 1: refill_settings flags, the flag helper and v_machine_posture_params.
-- Flags (created here, flipped by CS): prd142_fill_depth_enabled false, prd142_swap_mode_enabled false,
-- prd142_swap_guard_enabled true, prd142_picker_multiplier_enabled false, prd142_procurement_posture_enabled true.
-- posture_applies = a CS-confirmed posture other than PROTECT_GROW. PROTECT_GROW is today's behaviour (5.5 item 1),
-- and every machine without a confirmed posture reads PROTECT_GROW defaults of its population, so engine hooks
-- that key on posture_applies leave those machines exactly as today.

INSERT INTO public.refill_settings (setting_key, setting_value, updated_at) VALUES
  ('prd142_fill_depth_enabled', 'false'::jsonb, now()),
  ('prd142_swap_mode_enabled', 'false'::jsonb, now()),
  ('prd142_swap_guard_enabled', 'true'::jsonb, now()),
  ('prd142_picker_multiplier_enabled', 'false'::jsonb, now()),
  ('prd142_procurement_posture_enabled', 'true'::jsonb, now())
ON CONFLICT (setting_key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.prd142_setting_on(p_key text, p_default boolean)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT COALESCE((SELECT rs.setting_value = 'true'::jsonb FROM refill_settings rs WHERE rs.setting_key = p_key), p_default)
$$;
REVOKE EXECUTE ON FUNCTION public.prd142_setting_on(text, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.prd142_setting_on(text, boolean) TO authenticated, service_role;

CREATE OR REPLACE VIEW public.v_machine_posture_params WITH (security_invoker = true) AS
SELECT m.machine_id,
       m.official_name,
       strategy_population(m.venue_group, m.official_name) AS population,
       COALESCE(c.posture, 'PROTECT_GROW') AS posture,
       (c.posture IS NOT NULL) AS confirmed,
       (c.posture IS NOT NULL AND c.posture <> 'PROTECT_GROW') AS posture_applies,
       COALESCE(d.params, '{}'::jsonb) || COALESCE(c.params, '{}'::jsonb) AS params,
       COALESCE(c.shelf_overrides, '[]'::jsonb) AS shelf_overrides,
       c.archetype_code
FROM public.machines m
LEFT JOIN LATERAL (
  SELECT s.posture, s.params, s.shelf_overrides, s.archetype_code
  FROM public.machine_strategy s
  WHERE s.machine_id = m.machine_id AND s.confirmed_at IS NOT NULL AND s.posture IS NOT NULL
) c ON true
LEFT JOIN public.strategy_posture_defaults d
  ON d.posture = COALESCE(c.posture, 'PROTECT_GROW')
 AND d.population = strategy_population(m.venue_group, m.official_name);
REVOKE ALL ON public.v_machine_posture_params FROM anon;
GRANT SELECT ON public.v_machine_posture_params TO authenticated, service_role;
