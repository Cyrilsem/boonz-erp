-- drift-kill PHASE 1b: guard v2 (machine filter + no-write 'check' mode) and
-- wire into approve_refill_plan (chat/canonical approve choke point).
-- DROP+CREATE (not overload) per the repurpose_machine foot-gun rule.
-- Rollback md5s in PRD execution log: approve_refill_plan v1 = 1a26b5c2ea46ce24e464d62d05d2476e.

DROP FUNCTION public.assert_weimi_slot_match(date, text);

CREATE FUNCTION public.assert_weimi_slot_match(p_plan_date date, p_mode text DEFAULT NULL, p_machine_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_mode text;
  v_prev_rpc text := current_setting('app.rpc_name', true);
  v_checked int := 0;
  v_blocked jsonb := '[]'::jsonb;
  v_warned  jsonb := '[]'::jsonb;
  v_info    jsonb := '[]'::jsonb;
  r RECORD;
  v_diag jsonb;
BEGIN
  v_mode := COALESCE(p_mode, (SELECT weimi_slot_guard FROM refill_policy_params ORDER BY id LIMIT 1), 'warn');
  IF v_mode NOT IN ('off','warn','block','check') THEN v_mode := 'warn'; END IF;
  IF v_mode = 'off' THEN
    RETURN jsonb_build_object('status','ok','mode','off','checked',0,'blocked','[]'::jsonb,'warned','[]'::jsonb,'info','[]'::jsonb,'blocked_n',0,'warned_n',0);
  END IF;

  PERFORM set_config('app.via_rpc','true', true);
  PERFORM set_config('app.rpc_name','assert_weimi_slot_match', true);

  FOR r IN
    SELECT rpo.id, rpo.machine_name, rpo.shelf_code, rpo.pod_product_name, rpo.action, rpo.quantity,
           rpo.operator_status,
           upper(trim(rpo.action)) AS act,
           ssi.pod_product_id  AS weimi_pp_id,
           ssi.pod_product_name AS weimi_pod_name,
           ssi.goods_name_raw, ssi.match_method,
           plan_pp.pod_product_id AS plan_pp_id,
           EXISTS (
             SELECT 1 FROM refill_plan_output rr
             WHERE rr.plan_date = rpo.plan_date AND rr.machine_name = rpo.machine_name
               AND rr.shelf_code = rpo.shelf_code
               AND upper(trim(rr.action)) IN ('REMOVE','MACHINE TO WAREHOUSE')
               AND rr.operator_status IN ('pending','approved')
           ) AS same_shelf_swap
    FROM refill_plan_output rpo
    JOIN machines m ON m.official_name = rpo.machine_name
    LEFT JOIN shelf_configurations sc
      ON sc.machine_id = m.machine_id
     AND sc.shelf_code = regexp_replace(rpo.shelf_code, '^([A-Z])([0-9])$', '\1' || '0' || '\2')
    LEFT JOIN v_shelf_slot_identity ssi ON ssi.machine_id = m.machine_id AND ssi.shelf_id = sc.shelf_id
    LEFT JOIN pod_products plan_pp ON lower(trim(plan_pp.pod_product_name)) = lower(trim(rpo.pod_product_name))
    WHERE rpo.plan_date = p_plan_date
      AND (p_machine_name IS NULL OR rpo.machine_name = p_machine_name)
      AND rpo.operator_status IN ('pending','approved')
      AND COALESCE(rpo.dispatched, false) = false
  LOOP
    v_checked := v_checked + 1;
    v_diag := jsonb_build_object(
      'plan_line_id', r.id, 'machine', r.machine_name, 'shelf', r.shelf_code,
      'action', r.act, 'qty', r.quantity,
      'planned_pod', r.pod_product_name, 'weimi_pod', r.weimi_pod_name,
      'weimi_goods_name_raw', r.goods_name_raw, 'match_method', r.match_method,
      'same_shelf_swap', r.same_shelf_swap);

    IF r.act NOT IN ('REFILL','ADD NEW') OR COALESCE(r.quantity,0) = 0 THEN
      CONTINUE;
    END IF;
    IF r.weimi_pp_id IS NULL OR r.match_method = 'unmatched' THEN
      v_info := v_info || (v_diag || jsonb_build_object('reason','weimi_unresolved'));
      CONTINUE;
    END IF;
    IF r.plan_pp_id IS NOT DISTINCT FROM r.weimi_pp_id THEN CONTINUE; END IF;
    IF r.same_shelf_swap THEN
      v_info := v_info || (v_diag || jsonb_build_object('reason','same_shelf_swap_exempt'));
      CONTINUE;
    END IF;

    IF v_mode = 'check' THEN
      v_warned := v_warned || v_diag;  -- diagnostics only, zero writes
    ELSIF v_mode = 'block' THEN
      UPDATE refill_plan_output
         SET operator_status = 'rejected',
             operator_comment = left(COALESCE(NULLIF(trim(operator_comment),'') || ' | ', '')
               || '[weimi_slot_guard] planned ' || COALESCE(r.pod_product_name,'?')
               || ' but WEIMI shows ' || COALESCE(r.weimi_pod_name, r.goods_name_raw, '?')
               || ' on ' || r.shelf_code, 500)
       WHERE id = r.id AND operator_status IN ('pending','approved')
         AND COALESCE(dispatched,false) = false;
      v_blocked := v_blocked || v_diag;
      INSERT INTO monitoring_alerts (source, severity, payload)
      VALUES ('weimi_slot_guard','critical',
              v_diag || jsonb_build_object('title', format('BLOCKED: %s %s planned %s, WEIMI shows %s',
                r.machine_name, r.shelf_code, r.pod_product_name, COALESCE(r.weimi_pod_name, r.goods_name_raw)),
                'mode','block','plan_date', p_plan_date, 'detected_at', now()));
    ELSE
      v_warned := v_warned || v_diag;
      INSERT INTO monitoring_alerts (source, severity, payload)
      VALUES ('weimi_slot_guard','warning',
              v_diag || jsonb_build_object('title', format('slot mismatch: %s %s planned %s, WEIMI shows %s',
                r.machine_name, r.shelf_code, r.pod_product_name, COALESCE(r.weimi_pod_name, r.goods_name_raw)),
                'mode','warn','plan_date', p_plan_date, 'detected_at', now()));
    END IF;
  END LOOP;

  PERFORM set_config('app.rpc_name', COALESCE(v_prev_rpc,''), true);

  RETURN jsonb_build_object(
    'status','ok','mode',v_mode,'plan_date',p_plan_date,
    'checked',v_checked,
    'blocked',v_blocked,'warned',v_warned,'info',v_info,
    'blocked_n', jsonb_array_length(v_blocked),
    'warned_n', jsonb_array_length(v_warned));
END;
$function$;

COMMENT ON FUNCTION public.assert_weimi_slot_match(date, text, text) IS
'drift-kill Phase 1 guard v2: pending/approved REFILL/ADD NEW plan lines checked against v_shelf_slot_identity (WEIMI truth). Same-shelf swaps exempt; REMOVE/qty-0/unresolved informational. Modes: off|warn|block (dial refill_policy_params.weimi_slot_guard, default warn) + check (diagnostics only, zero writes, for dry-runs). Optional p_machine_name scope. Restores app.rpc_name. Articles 1,3,8,12; Am.005.';

-- Wire into approve_refill_plan (v2): guard runs before approval; in block
-- mode mismatched pending lines are rejected so only clean lines approve.
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

  -- drift-kill P1: WEIMI slot guard runs on every approve (warn logs; block
  -- rejects mismatched pending lines so they never reach dispatching).
  v_slot_guard := public.assert_weimi_slot_match(p_plan_date, NULL, NULL);
  PERFORM set_config('app.rpc_name', 'approve_refill_plan', true);

  -- Step 1: Approve pending rows
  UPDATE refill_plan_output
  SET operator_status = 'approved',
      reviewed_at     = now()
  WHERE plan_date        = p_plan_date
    AND machine_name     = ANY(p_machine_names)
    AND operator_status  = 'pending';

  GET DIAGNOSTICS v_rows_approved = ROW_COUNT;

  -- Step 2: Clear existing dispatching rows for this date + machines (existing dedup behavior)
  DELETE FROM refill_dispatching
  WHERE dispatch_date = p_plan_date
    AND machine_id IN (
      SELECT machine_id FROM machines
      WHERE official_name = ANY(p_machine_names)
    )
    AND include = true;

  -- Step 3: Mirror approved plan into refill_dispatching, capturing new dispatch_ids back
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
  -- ★ NEW: back-populate dispatch_id onto plan rows (UPDATE only on unambiguous match)
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

  -- count of rows inserted into refill_dispatching is approximately v_back_populated
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