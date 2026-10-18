-- PRD-141 item 27: approve_refill_plan returns per-machine results instead of failing the whole call on one machine.
-- With more than one machine it calls itself once per machine; each single-machine call runs in the function's own
-- EXCEPTION block (a subtransaction), so a Gate-2 or validation failure rolls back only that machine. Returns
-- status ok / partial / error, machines_ok, machines_failed, summed rows_approved and dispatching_rows_written, and
-- results[] (machine, status ok / nothing_pending / error, error, violation_detail). Single-machine calls unchanged.
-- Rollback: supabase/rollbacks/prd141_27_rollback.sql.
DO $patch$
DECLARE
  v_def text; n int; i int;
  pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.approve_refill_plan(date,text[],jsonb)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  v_g11_check        record;' || chr(10) || 'BEGIN',
          '  v_g11_check        record;' || chr(10)
          || '  -- PRD-141 item 27 (per-machine results)' || chr(10)
          || '  v_pm_name          text;' || chr(10)
          || '  v_pm_one           jsonb;' || chr(10)
          || '  v_pm_results       jsonb := ''[]''::jsonb;' || chr(10)
          || '  v_pm_ok            int := 0;' || chr(10)
          || '  v_pm_failed        int := 0;' || chr(10)
          || '  v_pm_rows          int := 0;' || chr(10)
          || '  v_pm_dispatch      int := 0;' || chr(10)
          || 'BEGIN'],
    ARRAY['    RETURN jsonb_build_object(''status'', ''error'', ''error'', ''p_machine_names must be a non-empty array'');' || chr(10) || '  END IF;',
          '    RETURN jsonb_build_object(''status'', ''error'', ''error'', ''p_machine_names must be a non-empty array'');' || chr(10) || '  END IF;' || chr(10) || chr(10)
          || '  -- PRD-141 item 27: several machines are approved one by one. Each single-machine call runs in this' || chr(10)
          || '  -- function''s own EXCEPTION block (a subtransaction), so one machine failing Gate-2 rolls back only that' || chr(10)
          || '  -- machine and the others still go through. A machine with nothing pending is reported, not failed.' || chr(10)
          || '  IF (SELECT count(DISTINCT x) FROM unnest(p_machine_names) x) > 1 THEN' || chr(10)
          || '    FOR v_pm_name IN SELECT DISTINCT x FROM unnest(p_machine_names) x ORDER BY 1 LOOP' || chr(10)
          || '      v_pm_one := public.approve_refill_plan(p_plan_date, ARRAY[v_pm_name], p_waive);' || chr(10)
          || '      IF v_pm_one->>''status'' = ''ok'' THEN' || chr(10)
          || '        v_pm_ok := v_pm_ok + 1;' || chr(10)
          || '        v_pm_rows := v_pm_rows + COALESCE((v_pm_one->>''rows_approved'')::int, 0);' || chr(10)
          || '        v_pm_dispatch := v_pm_dispatch + COALESCE((v_pm_one->>''dispatching_rows_written'')::int, 0);' || chr(10)
          || '        v_pm_results := v_pm_results || jsonb_build_object(''machine'', v_pm_name, ''status'', ''ok'',' || chr(10)
          || '          ''rows_approved'', v_pm_one->''rows_approved'', ''dispatching_rows_written'', v_pm_one->''dispatching_rows_written'',' || chr(10)
          || '          ''mid_pack_warning'', v_pm_one->''mid_pack_warning'');' || chr(10)
          || '      ELSIF v_pm_one->>''error'' = ''No pending rows found for the specified date and machines'' THEN' || chr(10)
          || '        v_pm_results := v_pm_results || jsonb_build_object(''machine'', v_pm_name, ''status'', ''nothing_pending'');' || chr(10)
          || '      ELSE' || chr(10)
          || '        v_pm_failed := v_pm_failed + 1;' || chr(10)
          || '        v_pm_results := v_pm_results || jsonb_build_object(''machine'', v_pm_name, ''status'', ''error'',' || chr(10)
          || '          ''error'', v_pm_one->''error'', ''violation_detail'', v_pm_one->''violation_detail'');' || chr(10)
          || '      END IF;' || chr(10)
          || '    END LOOP;' || chr(10)
          || '    RETURN jsonb_build_object(' || chr(10)
          || '      ''status'', CASE WHEN v_pm_failed = 0 AND v_pm_ok > 0 THEN ''ok'' WHEN v_pm_ok > 0 THEN ''partial'' ELSE ''error'' END,' || chr(10)
          || '      ''error'', CASE WHEN v_pm_ok = 0 THEN CASE WHEN v_pm_failed = 0 THEN ''No pending rows found for the specified date and machines''' || chr(10)
          || '                      ELSE format(''%s machine(s) failed, none approved'', v_pm_failed) END END,' || chr(10)
          || '      ''plan_date'', p_plan_date, ''machines'', p_machine_names,' || chr(10)
          || '      ''machines_ok'', v_pm_ok, ''machines_failed'', v_pm_failed,' || chr(10)
          || '      ''rows_approved'', v_pm_rows, ''dispatching_rows_present'', v_pm_dispatch, ''dispatching_rows_written'', v_pm_dispatch,' || chr(10)
          || '      ''results'', v_pm_results, ''writer'', ''push_plan_to_dispatch'');' || chr(10)
          || '  END IF;']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd141_27: approve_refill_plan anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;
REVOKE EXECUTE ON FUNCTION public.approve_refill_plan(date, text[], jsonb) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.approve_refill_plan(date, text[], jsonb) TO authenticated, service_role;
