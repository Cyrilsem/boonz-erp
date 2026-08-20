-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- RC-14 Tier 1b: same-day fix to a status value bug in cron_phantom_pod_alert() from
-- rc14t1_phantom_alert_self_heal (20260719100000). Per the comment baked into the live body
-- ("Allowed status values: open/dismissed/corrected"), the self-heal UPDATE originally used
-- a status value outside phantom_pod_alerts' allowed set and t1b corrected it to 'corrected'.
-- Superseded-in-place: this file reconstructs the SAME current live body as t1 (idempotent
-- CREATE OR REPLACE) because the pre-fix delta is not separable from live state alone --
-- applying this migration after t1 is a no-op re-apply, not a second distinct change.

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
