-- ROLLBACK for 20260718090002_rc01_single_writer_bridge.sql
-- Restores the VERBATIM live bodies captured 2026-07-18 (pg_get_functiondef) and drops
-- the additive index. No data migration was performed -> pure DDL, instant, no backfill.
-- Apply order for rollback: run this AFTER (or instead of) re-instating RC-08-A only if
-- push has already been reverted (this body uses the pre-RC-01 inline pin, so it does not
-- depend on wh_fefo_for_line).

-- (1) Drop the idempotency index (additive object; safe).
DROP INDEX IF EXISTS public.uq_dispatch_unstarted_wh_refill;

-- (2) Restore approve_refill_plan (verbatim pre-RC-01).
CREATE OR REPLACE FUNCTION public.approve_refill_plan(p_plan_date date, p_machine_names text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role    text;
  v_rows_approved  int := 0;
  v_dispatch_rows  int := 0;
  v_back_populated int := 0;
  v_slot_guard     jsonb := NULL;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'approve_refill_plan', true);

  SELECT role INTO v_caller_role
  FROM user_profiles WHERE id = auth.uid();

  IF v_caller_role NOT IN ('operator_admin', 'superadmin', 'manager') THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'error', 'Insufficient role — approval requires operator_admin, superadmin, or manager'
    );
  END IF;

  IF p_plan_date IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'p_plan_date is required');
  END IF;
  IF p_machine_names IS NULL OR array_length(p_machine_names, 1) = 0 THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'p_machine_names must be a non-empty array');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM refill_plan_output
    WHERE plan_date = p_plan_date
      AND machine_name = ANY(p_machine_names)
      AND operator_status = 'pending'
  ) THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'error', 'No pending rows found for the specified date and machines'
    );
  END IF;

  v_slot_guard := public.assert_weimi_slot_match(p_plan_date, NULL, NULL);
  PERFORM set_config('app.rpc_name', 'approve_refill_plan', true);

  UPDATE refill_plan_output
  SET operator_status = 'approved',
      reviewed_at     = now()
  WHERE plan_date        = p_plan_date
    AND machine_name     = ANY(p_machine_names)
    AND operator_status  = 'pending';

  GET DIAGNOSTICS v_rows_approved = ROW_COUNT;

  DELETE FROM refill_dispatching
  WHERE dispatch_date = p_plan_date
    AND machine_id IN (
      SELECT machine_id FROM machines
      WHERE official_name = ANY(p_machine_names)
    )
    AND include = true;

  WITH inserted AS (
    INSERT INTO refill_dispatching (
      machine_id, shelf_id, pod_product_id, boonz_product_id,
      dispatch_date, action, quantity, include, comment,
      from_warehouse_id
    )
    SELECT
      m.machine_id,
      sc.shelf_id,
      pp.pod_product_id,
      bp.product_id,
      r.plan_date,
      CASE r.action
        WHEN 'REFILL'  THEN 'Refill'
        WHEN 'ADD NEW' THEN 'Add New'
        WHEN 'REMOVE'  THEN 'Remove'
        ELSE r.action
      END,
      r.quantity,
      true,
      r.comment,
      CASE
        WHEN bp.storage_temp_requirement = 'cold'
          THEN '4bebef68-9e36-4a5c-9c2c-142f8dbdae85'  -- WH_CENTRAL
        ELSE m.primary_warehouse_id
      END
    FROM refill_plan_output r
    JOIN machines m
      ON m.official_name = r.machine_name
    JOIN pod_products pp
      ON pp.pod_product_name = r.pod_product_name
    JOIN boonz_products bp
      ON bp.boonz_product_name = r.boonz_product_name
    JOIN shelf_configurations sc
      ON sc.machine_id = m.machine_id
     AND sc.shelf_code = r.shelf_code
    WHERE r.plan_date       = p_plan_date
      AND r.machine_name    = ANY(p_machine_names)
      AND r.operator_status = 'approved'
    RETURNING dispatch_id, machine_id, shelf_id, dispatch_date, action, boonz_product_id, pod_product_id
  )
  UPDATE refill_plan_output rpo
  SET dispatch_id = i.dispatch_id
  FROM inserted i
  JOIN machines m  ON m.machine_id = i.machine_id
  JOIN shelf_configurations sc ON sc.shelf_id = i.shelf_id
  JOIN boonz_products bp ON bp.product_id = i.boonz_product_id
  JOIN pod_products  pp ON pp.pod_product_id = i.pod_product_id
  WHERE rpo.plan_date          = i.dispatch_date
    AND rpo.machine_name       = m.official_name
    AND rpo.shelf_code         = sc.shelf_code
    AND rpo.boonz_product_name = bp.boonz_product_name
    AND rpo.pod_product_name   = pp.pod_product_name
    AND rpo.operator_status    = 'approved'
    AND CASE i.action
          WHEN 'Refill'  THEN 'REFILL'
          WHEN 'Add New' THEN 'ADD NEW'
          WHEN 'Remove'  THEN 'REMOVE'
          ELSE upper(i.action)
        END = upper(rpo.action);

  GET DIAGNOSTICS v_back_populated = ROW_COUNT;

  v_dispatch_rows := v_back_populated;

  RETURN jsonb_build_object(
    'status',                   'ok',
    'plan_date',                p_plan_date,
    'rows_approved',            v_rows_approved,
    'dispatching_rows_written', v_dispatch_rows,
    'dispatch_ids_back_populated', v_back_populated,
    'weimi_slot_guard',         v_slot_guard,
    'machines',                 p_machine_names
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'status', 'error',
    'error',  SQLERRM,
    'detail', SQLSTATE
  );
END;
$function$;

-- (3) Restore push_plan_to_dispatch (verbatim pre-RC-01, rpc_version v9_id_keyed_rpo).
--     NOTE: this body uses the OLD inline FEFO pin (warehouse_stock>0, LIMIT 1, no
--     netting/quarantine/expiry guard). It does NOT reference wh_fefo_for_line, so it
--     is safe to restore whether or not RC-08-A is still present.
--     >>> Full verbatim body captured 2026-07-18 — see rollback/rc01_push_pre.sql
--         (kept in a separate file for length; identical to the live def pulled this session).
\i rollback/rc01_push_pre.sql
