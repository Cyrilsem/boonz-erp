-- Rollback for PRD-144 P0-2: restores add_dispatch_row and tg_enforce_pack_via_rpc to their
-- pre-P0-2 bodies by reversing each anchor (guarded, count must be 1).
DO $patch$
DECLARE
  v_def text; n int; i int;
  pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.add_dispatch_row(uuid,text,uuid,numeric,text,date,text,uuid,uuid,text,text,text,uuid)'::regprocedure);
  pairs := ARRAY[
    ARRAY['       quantity, packed, dispatched, picked_up, returned, item_added, include,' || chr(10) || '       source_kind,',
          '       quantity, packed, dispatched, picked_up, returned, item_added, include, pack_outcome,' || chr(10) || '       source_kind,'],
    ARRAY['       p_quantity, false, true, false, false, false, true,' || chr(10) || '       p_source_kind,',
          '       p_quantity, (p_source_kind = ''m2m''), true, false, false, false, true,' || chr(10)
          || '       CASE WHEN p_source_kind = ''m2m'' THEN ''no_pack_needed''::public.pack_outcome_enum END,  -- PRD-144 P0-2' || chr(10)
          || '       p_source_kind,'],
    ARRAY['         SET source_kind = ''m2m'',' || chr(10),
          '         SET source_kind = ''m2m'',' || chr(10)
          || '             packed = true,  -- PRD-144 P0-2: same stamp as push_plan_to_dispatch' || chr(10)
          || '             pack_outcome = ''no_pack_needed''::public.pack_outcome_enum,' || chr(10)
          || '             dispatched = true,' || chr(10)]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][2], ''))) / length(pairs[i][2]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p0_2 rollback: add_dispatch_row anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][2], pairs[i][1]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.tg_enforce_pack_via_rpc()'::regprocedure);
  n := (length(v_def) - length(replace(v_def, '''confirm_machine_packed'',''add_dispatch_row'')', ''))) / length('''confirm_machine_packed'',''add_dispatch_row'')');
  IF n <> 1 THEN RAISE EXCEPTION 'prd144_p0_2 rollback: tg_enforce_pack_via_rpc anchor count %', n; END IF;
  EXECUTE replace(v_def, '''confirm_machine_packed'',''add_dispatch_row'')', '''confirm_machine_packed'')');
END
$patch$;
REVOKE EXECUTE ON FUNCTION public.add_dispatch_row(uuid,text,uuid,numeric,text,date,text,uuid,uuid,text,text,text,uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.add_dispatch_row(uuid,text,uuid,numeric,text,date,text,uuid,uuid,text,text,text,uuid) TO authenticated, service_role;
