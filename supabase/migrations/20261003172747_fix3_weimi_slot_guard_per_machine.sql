-- ONE-SHOT FIX BATCH, FIX 3: per-machine override for the WEIMI slot guard.
-- Rollback: supabase/migrations/20261003172747_fix3_weimi_slot_guard_per_machine_rollback.sql
--
-- Classification: assert_weimi_slot_match is a planning-pipeline function (called only from
-- preflight_refill_plan, push_plan_to_dispatch, stitch_pod_to_boonz, approve_refill_plan), never
-- from a field-app or warehouse-confirmation screen. Not subject to the 22:00-06:00 window.
--
-- Problem: v_mode was resolved ONCE globally (COALESCE(p_mode, refill_policy_params.weimi_slot_guard,
-- 'warn')), so the only way through for one new/offline machine was flipping the whole fleet.
--
-- Fix:
-- 1. New nullable machines.weimi_slot_guard_override text, CHECK IN ('off','warn','block','check').
-- 2. assert_weimi_slot_match resolves mode PER ROW: COALESCE(p_mode, machine override, global
--    default, 'warn'). The old top-of-function 'off' early-return moves into the loop (a global
--    'off' must not suppress a machine whose own override is 'block', and vice versa). Everything
--    else (the block/warn/check branches, the UPDATE, the monitoring_alerts inserts) is unchanged.
-- 3. New SECURITY DEFINER set_machine_weimi_slot_guard_override(p_machine_id, p_override, p_reason,
--    p_caller): the only write path for this column. Role-gated to operator_admin ONLY (narrower
--    than the usual 4-role admin list, per the task). write_audit_log has no reason column, so this
--    writer also inserts an explicit monitoring_alerts row (source
--    'weimi_slot_guard_override_changed') carrying who/when/old/new/reason for a queryable record,
--    on top of the generic tg_audit_machines trigger (already installed, fires unconditionally)
--    covering the raw before/after.

ALTER TABLE public.machines ADD COLUMN IF NOT EXISTS weimi_slot_guard_override text;
ALTER TABLE public.machines ADD CONSTRAINT machines_weimi_slot_guard_override_check
  CHECK (weimi_slot_guard_override IS NULL OR weimi_slot_guard_override IN ('off', 'warn', 'block', 'check'));

CREATE OR REPLACE FUNCTION public.assert_weimi_slot_match(p_plan_date date, p_mode text DEFAULT NULL::text, p_machine_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_global_mode text;
  v_row_mode text;
  v_prev_rpc text := current_setting('app.rpc_name', true);
  v_checked int := 0;
  v_blocked jsonb := '[]'::jsonb;
  v_warned  jsonb := '[]'::jsonb;
  v_info    jsonb := '[]'::jsonb;
  r RECORD;
  v_diag jsonb;
BEGIN
  v_global_mode := COALESCE((SELECT weimi_slot_guard FROM refill_policy_params ORDER BY id LIMIT 1), 'warn');
  IF v_global_mode NOT IN ('off','warn','block','check') THEN v_global_mode := 'warn'; END IF;

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
           m.weimi_slot_guard_override AS machine_override,
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
    v_row_mode := COALESCE(p_mode, r.machine_override, v_global_mode, 'warn');
    IF v_row_mode NOT IN ('off','warn','block','check') THEN v_row_mode := 'warn'; END IF;
    IF v_row_mode = 'off' THEN CONTINUE; END IF;

    v_checked := v_checked + 1;
    v_diag := jsonb_build_object(
      'plan_line_id', r.id, 'machine', r.machine_name, 'shelf', r.shelf_code,
      'action', r.act, 'qty', r.quantity,
      'planned_pod', r.pod_product_name, 'weimi_pod', r.weimi_pod_name,
      'weimi_goods_name_raw', r.goods_name_raw, 'match_method', r.match_method,
      'same_shelf_swap', r.same_shelf_swap, 'mode', v_row_mode);

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

    IF v_row_mode = 'check' THEN
      v_warned := v_warned || v_diag;  -- diagnostics only, zero writes
    ELSIF v_row_mode = 'block' THEN
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
    'status','ok','mode',v_global_mode,'plan_date',p_plan_date,
    'checked',v_checked,
    'blocked',v_blocked,'warned',v_warned,'info',v_info,
    'blocked_n', jsonb_array_length(v_blocked),
    'warned_n', jsonb_array_length(v_warned));
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_machine_weimi_slot_guard_override(
  p_machine_id uuid,
  p_override text,
  p_reason text,
  p_caller uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_caller_role text;
  v_old text;
  v_machine_name text;
BEGIN
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = p_caller;
  IF v_caller_role IS NULL OR v_caller_role <> 'operator_admin' THEN
    RAISE EXCEPTION 'set_machine_weimi_slot_guard_override: forbidden for role %, operator_admin only', COALESCE(v_caller_role, 'unknown');
  END IF;
  IF p_override IS NOT NULL AND p_override NOT IN ('off', 'warn', 'block', 'check') THEN
    RAISE EXCEPTION 'set_machine_weimi_slot_guard_override: p_override must be off, warn, block, check, or null (got %)', p_override;
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'set_machine_weimi_slot_guard_override: p_reason is required (>=10 chars)';
  END IF;

  SELECT weimi_slot_guard_override, official_name INTO v_old, v_machine_name
  FROM machines WHERE machine_id = p_machine_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'set_machine_weimi_slot_guard_override: machine % not found', p_machine_id;
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'set_machine_weimi_slot_guard_override', true);
  PERFORM set_config('app.mutation_reason',
    format('set_machine_weimi_slot_guard_override: machine=%s (%s) old=%s new=%s reason=%s caller=%s',
      p_machine_id, v_machine_name, COALESCE(v_old, '<global>'), COALESCE(p_override, '<global>'), p_reason, p_caller), true);

  UPDATE machines SET weimi_slot_guard_override = p_override WHERE machine_id = p_machine_id;

  INSERT INTO monitoring_alerts (source, severity, payload)
  VALUES ('weimi_slot_guard_override_changed', 'info',
    jsonb_build_object('machine_id', p_machine_id, 'machine_name', v_machine_name,
      'old_override', v_old, 'new_override', p_override, 'reason', p_reason,
      'changed_by', p_caller, 'changed_at', now()));

  RETURN jsonb_build_object('status', 'ok', 'machine_id', p_machine_id, 'machine_name', v_machine_name,
    'old_override', v_old, 'new_override', p_override);
END;
$function$;
