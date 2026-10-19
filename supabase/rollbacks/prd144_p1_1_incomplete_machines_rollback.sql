-- Rollback for PRD-144 P1-1 (20261019064628_prd144_p1_1_incomplete_machines_and_prepicks).
-- Reverses the write_refill_plan and pick_machine_manually anchors (count guarded) and drops the two
-- new functions. Pre-picks already dropped stay cs_dropped; pick_machine_manually restores any one.
DO $patch$
DECLARE
  v_def text; n int; i int; pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.write_refill_plan(date,jsonb)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  v_map_block    jsonb;' || chr(10) || 'BEGIN',
          '  v_map_block    jsonb;' || chr(10)
          || '  v_pp           record;  -- PRD-144 P1-1' || chr(10)
          || '  v_pre_dropped  int := 0;' || chr(10)
          || '  v_repicked     int := 0;' || chr(10)
          || 'BEGIN'],
    ARRAY['  ) INTO v_machine_names;' || chr(10) || chr(10) || '  DELETE FROM refill_plan_output t',
          '  ) INTO v_machine_names;' || chr(10) || chr(10)
          || '  -- PRD-144 P1-1: the plan CS writes supersedes the picker''s unconfirmed pre-picks for the day.' || chr(10)
          || '  FOR v_pp IN' || chr(10)
          || '    SELECT mtv.machine_id FROM public.machines_to_visit mtv JOIN public.machines m ON m.machine_id = mtv.machine_id' || chr(10)
          || '     WHERE mtv.plan_date = p_plan_date AND mtv.status = ''picked'' AND mtv.confirmed_at IS NULL' || chr(10)
          || '       AND NOT (m.official_name = ANY(v_machine_names))' || chr(10)
          || '       AND NOT EXISTS (SELECT 1 FROM public.refill_plan_output r WHERE r.plan_date = p_plan_date AND r.machine_name = m.official_name)' || chr(10)
          || '       AND NOT EXISTS (SELECT 1 FROM public.refill_dispatching rd WHERE rd.machine_id = mtv.machine_id AND rd.dispatch_date = p_plan_date)' || chr(10)
          || '  LOOP' || chr(10)
          || '    BEGIN' || chr(10)
          || '      PERFORM public.unpick_machine_to_visit(p_plan_date, v_pp.machine_id, ''superseded by the plan CS wrote (PRD-144 P1-1)'');' || chr(10)
          || '      v_pre_dropped := v_pre_dropped + 1;' || chr(10)
          || '    EXCEPTION WHEN OTHERS THEN NULL;  -- e.g. a manager caller: unpick is operator_admin only' || chr(10)
          || '    END;' || chr(10)
          || '  END LOOP;' || chr(10)
          || '  FOR v_pp IN' || chr(10)
          || '    SELECT m.machine_id FROM public.machines m' || chr(10)
          || '     WHERE m.official_name = ANY(v_machine_names)' || chr(10)
          || '       AND NOT EXISTS (SELECT 1 FROM public.machines_to_visit mtv WHERE mtv.machine_id = m.machine_id' || chr(10)
          || '                        AND mtv.plan_date = p_plan_date AND mtv.status IN (''picked'', ''cs_added''))' || chr(10)
          || '  LOOP' || chr(10)
          || '    BEGIN' || chr(10)
          || '      PERFORM public.pick_machine_manually(p_plan_date, v_pp.machine_id, ''plan written by CS (PRD-144 P1-1)'');' || chr(10)
          || '      v_repicked := v_repicked + 1;' || chr(10)
          || '    EXCEPTION WHEN OTHERS THEN NULL;' || chr(10)
          || '    END;' || chr(10)
          || '  END LOOP;' || chr(10) || chr(10)
          || '  DELETE FROM refill_plan_output t'],
    ARRAY['  ) || jsonb_build_object(''stale_pending_preserved'', v_stale_pending);',
          '  ) || jsonb_build_object(''stale_pending_preserved'', v_stale_pending,' || chr(10)
          || '                        ''pre_picks_dropped'', v_pre_dropped, ''machines_repicked'', v_repicked);']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][2], ''))) / length(pairs[i][2]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p1_1 rollback: write_refill_plan anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][2], pairs[i][1]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.pick_machine_manually(date,uuid,text)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  v_m_building text;' || chr(10) || 'BEGIN',
          '  v_m_building text;' || chr(10) || '  v_pp         record;  -- PRD-144 P1-1' || chr(10) || 'BEGIN'],
    ARRAY['  -- Upsert: if already in this plan',
          '  -- PRD-144 P1-1: a machine CS picks by hand supersedes the picker''s unconfirmed pre-picks for' || chr(10)
          || '  -- the day that have no plan and no dispatch lines yet.' || chr(10)
          || '  FOR v_pp IN' || chr(10)
          || '    SELECT mtv.machine_id FROM public.machines_to_visit mtv JOIN public.machines m ON m.machine_id = mtv.machine_id' || chr(10)
          || '     WHERE mtv.plan_date = p_plan_date AND mtv.status = ''picked'' AND mtv.confirmed_at IS NULL' || chr(10)
          || '       AND mtv.machine_id <> p_machine_id' || chr(10)
          || '       AND NOT EXISTS (SELECT 1 FROM public.refill_plan_output r WHERE r.plan_date = p_plan_date AND r.machine_name = m.official_name)' || chr(10)
          || '       AND NOT EXISTS (SELECT 1 FROM public.refill_dispatching rd WHERE rd.machine_id = mtv.machine_id AND rd.dispatch_date = p_plan_date)' || chr(10)
          || '  LOOP' || chr(10)
          || '    PERFORM public.unpick_machine_to_visit(p_plan_date, v_pp.machine_id, ''superseded by a machine CS picked (PRD-144 P1-1)'');' || chr(10)
          || '  END LOOP;' || chr(10) || chr(10)
          || '  -- Upsert: if already in this plan']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][2], ''))) / length(pairs[i][2]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p1_1 rollback: pick_machine_manually anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][2], pairs[i][1]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;
REVOKE EXECUTE ON FUNCTION public.write_refill_plan(date, jsonb) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.write_refill_plan(date, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.pick_machine_manually(date, uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.pick_machine_manually(date, uuid, text) TO authenticated, service_role;
DROP FUNCTION IF EXISTS public.resolve_incomplete_dispatch(uuid, date, text, text);
DROP FUNCTION IF EXISTS public.get_incomplete_dispatch_machines(integer);
