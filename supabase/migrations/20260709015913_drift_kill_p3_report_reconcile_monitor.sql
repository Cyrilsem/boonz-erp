-- drift-kill PHASE 3: row-level drift report + idempotent per-machine
-- reconcile RPC (dry-run first, RPC-only writes, no DELETEs - status
-- transitions and shelf moves only, all audited) + standing hourly monitor.
-- Dara-designed, Cody-reviewed (Articles 1,3,5,8,12; Am.005).

CREATE OR REPLACE VIEW public.v_weimi_slot_drift_report AS
WITH pod_rows AS (
  SELECT pi.pod_inventory_id, pi.machine_id, pi.shelf_id, pi.boonz_product_id,
         pi.current_stock, bp.boonz_product_name
  FROM pod_inventory pi
  JOIN boonz_products bp ON bp.product_id = pi.boonz_product_id
  WHERE pi.status = 'Active' AND pi.shelf_id IS NOT NULL
),
pod_checked AS (
  SELECT pr.*, ssi.pod_product_id AS weimi_pp_id, ssi.pod_product_name AS weimi_pod_name,
         ssi.shelf_code, ssi.machine_name, ssi.match_method,
         EXISTS (SELECT 1 FROM product_mapping pm
                  WHERE pm.boonz_product_id = pr.boonz_product_id
                    AND pm.pod_product_id = ssi.pod_product_id
                    AND pm.status = 'Active') AS maps_to_weimi
  FROM pod_rows pr
  JOIN v_shelf_slot_identity ssi ON ssi.machine_id = pr.machine_id AND ssi.shelf_id = pr.shelf_id
),
plano_checked AS (
  SELECT pg.planogram_id, pg.machine_id, pg.shelf_id, pg.pod_product_id,
         ssi.pod_product_id AS weimi_pp_id, ssi.pod_product_name AS weimi_pod_name,
         ssi.shelf_code, ssi.machine_name, ssi.match_method
  FROM planogram pg
  JOIN v_shelf_slot_identity ssi ON ssi.machine_id = pg.machine_id AND ssi.shelf_id = pg.shelf_id
  WHERE pg.is_active = true
)
SELECT 'pod_inventory' AS source, machine_id, machine_name, shelf_id, shelf_code,
       pod_inventory_id AS row_id, boonz_product_name AS row_product, weimi_pod_name, current_stock,
       CASE WHEN match_method = 'unmatched' OR weimi_pp_id IS NULL THEN 'weimi_unresolved'
            WHEN maps_to_weimi THEN 'ok' ELSE 'mismatch' END AS verdict
FROM pod_checked
UNION ALL
SELECT 'planogram', machine_id, machine_name, shelf_id, shelf_code,
       planogram_id, (SELECT pod_product_name FROM pod_products p WHERE p.pod_product_id = plano_checked.pod_product_id),
       weimi_pod_name, NULL,
       CASE WHEN match_method = 'unmatched' OR weimi_pp_id IS NULL THEN 'weimi_unresolved'
            WHEN pod_product_id = weimi_pp_id THEN 'ok' ELSE 'mismatch' END
FROM plano_checked;

COMMENT ON VIEW public.v_weimi_slot_drift_report IS
'drift-kill Phase 3 detector: every Active pod_inventory row (variant-aware via product_mapping) and active planogram row diffed against v_shelf_slot_identity (WEIMI truth). verdict: ok | mismatch | weimi_unresolved.';

