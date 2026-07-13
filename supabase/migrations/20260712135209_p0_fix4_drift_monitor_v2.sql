-- P0 FIX4 (2026-07-12, Cody-approved): cron_slot_binding_drift_alert v2.
-- Adds WEIMI-unresolved-but-bound slots (blind spot of v_slot_binding_drift),
-- fixes stale 'plan will HALT' text (obsolete once FIX2 lands: engine now
-- hard-skips drifted shelves instead of halting). cron.job 39 calls this by
-- name at 30 1 * * * — no cron change needed (Article 11).
CREATE OR REPLACE FUNCTION public.cron_slot_binding_drift_alert()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
DECLARE v_n int; v_rows jsonb; v_unres int; v_unres_rows jsonb;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','cron_slot_binding_drift_alert',true);
  -- hard mismatches (identity drift)
  SELECT COUNT(*), COALESCE(jsonb_agg(jsonb_build_object(
           'machine_id', machine_id, 'shelf_code', shelf_code,
           'lifecycle_product', lifecycle_product, 'weimi_product', weimi_product,
           'goods_name_raw', goods_name_raw)), '[]'::jsonb)
    INTO v_n, v_rows
  FROM public.v_slot_binding_drift;
  -- WEIMI-unresolved slots that carry a current lifecycle binding (blind spot of the view)
  SELECT COUNT(*), COALESCE(jsonb_agg(jsonb_build_object(
           'machine_name', ssi.machine_name, 'shelf_code', ssi.shelf_code,
           'goods_name_raw', ssi.goods_name_raw, 'match_method', ssi.match_method)), '[]'::jsonb)
    INTO v_unres, v_unres_rows
  FROM public.v_shelf_slot_identity ssi
  JOIN public.slot_lifecycle sl
    ON sl.machine_id = ssi.machine_id AND sl.shelf_id = ssi.shelf_id
   AND sl.archived = false AND sl.is_current = true
  WHERE ssi.pod_product_id IS NULL OR ssi.match_method = 'unmatched';
  IF v_n > 0 OR v_unres > 0 THEN
    INSERT INTO public.monitoring_alerts(source, severity, payload)
    VALUES ('slot_binding_drift',
            CASE WHEN v_n > 0 THEN 'critical' ELSE 'warning' END,
            jsonb_build_object(
              'title', format('%s slot binding drift row(s), %s WEIMI-unresolved bound slot(s): drifted shelves are HARD-SKIPPED by engine_add_pod (clamp_reason=binding_drift) and REJECTED by weimi_slot_guard block mode', v_n, v_unres),
              'drift_rows', v_rows, 'unresolved_rows', v_unres_rows,
              'detected_by','cron_slot_binding_drift_alert_v2','detected_at', now()));
  END IF;
  RETURN jsonb_build_object('status','ok','drift_rows',v_n,'weimi_unresolved_bound',v_unres);
END; $fn$;
