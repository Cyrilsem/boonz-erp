-- PRD-065 B2 — sweep_expired_inventory + sweep flag.
-- HELD (calls pod + warehouse write-offs; cron HELD separately). Apply on CS green light.
-- Dara/Cody: walks v_expired_inventory.
--   zero_stock_residual -> auto write-off: pod via backfill_archive_pod_inventory_row (the 12+8 we
--     cleared by hand on 29 Jun), warehouse via warehouse_expire_writeoff (B4).
--   stock_bearing pod -> queue a PENDING 'expired' pod_inventory_edits row (recheck_source='system')
--     = the existing review-queue mechanism; the driver confirms removal and B3 approves (write-off,
--     no WH credit). stock_bearing warehouse -> flagged only (manager handles via B4).
-- Expired = loss, never a WH credit. Idempotent (write-offs no-op if already done; queue skips if a
-- pending expired edit already exists). FLAG-GATED: live writes require refill_settings.sweep_enabled
-- = true; p_dry_run = true always allowed (report only). Caller gated to superadmin/operator_admin
-- (backfill_archive requires it). pg_cron is a SEPARATE held step, enabled only after a clean dry-run.

-- sweep on/off flag (default OFF), in the established refill_settings KV store (like swaps_enabled)
INSERT INTO public.refill_settings (setting_key, setting_value)
VALUES ('sweep_enabled', 'false'::jsonb)
ON CONFLICT (setting_key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.sweep_expired_inventory(
  p_dry_run   boolean DEFAULT true,
  p_caller_id uuid    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_user_id uuid := COALESCE(p_caller_id, auth.uid());
  v_role    text;
  v_enabled boolean;
  r         record;
  v_cleared_pod int := 0;
  v_cleared_wh  int := 0;
  v_queued_pod  int := 0;
  v_flagged_wh  int := 0;
  v_skipped     int := 0;
  v_details jsonb := '[]'::jsonb;
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_role IS NULL OR v_role NOT IN ('superadmin','operator_admin') THEN
    RAISE EXCEPTION 'sweep_expired_inventory: forbidden for role % (superadmin/operator_admin required)', COALESCE(v_role,'unknown');
  END IF;

  SELECT COALESCE((setting_value)::text::boolean, false) INTO v_enabled
  FROM public.refill_settings WHERE setting_key = 'sweep_enabled';
  v_enabled := COALESCE(v_enabled, false);

  IF NOT p_dry_run AND NOT v_enabled THEN
    RETURN jsonb_build_object('status','disabled','note','refill_settings.sweep_enabled is false; run with p_dry_run := true or enable the flag','dry_run',p_dry_run);
  END IF;

  FOR r IN SELECT * FROM public.v_expired_inventory LOOP
    IF r.bucket = 'zero_stock_residual' THEN
      IF r.location = 'machine' THEN
        IF p_dry_run THEN
          v_cleared_pod := v_cleared_pod + 1;
        ELSE
          PERFORM public.backfill_archive_pod_inventory_row(
            r.row_id, format('PRD-065 sweep: zero-stock expired residual (expiry %s)', r.expiry), NULL, v_user_id);
          v_cleared_pod := v_cleared_pod + 1;
        END IF;
        v_details := v_details || jsonb_build_object('action','writeoff_pod','row_id',r.row_id,'product',r.product_name,'location',r.location_name);
      ELSE -- warehouse
        IF p_dry_run THEN
          v_cleared_wh := v_cleared_wh + 1;
        ELSE
          PERFORM public.warehouse_expire_writeoff(
            r.row_id, format('PRD-065 sweep: zero-stock expired residual (expiry %s)', r.expiry), v_user_id);
          v_cleared_wh := v_cleared_wh + 1;
        END IF;
        v_details := v_details || jsonb_build_object('action','writeoff_wh','row_id',r.row_id,'product',r.product_name,'location',r.location_name);
      END IF;

    ELSE -- stock_bearing
      IF r.location = 'machine' THEN
        -- already queued?
        IF EXISTS (SELECT 1 FROM public.pod_inventory_edits
                   WHERE pod_inventory_id = r.row_id AND edit_type = 'expired' AND status = 'pending') THEN
          v_skipped := v_skipped + 1;
        ELSE
          IF p_dry_run THEN
            v_queued_pod := v_queued_pod + 1;
          ELSE
            PERFORM set_config('app.via_rpc','true', true);
            PERFORM set_config('app.rpc_name','sweep_expired_inventory', true);
            PERFORM set_config('app.mutation_reason', format('sweep queue expired pod=%s by=%s', r.row_id, v_user_id), true);
            INSERT INTO public.pod_inventory_edits
              (machine_id, boonz_product_id, requested_by, edit_type, quantity_update,
               requested_expiration_date, recheck_source, notes, status, pod_inventory_id)
            VALUES
              (r.location_id, r.boonz_product_id, v_user_id, 'expired', r.units,
               r.expiry, 'system', 'PRD-065 sweep: stock-bearing expired; driver to confirm removal', 'pending', r.row_id);
            v_queued_pod := v_queued_pod + 1;
          END IF;
          v_details := v_details || jsonb_build_object('action','queue_pod','row_id',r.row_id,'product',r.product_name,'units',r.units,'location',r.location_name);
        END IF;
      ELSE -- warehouse stock-bearing: manager handles via B4, flag only
        v_flagged_wh := v_flagged_wh + 1;
        v_details := v_details || jsonb_build_object('action','flag_wh','row_id',r.row_id,'product',r.product_name,'units',r.units,'location',r.location_name);
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'status', CASE WHEN p_dry_run THEN 'dry_run' ELSE 'applied' END,
    'dry_run', p_dry_run,
    'sweep_enabled', v_enabled,
    'cleared_pod_residual', v_cleared_pod,
    'cleared_wh_residual', v_cleared_wh,
    'queued_pod_stock_bearing', v_queued_pod,
    'flagged_wh_stock_bearing', v_flagged_wh,
    'skipped_already_queued', v_skipped,
    'details', v_details
  );
END;
$$;

REVOKE ALL ON FUNCTION public.sweep_expired_inventory(boolean,uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.sweep_expired_inventory(boolean,uuid) TO authenticated, service_role;

-- DOWN:
-- DROP FUNCTION IF EXISTS public.sweep_expired_inventory(boolean,uuid);
-- DELETE FROM public.refill_settings WHERE setting_key = 'sweep_enabled';