CREATE OR REPLACE FUNCTION public.reconcile_shelf_identity_weimi(p_machine_id uuid, p_dry_run boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_role text;
  r RECORD;
  v_target uuid;
  v_target_n int;
  v_moved int := 0; v_archived int := 0; v_plano_off int := 0;
  v_actions jsonb := '[]'::jsonb;
BEGIN
  IF v_user IS NOT NULL THEN
    SELECT role INTO v_role FROM user_profiles WHERE id = v_user;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager','warehouse') THEN
      RAISE EXCEPTION 'reconcile_shelf_identity_weimi: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;
  IF p_machine_id IS NULL THEN RAISE EXCEPTION 'p_machine_id required'; END IF;

  PERFORM set_config('app.via_rpc','true', true);
  PERFORM set_config('app.rpc_name','reconcile_shelf_identity_weimi', true);
  PERFORM set_config('app.mutation_reason',
    format('drift-kill P3 reconcile machine=%s dry_run=%s by=%s', p_machine_id, p_dry_run, v_user), true);

  FOR r IN
    SELECT * FROM v_weimi_slot_drift_report
    WHERE machine_id = p_machine_id AND source = 'pod_inventory' AND verdict = 'mismatch'
  LOOP
    SELECT ssi.shelf_id, count(*) OVER () INTO v_target, v_target_n
    FROM v_shelf_slot_identity ssi
    JOIN product_mapping pm ON pm.pod_product_id = ssi.pod_product_id AND pm.status='Active'
    JOIN pod_inventory pi ON pi.pod_inventory_id = r.row_id AND pm.boonz_product_id = pi.boonz_product_id
    WHERE ssi.machine_id = p_machine_id AND ssi.match_method <> 'unmatched'
    LIMIT 1;

    IF v_target IS NOT NULL AND v_target_n = 1 THEN
      IF NOT p_dry_run THEN
        UPDATE pod_inventory SET shelf_id = v_target WHERE pod_inventory_id = r.row_id AND status='Active';
      END IF;
      v_moved := v_moved + 1;
      v_actions := v_actions || jsonb_build_object('action','move','row_id',r.row_id,
        'product',r.row_product,'from_shelf',r.shelf_code,'to_shelf_id',v_target,'stock',r.current_stock);
    ELSE
      IF NOT p_dry_run THEN
        UPDATE pod_inventory SET status = 'Inactive' WHERE pod_inventory_id = r.row_id AND status='Active';
      END IF;
      v_archived := v_archived + 1;
      v_actions := v_actions || jsonb_build_object('action','archive','row_id',r.row_id,
        'product',r.row_product,'shelf',r.shelf_code,'stock',r.current_stock,
        'reason', CASE WHEN v_target IS NULL THEN 'no_weimi_home_on_machine' ELSE 'ambiguous_multiple_homes' END);
    END IF;
    v_target := NULL; v_target_n := NULL;
  END LOOP;

  FOR r IN
    SELECT * FROM v_weimi_slot_drift_report
    WHERE machine_id = p_machine_id AND source = 'planogram' AND verdict = 'mismatch'
  LOOP
    IF NOT p_dry_run THEN
      UPDATE planogram SET is_active = false WHERE planogram_id = r.row_id AND is_active = true;
    END IF;
    v_plano_off := v_plano_off + 1;
    v_actions := v_actions || jsonb_build_object('action','planogram_deactivate','row_id',r.row_id,
      'row_product',r.row_product,'shelf',r.shelf_code,'weimi_product',r.weimi_pod_name);
  END LOOP;

  IF NOT p_dry_run AND (v_moved + v_archived + v_plano_off) > 0 THEN
    INSERT INTO monitoring_alerts (source, severity, payload)
    VALUES ('drift_kill_reconcile','warning', jsonb_build_object(
      'title', format('reconciled slot identity: machine %s (%s moved, %s archived, %s planogram off)', p_machine_id, v_moved, v_archived, v_plano_off),
      'machine_id', p_machine_id, 'actions', v_actions, 'by', v_user, 'at', now()));
  END IF;

  RETURN jsonb_build_object('status','ok','dry_run',p_dry_run,'machine_id',p_machine_id,
    'moved',v_moved,'archived',v_archived,'planogram_deactivated',v_plano_off,'actions',v_actions);
END;
$function$;

COMMENT ON FUNCTION public.reconcile_shelf_identity_weimi(uuid, boolean) IS
'drift-kill Phase 3 repair writer (THE canonical reconcile; no raw writes elsewhere). Per machine, idempotent, dry-run default: mismatched Active pod_inventory rows MOVE to their unique WEIMI home shelf else ARCHIVE (status Inactive, reversible, never deleted); mismatched active planogram rows deactivate. All actions audited (write_audit_log) + summarized to monitoring_alerts. Articles 1,3,5,8,12; Am.005.';

CREATE OR REPLACE FUNCTION public.monitor_weimi_slot_drift()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_n int; v_breakdown jsonb;
BEGIN
  SELECT count(*), jsonb_agg(DISTINCT machine_name) INTO v_n, v_breakdown
  FROM v_weimi_slot_drift_report WHERE verdict = 'mismatch';
  IF v_n > 0 AND NOT EXISTS (
       SELECT 1 FROM monitoring_alerts
       WHERE source='weimi_slot_drift_monitor' AND created_at > now() - interval '6 hours'
         AND (payload->>'mismatch_rows')::int = v_n) THEN
    INSERT INTO monitoring_alerts (source, severity, payload)
    VALUES ('weimi_slot_drift_monitor','warning', jsonb_build_object(
      'title', format('%s slot-identity drift rows fleet-wide', v_n),
      'mismatch_rows', v_n, 'machines', v_breakdown, 'detected_at', now(),
      'hint','v_weimi_slot_drift_report has the rows; reconcile_shelf_identity_weimi(machine_id, dry_run) repairs'));
  END IF;
  RETURN jsonb_build_object('mismatch_rows', v_n, 'machines', v_breakdown);
END;
$function$;

SELECT cron.schedule('drift_kill_slot_monitor', '15 * * * *', $$SELECT public.monitor_weimi_slot_drift()$$);