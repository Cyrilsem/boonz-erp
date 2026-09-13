-- PRD-122 Phase 2, Guard G-E: dispose_warehouse_return RPC + daily undisposed check.
--
-- dispose_warehouse_return resolves a warehouse_inventory row stuck at
-- provenance_reason='dispatch_return_unverified' -- refuses if the row isn't
-- currently at that state. 'reshelved' clears the unverified flag and leaves stock/
-- status alone; 'written_off'/'destroyed' zero the stock, set status='Removed', and
-- stamp disposal_reason='Waste' (warehouse_inventory.disposal_reason has its own
-- controlled vocabulary: 'Waste'/'Returning to supplier'/'Returned to supplier' --
-- the free-text p_reason goes to inventory_audit_log.reason instead). Ships with
-- p_dry_run DEFAULT true per the mission's blanket destructive-function rule.
--
-- check_undisposed_warehouse_returns is a daily check (register on the nightly cron
-- alongside sweep_warehouse_hygiene in G-F) that raises a return_undisposed/warning
-- monitoring_alerts row for every dispatch_return_unverified row older than 7 days.
-- ('warning' used in place of the brief's 'medium' -- monitoring_alerts.severity's
-- CHECK constraint only allows info/warning/critical.)
--
-- Cody: Approve. Article 1 (dedicated write path for this state transition), Article 4
-- (role-gated to warehouse/operator_admin/superadmin/manager, sets app.via_rpc,
-- validates disposition/reason/row-state), Article 6 (writes warehouse_inventory.status
-- and warehouse_stock -- follows the existing precedent set by transfer_warehouse_stock/
-- auto_expire_old_warehouse_stock/log_manual_refill, all role-gated writers of this
-- column; no ad-hoc trigger/cron mutates it directly), Article 8 (writes
-- inventory_audit_log; the codebase's existing generic auto-audit trigger also fires
-- in parallel, confirmed harmless in backtest).
--
-- Backtested in a rolled-back transaction: dry run previews correctly (no write);
-- check_undisposed_warehouse_returns flags both 19-Aug Healthy Cola rows (25 days
-- unverified); real disposal of one row correctly zeroes stock, sets status=Removed,
-- disposal_reason=Waste, and writes an audit_log row; the check no longer flags a
-- row once it's been disposed.

CREATE OR REPLACE FUNCTION public.dispose_warehouse_return(
  p_wh_inventory_id uuid,
  p_disposition text,
  p_reason text,
  p_actor uuid,
  p_dry_run boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_role text;
  v_row public.warehouse_inventory%ROWTYPE;
  v_old_stock numeric;
  v_new_status text;
  v_new_stock numeric;
  v_disposal_reason text;
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF v_role IS NULL OR v_role NOT IN ('warehouse', 'operator_admin', 'superadmin', 'manager') THEN
    RAISE EXCEPTION 'dispose_warehouse_return: role % not authorized', COALESCE(v_role, 'none');
  END IF;

  IF p_disposition NOT IN ('reshelved', 'written_off', 'destroyed') THEN
    RAISE EXCEPTION 'dispose_warehouse_return: p_disposition must be reshelved, written_off, or destroyed (got %)', p_disposition;
  END IF;

  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'dispose_warehouse_return: p_reason is required (>=10 chars)';
  END IF;

  IF p_actor IS NULL THEN
    RAISE EXCEPTION 'dispose_warehouse_return: p_actor is required';
  END IF;

  SELECT * INTO v_row FROM public.warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'dispose_warehouse_return: wh_inventory_id % not found', p_wh_inventory_id;
  END IF;

  IF v_row.provenance_reason IS DISTINCT FROM 'dispatch_return_unverified' THEN
    RAISE EXCEPTION 'dispose_warehouse_return: row % is not at dispatch_return_unverified (currently %), refusing', p_wh_inventory_id, COALESCE(v_row.provenance_reason, 'NULL');
  END IF;

  v_old_stock := COALESCE(v_row.warehouse_stock, 0);

  IF p_disposition = 'reshelved' THEN
    v_new_status := v_row.status;
    v_new_stock := v_old_stock;
    v_disposal_reason := v_row.disposal_reason;
  ELSE
    v_new_status := 'Removed';
    v_new_stock := 0;
    v_disposal_reason := 'Waste';
  END IF;

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'dry_run', true,
      'wh_inventory_id', p_wh_inventory_id,
      'disposition', p_disposition,
      'current_status', v_row.status,
      'would_set_status', v_new_status,
      'old_stock', v_old_stock,
      'would_set_stock', v_new_stock,
      'would_set_disposal_reason', v_disposal_reason,
      'reason', p_reason
    );
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'dispose_warehouse_return', true);
  PERFORM set_config('app.provenance_reason', 'manual_adjust', true);

  UPDATE public.warehouse_inventory
  SET status = v_new_status,
      provenance_reason = 'manual_adjust',
      disposal_reason = v_disposal_reason,
      warehouse_stock = v_new_stock
  WHERE wh_inventory_id = p_wh_inventory_id;

  INSERT INTO public.inventory_audit_log (wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason)
  VALUES (p_wh_inventory_id, v_row.boonz_product_id, p_actor, v_old_stock, v_new_stock,
          format('dispose_warehouse_return: %s -- %s', p_disposition, p_reason));

  RETURN jsonb_build_object(
    'dry_run', false,
    'wh_inventory_id', p_wh_inventory_id,
    'disposition', p_disposition,
    'new_status', v_new_status,
    'old_stock', v_old_stock,
    'new_stock', v_new_stock,
    'disposal_reason', v_disposal_reason
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.check_undisposed_warehouse_returns()
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_count int;
BEGIN
  INSERT INTO public.monitoring_alerts (source, severity, payload)
  SELECT
    'return_undisposed',
    'warning',
    jsonb_build_object(
      'wh_inventory_id', wh_inventory_id,
      'boonz_product_id', boonz_product_id,
      'warehouse_stock', warehouse_stock,
      'days_unverified', (CURRENT_DATE - created_at::date)
    )
  FROM public.warehouse_inventory
  WHERE provenance_reason = 'dispatch_return_unverified'
    AND created_at < now() - interval '7 days';

  GET DIAGNOSTICS v_count = ROW_COUNT;

  RETURN jsonb_build_object('flagged', v_count, 'run_at', now());
END;
$function$;
