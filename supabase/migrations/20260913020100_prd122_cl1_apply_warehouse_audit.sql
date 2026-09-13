-- PRD-122 Phase 3, CL-1: apply_warehouse_audit -- applies Monday's physical count
-- (already frozen into warehouse_audit_baseline for audit_date 2026-09-14, 145
-- rows/1298 units/26 flagged) onto live warehouse_inventory.
--
-- Extends disposal_reason's controlled vocabulary with 'audit_zero' (distinct from
-- 'auto_retired_at_zero', which was considered for G-F and reverted -- this one is
-- genuinely new: a row physically counted at zero during the audit, not a stale
-- system-side zero).
--
-- apply_warehouse_audit(p_audit_date, p_actor, p_dry_run DEFAULT true):
--  - Refuses outright if fewer than 80% of baseline rows for that date have a
--    counted_units value yet (today, 13 Sep, that's 0% -- the count hasn't
--    happened -- so this correctly refuses on every call right now).
--  - For each counted baseline row: if live warehouse_stock has drifted from the
--    frozen system_units snapshot (something else touched it since the freeze),
--    skip and report 'drifted' -- never blindly overwrite. Otherwise write
--    counted_units onto warehouse_stock; a count of exactly 0 also flips
--    status -> Inactive, disposal_reason -> 'audit_zero'.
--  - One inventory_audit_log row per applied change.
--  - Returns {applied, skipped, drifted, total_variance_units}.
--
-- Cody: Approve. Article 1 (dedicated writer for this audit-application action, no
-- other function performs it), Article 4 (role-gated, sets app.via_rpc/rpc_name,
-- validates p_actor and the 80% completeness gate before touching anything), Article
-- 6 (writes warehouse_inventory.status/warehouse_stock -- role-gated RPC, same
-- precedent as G-E/G-F/transfer_warehouse_stock), Article 8 (one audit log entry per
-- change), Article 12 (forward-only, additive constraint change).
--
-- Backtested in a rolled-back transaction: (1) real call against the actual 2026-09-14
-- baseline today correctly refuses (0% counted). (2) A synthetic count was staged
-- (120 of 145 rows given counted_units=system_units, one row's live stock bumped by
-- +999 to simulate post-freeze drift, one row's counted_units forced to 0) --
-- dry run reported would_apply=119, would_drift_skip=1, would_zero_out=2 (a second
-- row already had system_units=0 in the baseline, unrelated to the injected test
-- case). The real call then correctly zeroed/Inactivated the genuinely-counted zero
-- row and left the drifted row completely untouched (Active, original stock intact)
-- even though it also carried counted_units=0 -- confirms the drift check runs
-- before the zero-out branch, so a drifted row is never silently retired.

ALTER TABLE public.warehouse_inventory DROP CONSTRAINT warehouse_inventory_disposal_reason_check;

ALTER TABLE public.warehouse_inventory ADD CONSTRAINT warehouse_inventory_disposal_reason_check
  CHECK (disposal_reason IS NULL OR disposal_reason = ANY (ARRAY[
    'Waste'::text, 'Returning to supplier'::text, 'Returned to supplier'::text, 'audit_zero'::text
  ]));

CREATE OR REPLACE FUNCTION public.apply_warehouse_audit(p_audit_date date, p_actor uuid, p_dry_run boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_role text;
  v_total int;
  v_counted int;
  v_pct numeric;
  v_applied int := 0;
  v_skipped int := 0;
  v_drifted int := 0;
  v_variance numeric := 0;
  v_would_apply int := 0;
  v_would_drift int := 0;
  v_would_zero int := 0;
  r record;
  v_live_stock numeric;
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF v_role IS NULL OR v_role NOT IN ('warehouse', 'operator_admin', 'superadmin', 'manager') THEN
    RAISE EXCEPTION 'apply_warehouse_audit: role % not authorized', COALESCE(v_role, 'none');
  END IF;

  IF p_actor IS NULL THEN
    RAISE EXCEPTION 'apply_warehouse_audit: p_actor is required';
  END IF;

  SELECT count(*), count(counted_units) INTO v_total, v_counted
  FROM public.warehouse_audit_baseline WHERE audit_date = p_audit_date;

  IF v_total = 0 THEN
    RAISE EXCEPTION 'apply_warehouse_audit: no baseline rows frozen for audit_date %', p_audit_date;
  END IF;

  v_pct := v_counted::numeric / v_total;
  IF v_pct < 0.8 THEN
    RETURN jsonb_build_object(
      'status', 'refused_incomplete_count',
      'audit_date', p_audit_date,
      'total_baseline_rows', v_total,
      'counted_rows', v_counted,
      'pct_counted', round(v_pct * 100, 1)
    );
  END IF;

  IF p_dry_run THEN
    FOR r IN SELECT * FROM public.warehouse_audit_baseline WHERE audit_date = p_audit_date AND counted_units IS NOT NULL LOOP
      SELECT warehouse_stock INTO v_live_stock FROM public.warehouse_inventory WHERE wh_inventory_id = r.wh_inventory_id;
      IF v_live_stock IS DISTINCT FROM r.system_units THEN
        v_would_drift := v_would_drift + 1;
      ELSE
        v_would_apply := v_would_apply + 1;
        IF r.counted_units = 0 THEN v_would_zero := v_would_zero + 1; END IF;
      END IF;
    END LOOP;

    RETURN jsonb_build_object(
      'dry_run', true,
      'audit_date', p_audit_date,
      'total_baseline_rows', v_total,
      'counted_rows', v_counted,
      'pct_counted', round(v_pct * 100, 1),
      'would_apply', v_would_apply,
      'would_drift_skip', v_would_drift,
      'would_zero_out', v_would_zero
    );
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'apply_warehouse_audit', true);

  FOR r IN SELECT * FROM public.warehouse_audit_baseline WHERE audit_date = p_audit_date AND counted_units IS NOT NULL LOOP
    SELECT warehouse_stock INTO v_live_stock FROM public.warehouse_inventory WHERE wh_inventory_id = r.wh_inventory_id FOR UPDATE;
    IF NOT FOUND THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    IF v_live_stock IS DISTINCT FROM r.system_units THEN
      v_drifted := v_drifted + 1;
      CONTINUE;
    END IF;

    UPDATE public.warehouse_inventory
    SET warehouse_stock = r.counted_units,
        status = CASE WHEN r.counted_units = 0 THEN 'Inactive' ELSE status END,
        disposal_reason = CASE WHEN r.counted_units = 0 THEN 'audit_zero' ELSE disposal_reason END
    WHERE wh_inventory_id = r.wh_inventory_id;

    INSERT INTO public.inventory_audit_log (wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason)
    VALUES (r.wh_inventory_id, r.boonz_product_id, p_actor, v_live_stock, r.counted_units,
            format('apply_warehouse_audit %s: counted %s vs system %s', p_audit_date, r.counted_units, v_live_stock));

    v_applied := v_applied + 1;
    v_variance := v_variance + (r.counted_units - v_live_stock);
  END LOOP;

  RETURN jsonb_build_object(
    'dry_run', false,
    'audit_date', p_audit_date,
    'applied', v_applied,
    'skipped', v_skipped,
    'drifted', v_drifted,
    'total_variance_units', v_variance
  );
END;
$function$;
