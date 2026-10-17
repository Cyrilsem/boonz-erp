-- PRD-142a: nightly strategy job, 03:30 Dubai (23:30 UTC).
-- Outside 20:00 to 23:00 Dubai (cron 13 and the draft build) and outside
-- PRD-141's night-window writes. Read-only toward every engine object: it
-- writes only PRD-142a tables. Each step is isolated so one failure does not
-- block the rest; the run is logged to monitoring_alerts as a
-- pre-acknowledged info row (a log, not an ack gate). Later PRD-142a items
-- extend run_strategy_nightly() with archetypes, proposals and product
-- strategy.

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
  FOREACH v_step IN ARRAY ARRAY['sync_machine_eras', 'build_strategy_facts', 'build_machine_features', 'build_product_supply'] LOOP
    BEGIN
      v_out := v_out || jsonb_build_object(v_step,
        CASE v_step
          WHEN 'sync_machine_eras' THEN sync_machine_eras()
          WHEN 'build_strategy_facts' THEN build_strategy_facts(NULL)
          WHEN 'build_machine_features' THEN build_machine_features(NULL)
          WHEN 'build_product_supply' THEN build_product_supply(NULL)
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

SELECT cron.schedule('prd142_strategy_nightly_0330_dubai', '30 23 * * *', $cron$SELECT public.run_strategy_nightly();$cron$);
