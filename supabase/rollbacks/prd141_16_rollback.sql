-- PRD-141 item 16 rollback.
-- Fast path (no DDL): machine_is_new() returns false for every machine, all four patches go inert.
--   UPDATE public.refill_policy_params SET new_machine_days = 0, new_machine_velocity_mode = 'off';
-- Full path: reverse the four anchor patches (helpers left in place, unreferenced).
DO $rb$
DECLARE v text;
BEGIN
  v := pg_get_functiondef('public.compute_refill_decision(uuid,uuid,uuid,integer)'::regprocedure);
  v := replace(v, '  v7  := public.new_machine_velocity(p_machine_id, v_pod_id, v7, ''7d'');' || chr(10) ||
                  '  v30 := public.new_machine_velocity(p_machine_id, v_pod_id, v30, ''30d'');' || chr(10), '');
  EXECUTE v;
  v := pg_get_functiondef('public.engine_add_pod(date,integer)'::regprocedure);
  v := replace(v, 'ELSE public.new_machine_velocity(p.machine_id, wid.identity_pod, COALESCE(sl.velocity_7d, 0), ''7d'') END', 'ELSE COALESCE(sl.velocity_7d, 0) END');
  v := replace(v, 'ELSE public.new_machine_velocity(p.machine_id, wid.identity_pod, COALESCE(sl.velocity_30d, 0), ''30d'') END', 'ELSE COALESCE(sl.velocity_30d, 0) END');
  EXECUTE v;
  v := pg_get_functiondef('public.engine_swap_pod(date,integer,numeric,integer)'::regprocedure);
  v := replace(v, '         ) = ''false''::jsonb' || chr(10) || '      OR public.machine_is_new(m.machine_id);', '         ) = ''false''::jsonb;');
  EXECUTE v;
  v := pg_get_functiondef('public.assert_weimi_slot_match(date,text,text)'::regprocedure);
  v := replace(v, chr(10) || '    IF v_row_mode = ''block'' AND p_mode IS NULL AND r.machine_override IS NULL' || chr(10) ||
    '       AND (SELECT public.machine_is_new(mm.machine_id) FROM public.machines mm WHERE mm.official_name = r.machine_name) THEN' || chr(10) ||
    '      v_row_mode := ''warn'';  -- PRD-141 item 16: new-machine mode' || chr(10) || '    END IF;', '');
  EXECUTE v;
END $rb$;
REVOKE EXECUTE ON FUNCTION public.engine_add_pod(date, integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.engine_add_pod(date, integer) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.engine_swap_pod(date, integer, numeric, integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.engine_swap_pod(date, integer, numeric, integer) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.assert_weimi_slot_match(date, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assert_weimi_slot_match(date, text, text) TO authenticated, service_role;
