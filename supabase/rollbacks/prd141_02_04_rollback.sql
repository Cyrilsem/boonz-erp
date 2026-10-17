-- PRD-141 items 2 and 4 rollback: restore primary-warehouse crediting and drop the damaged outcome.
-- The return_warehouse_id column, the 'damaged_return' enum value and the quarantined expression are
-- left in place (harmless when unused; dropping them would orphan any damaged rows already written).
DO $rb$
DECLARE v text;
BEGIN
  v := pg_get_functiondef('public.wm_confirm_line(uuid,numeric,date,text,uuid,text,text,uuid,boolean,jsonb)'::regprocedure);
  v := regexp_replace(v, '  -- PRD-141 item 2: returns land in WH_CENTRAL[^\n]*\n  v_target_wh := COALESCE\([^\n]*\n',
         '  v_target_wh := (SELECT primary_warehouse_id FROM public.machines WHERE machine_id = v_line.machine_id);' || chr(10));
  v := replace(v, ',''acknowledged'',''damaged'') THEN', ',''acknowledged'') THEN');
  EXECUTE v;
  v := pg_get_functiondef('public.wm_confirm_line_split(uuid,jsonb,text,uuid,boolean)'::regprocedure);
  v := regexp_replace(v, '  -- PRD-141 item 2: returns land in WH_CENTRAL[^\n]*\n  v_target_wh := COALESCE\([^\n]*\n',
         '  v_target_wh := (SELECT primary_warehouse_id FROM public.machines WHERE machine_id = v_line.machine_id);' || chr(10));
  v := replace(v, '''waste'',''damaged'') THEN', '''waste'') THEN');
  EXECUTE v;
  v := pg_get_functiondef('public.receive_dispatch_line(uuid,numeric,uuid,jsonb,boolean,text)'::regprocedure);
  v := regexp_replace(v, '\n    v_target_wh := COALESCE\(v_dispatch\.return_warehouse_id[^\n]*', '');
  EXECUTE v;
END $rb$;
