-- PRD-144 P1-1 tests (operator_admin CS, then the warehouse manager). Ends with RAISE: nothing persists.
DO $t$
DECLARE
  v_list jsonb; v_cancel jsonb; v_complete jsonb; v_forbidden text := 'not refused'; v_pick jsonb;
  v_before int; v_after int; v_huawei uuid; v_amz38 uuid; v_iris uuid;
BEGIN
  SELECT machine_id INTO v_huawei FROM machines WHERE official_name = 'HUAWEI-2003-0000-B1';
  SELECT machine_id INTO v_amz38 FROM machines WHERE official_name = 'AMZ-1038-3001-O1';
  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
  v_list := public.get_incomplete_dispatch_machines(14);
  v_cancel := public.resolve_incomplete_dispatch(v_huawei, '2026-10-18', 'cancel', 'PRD-144 test, rolled back');
  v_complete := public.resolve_incomplete_dispatch(v_amz38, '2026-10-16', 'complete', 'PRD-144 test, rolled back');
  SELECT count(*) INTO v_before FROM machines_to_visit WHERE plan_date = '2026-10-20' AND status = 'picked';
  v_pick := public.pick_machine_manually('2026-10-20', (SELECT machine_id FROM machines WHERE official_name = 'HUAWEI-2003-0000-B1'), 'PRD-144 test');
  SELECT count(*) INTO v_after FROM machines_to_visit WHERE plan_date = '2026-10-20' AND status = 'picked';
  PERFORM set_config('request.jwt.claims', '{"sub":"bf32624e-3334-425d-b694-c5944b0c66f0","role":"authenticated"}', true);
  BEGIN
    PERFORM public.resolve_incomplete_dispatch(v_huawei, '2026-10-18', 'cancel', 'should be refused');
  EXCEPTION WHEN OTHERS THEN v_forbidden := SQLERRM; END;
  RAISE EXCEPTION 'PRD144_P1_1 list_machine_days=% open_lines=% | huawei_cancel=% | amz38_complete=% | prepicks % -> % | warehouse=%',
    jsonb_array_length(v_list), (SELECT sum((x->>'open_lines')::int) FROM jsonb_array_elements(v_list) x),
    left(v_cancel::text, 400), left(v_complete::text, 400), v_before, v_after, v_forbidden;
END $t$;
