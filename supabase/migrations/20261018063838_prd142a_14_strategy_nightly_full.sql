-- PRD-142a: the 03:30 Dubai nightly job now runs the whole strategy chain:
-- eras, facts, machine features, supply, archetypes, machine posture proposals,
-- product playbook and product posture proposals. Each step isolated; run
-- logged to monitoring_alerts. Same cron job (prd142_strategy_nightly_0330_dubai).

CREATE OR REPLACE FUNCTION public.run_strategy_nightly()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '900s'
AS $$
DECLARE
  v_t0  timestamptz := clock_timestamp();
  v_out jsonb := '{}'::jsonb;
  v_err text;
  v_step text;
BEGIN
  FOREACH v_step IN ARRAY ARRAY['sync_machine_eras', 'build_strategy_facts', 'build_machine_features', 'build_product_supply',
                                'assign_machine_archetypes', 'propose_machine_postures', 'build_product_playbook'] LOOP
    BEGIN
      v_out := v_out || jsonb_build_object(v_step,
        CASE v_step
          WHEN 'sync_machine_eras' THEN sync_machine_eras()
          WHEN 'build_strategy_facts' THEN build_strategy_facts(NULL)
          WHEN 'build_machine_features' THEN build_machine_features(NULL)
          WHEN 'build_product_supply' THEN build_product_supply(NULL)
          WHEN 'assign_machine_archetypes' THEN assign_machine_archetypes(NULL)
          WHEN 'propose_machine_postures' THEN propose_machine_postures(NULL)
          WHEN 'build_product_playbook' THEN build_product_playbook(NULL)
        END);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      v_out := v_out || jsonb_build_object(v_step, jsonb_build_object('error', v_err));
    END;
  END LOOP;

  v_out := v_out || jsonb_build_object('total_seconds', round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 2));
  INSERT INTO monitoring_alerts (source, severity, payload, acknowledged)
  VALUES ('prd142_strategy_nightly',
          CASE WHEN v_out::text LIKE '%"error"%' THEN 'warning' ELSE 'info' END,
          v_out,
          v_out::text NOT LIKE '%"error"%');
  RETURN v_out;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.run_strategy_nightly() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.run_strategy_nightly() TO service_role;

-- PRD-140 access model: /app/strategy for operator_admin and superadmin only.
INSERT INTO public.access_areas (key, surface, label, route_prefix, sidebar_label, sort)
VALUES ('app.strategy', 'app', 'Strategy', '/app/strategy', 'Strategy', 25)
ON CONFLICT (key) DO NOTHING;
INSERT INTO public.role_area_defaults (role, area_key)
VALUES ('operator_admin', 'app.strategy'), ('superadmin', 'app.strategy')
ON CONFLICT DO NOTHING;
