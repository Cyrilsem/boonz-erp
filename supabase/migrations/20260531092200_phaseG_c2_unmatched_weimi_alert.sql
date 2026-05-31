-- PRD-015 Phase C / C2 (AC#9) — daily unmatched-WEIMI alert.
-- Scans v_live_shelf_stock for match_method='unmatched' on eligible machines and writes one
-- monitoring_alerts finding per distinct goods_name_raw (same general ledger the bug010 monitor
-- uses), deduped per day. Surfaces a physically-deployed-but-unmapped product within 24h instead
-- of two weeks. SECURITY DEFINER (writes monitoring_alerts); cron-context guard mirrors
-- cron_phantom_pod_alert. NOT YET APPLIED.

CREATE OR REPLACE FUNCTION public.cron_unmatched_weimi_alert()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id  uuid := (SELECT auth.uid());
  v_caller   text;
  v_inserted int := 0;
  v_distinct int := 0;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'cron_unmatched_weimi_alert', true);

  -- Cron-context guard: pg_cron/service_role (no auth.uid) proceeds; an authenticated caller
  -- must be manager-class.
  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_caller FROM public.user_profiles WHERE id = v_user_id;
    IF v_caller IS NULL OR v_caller NOT IN ('operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'cron_unmatched_weimi_alert: forbidden for role %', COALESCE(v_caller,'unknown');
    END IF;
  END IF;

  WITH unmatched AS (
    SELECT v.goods_name_raw,
           COUNT(DISTINCT v.machine_id)        AS machine_count,
           array_agg(DISTINCT v.machine_name)  AS machines
    FROM public.v_live_shelf_stock v
    WHERE v.match_method = 'unmatched'
      AND v.is_eligible_machine = true
      AND NULLIF(TRIM(v.goods_name_raw), '') IS NOT NULL
    GROUP BY v.goods_name_raw
  ),
  ins AS (
    INSERT INTO public.monitoring_alerts (source, severity, payload)
    SELECT 'unmatched_weimi_product', 'warning',
      jsonb_build_object(
        'goods_name_raw', u.goods_name_raw,
        'machine_count',  u.machine_count,
        'sample_machines', to_jsonb(u.machines),
        'action_needed', 'Physically deployed product has no name mapping. Add a product_name_conventions row (and product_mapping) so the engine can see the shelf.',
        'detected_at', now()
      )
    FROM unmatched u
    WHERE NOT EXISTS (
      SELECT 1 FROM public.monitoring_alerts a
      WHERE a.source = 'unmatched_weimi_product'
        AND a.payload->>'goods_name_raw' = u.goods_name_raw
        AND a.created_at::date = CURRENT_DATE
    )
    RETURNING 1
  )
  SELECT (SELECT COUNT(*) FROM ins), (SELECT COUNT(*) FROM unmatched)
  INTO v_inserted, v_distinct;

  RETURN jsonb_build_object(
    'status', 'ok',
    'distinct_unmatched', v_distinct,
    'inserted', v_inserted,
    'ran_at', now()
  );
END $function$;
GRANT EXECUTE ON FUNCTION public.cron_unmatched_weimi_alert() TO authenticated;

-- Daily schedule (03:15 UTC = 07:15 Dubai; clear of the 22:00/22:30 expiry crons).
SELECT cron.schedule('unmatched_weimi_alert_daily', '15 3 * * *',
  'SELECT public.cron_unmatched_weimi_alert();');
