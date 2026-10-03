-- Rollback for DRAFT_fix3_weimi_slot_guard_per_machine.sql

DROP FUNCTION IF EXISTS public.set_machine_weimi_slot_guard_override(uuid, text, text, uuid);

CREATE OR REPLACE FUNCTION public.assert_weimi_slot_match(p_plan_date date, p_mode text DEFAULT NULL::text, p_machine_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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
      v_warned := v_warned || v_diag;
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

ALTER TABLE public.machines DROP CONSTRAINT IF EXISTS machines_weimi_slot_guard_override_check;
ALTER TABLE public.machines DROP COLUMN IF EXISTS weimi_slot_guard_override;
