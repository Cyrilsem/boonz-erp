-- drift-kill PHASE 1c: wire the WEIMI slot guard into push_plan_to_dispatch
-- (v7 -> v8, covers FE approve->push commits) and stitch_pod_to_boonz (result
-- surfaced on every stitch; 'check' mode on dry-runs = zero writes).
-- Guarded surgical transforms: abort on base-md5 drift or anchor-count <> 1.
-- Rollback md5s: push v7 = 98c40dc31ac26a76701626ecae89b417,
--                stitch v28 = 24c5799d4b7eae2ce95ba1cbcb2263c4.
DO $dk$
DECLARE
  v_def text; v_n int;
  A_DECL text := E'  v_transfer_skipped     int := 0;';
  A_CALL text := E'\n  v_leak_n := 0;\n  FOR v_leak IN';
  A_VER  text := '''rpc_version'',''v7_prd071_autopair_m2m''';
  S_DECL text := E'  v_noncanon_shelf_n integer := 0;';
  S_RET  text := E'  RETURN jsonb_build_object(\n    ''plan_date'',p_plan_date,''dry_run'',p_dry_run,\n    ''engine_version'',''v28_remove_conservation_planqty'',';
  S_KEY  text := E'''noncanonical_shelf_codes'', v_noncanon_shelf_n,';
BEGIN
  -- push v7 -> v8
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc
   WHERE proname='push_plan_to_dispatch' AND pg_get_function_identity_arguments(oid)='p_plan_date date, p_machine_name text';
  IF md5(v_def) <> '98c40dc31ac26a76701626ecae89b417' THEN RAISE EXCEPTION 'push base drift %', md5(v_def); END IF;
  IF (length(v_def)-length(replace(v_def,A_DECL,'')))/length(A_DECL) <> 1 THEN RAISE EXCEPTION 'push A_DECL'; END IF;
  IF (length(v_def)-length(replace(v_def,A_CALL,'')))/length(A_CALL) <> 1 THEN RAISE EXCEPTION 'push A_CALL'; END IF;
  IF (length(v_def)-length(replace(v_def,A_VER,'')))/length(A_VER) <> 1 THEN RAISE EXCEPTION 'push A_VER'; END IF;
  v_def := replace(v_def, A_DECL, A_DECL || E'\n  v_slot_guard           jsonb := NULL;');
  v_def := replace(v_def, A_CALL,
    E'\n  -- drift-kill P1: WEIMI slot guard (block rejects mismatched plan lines here,\n'
 || E'  -- before they bridge to dispatching; warn logs to monitoring_alerts)\n'
 || E'  v_slot_guard := public.assert_weimi_slot_match(p_plan_date, NULL, p_machine_name);\n'
 || E'  PERFORM set_config(''app.rpc_name'', ''push_plan_to_dispatch'', true);\n'
 || A_CALL);
  v_def := replace(v_def, A_VER, E'''weimi_slot_guard'', v_slot_guard,\n    ''rpc_version'',''v8_driftkill_slot_guard''');
  EXECUTE v_def;

  -- stitch v28 + guard surface
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc WHERE proname='stitch_pod_to_boonz';
  IF md5(v_def) <> '24c5799d4b7eae2ce95ba1cbcb2263c4' THEN RAISE EXCEPTION 'stitch base drift %', md5(v_def); END IF;
  IF (length(v_def)-length(replace(v_def,S_DECL,'')))/length(S_DECL) <> 1 THEN RAISE EXCEPTION 'stitch S_DECL'; END IF;
  IF (length(v_def)-length(replace(v_def,S_RET,'')))/length(S_RET) <> 1 THEN RAISE EXCEPTION 'stitch S_RET'; END IF;
  IF (length(v_def)-length(replace(v_def,S_KEY,'')))/length(S_KEY) <> 1 THEN RAISE EXCEPTION 'stitch S_KEY'; END IF;
  v_def := replace(v_def, S_DECL, S_DECL || E'\n  v_slot_guard jsonb := NULL;');
  v_def := replace(v_def, S_RET,
    E'  -- drift-kill P1: WEIMI slot guard on every stitch (dry-run: ''check'' = zero writes)\n'
 || E'  v_slot_guard := public.assert_weimi_slot_match(p_plan_date, CASE WHEN p_dry_run THEN ''check'' ELSE NULL END);\n'
 || E'  PERFORM set_config(''app.rpc_name'', ''stitch_pod_to_boonz'', true);\n\n'
 || S_RET);
  v_def := replace(v_def, S_KEY, S_KEY || E'\n    ''weimi_slot_guard'', v_slot_guard,');
  EXECUTE v_def;

  RAISE NOTICE 'push v8 md5 %, stitch md5 %',
    (SELECT md5(pg_get_functiondef(oid)) FROM pg_proc WHERE proname='push_plan_to_dispatch'),
    (SELECT md5(pg_get_functiondef(oid)) FROM pg_proc WHERE proname='stitch_pod_to_boonz');
END $dk$;