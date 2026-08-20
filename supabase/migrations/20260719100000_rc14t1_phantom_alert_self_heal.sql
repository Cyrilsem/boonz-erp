-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- RC-14 Tier 1: introduces cron_phantom_pod_alert(), which (a) opens a phantom_pod_alerts row
-- for each v_phantom_pod_rows candidate not already open, and (b) self-heals: closes any
-- 'open' alert whose underlying phantom condition has since cleared (status -> 'corrected').
-- Manager-class role gate (operator_admin/superadmin/manager) for authenticated callers;
-- null-uid (cron/service_role) context proceeds. NOTE: the body below is the CURRENT live
-- body, which already includes the same-day status-value fix from rc14t1b
-- (20260719100100_rc14t1b_phantom_alert_status_value_fix) -- the two migrations cannot be
-- disentangled from live state alone, so both files carry this identical cumulative body.

CREATE OR REPLACE FUNCTION public.cron_phantom_pod_alert()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id   uuid := (SELECT auth.uid());
  v_caller    text;
  v_inserted  integer := 0;
  v_skipped   integer := 0;
  v_closed    integer := 0;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'cron_phantom_pod_alert', true);

  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_caller FROM public.user_profiles WHERE id = v_user_id;
    IF v_caller IS NULL OR v_caller NOT IN ('operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'cron_phantom_pod_alert: forbidden for role %', COALESCE(v_caller,'unknown');
    END IF;
  END IF;

  WITH ins AS (
    INSERT INTO public.phantom_pod_alerts (
      pod_inventory_id, machine_id, boonz_product_id,
      current_stock, days_silent
    )
    SELECT v.pod_inventory_id, v.machine_id, v.boonz_product_id,
           v.current_stock, v.days_silent
    FROM public.v_phantom_pod_rows v
    WHERE NOT EXISTS (
      SELECT 1 FROM public.phantom_pod_alerts a
      WHERE a.pod_inventory_id = v.pod_inventory_id
        AND a.status = 'open'
    )
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_inserted FROM ins;

  SELECT COUNT(*) INTO v_skipped FROM public.v_phantom_pod_rows v
  WHERE EXISTS (
    SELECT 1 FROM public.phantom_pod_alerts a
    WHERE a.pod_inventory_id = v.pod_inventory_id
      AND a.status = 'open'
  );

  -- self-heal: close cleared phantoms. Allowed status values: open/dismissed/corrected.
  WITH closed AS (
    UPDATE public.phantom_pod_alerts a
       SET status = 'corrected',
           resolved_at = now(),
           resolution_note = COALESCE(a.resolution_note,'')
                             || ' [auto: phantom condition cleared ' || now()::date || ']'
     WHERE a.status = 'open'
       AND NOT EXISTS (
         SELECT 1 FROM public.v_phantom_pod_rows v
         WHERE v.pod_inventory_id = a.pod_inventory_id
       )
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_closed FROM closed;

  RETURN jsonb_build_object(
    'status', 'ok',
    'inserted', v_inserted,
    'skipped_already_open', v_skipped,
    'closed', v_closed,
    'ran_at', now()
  );
END;
$function$;
