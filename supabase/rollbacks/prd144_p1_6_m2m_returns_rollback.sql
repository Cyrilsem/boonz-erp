-- Rollback for PRD-144 P1-6: reverses the receive_dispatch_line, wh_approve_remove_receipt, approve_m2m_transfer,
-- confirm_m2m_delivery, confirm_packed_transferred, receive_all_dispatches_for_machine and resolve_incomplete_dispatch
-- anchors and drops the M2M / intra_machine predicate from v_wm_confirmations. No data to restore: source legs that
-- a destination receive mirrored keep their mirrored quantities.
DO $patch$
DECLARE
  v_def text; n int; i int; pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.receive_dispatch_line(uuid,numeric,uuid,jsonb,boolean,text)'::regprocedure);
  pairs := ARRAY[
    ARRAY['    v_path := ''remove_single_expiry'';' || chr(10)
          || '    -- PRD-144 P1-6: an M2M leg never returns stock to a warehouse. Only the transfer closers receive its' || chr(10)
          || '    -- source leg (approve_m2m_transfer, confirm_m2m_delivery, confirm_packed_transferred), naming the transfer first.' || chr(10)
          || '    IF (COALESCE(v_dispatch.is_m2m, false) OR v_dispatch.source_kind = ''m2m'')' || chr(10)
          || '       AND (v_dispatch.m2m_transfer_id IS NULL' || chr(10)
          || '            OR current_setting(''app.m2m_close'', true) IS DISTINCT FROM v_dispatch.m2m_transfer_id::text) THEN' || chr(10)
          || '      RAISE EXCEPTION ''receive_dispatch_line: dispatch % is a machine-to-machine transfer leg (transfer %). Its stock goes to another machine, never to a warehouse, so it cannot be received as a return. Close it with approve_m2m_transfer.'',' || chr(10)
          || '        p_dispatch_id, COALESCE(v_dispatch.m2m_transfer_id::text, ''none'');' || chr(10)
          || '    END IF;' || chr(10),
          '    v_path := ''remove_single_expiry'';' || chr(10)],
    ARRAY['  -- PRD-144 P1-6: what an M2M destination leg receives is the flavour split; the source Remove leg mirrors it.' || chr(10)
          || '  IF COALESCE(v_dispatch.is_m2m, false) AND v_dispatch.action IN (''Refill'',''Add New'',''Add'') AND v_dispatch.m2m_partner_id IS NOT NULL THEN' || chr(10)
          || '    UPDATE refill_dispatching s' || chr(10)
          || '       SET quantity = p_filled_quantity,' || chr(10)
          || '           driver_confirmed_qty = CASE WHEN s.driver_confirmed_at IS NOT NULL THEN p_filled_quantity ELSE s.driver_confirmed_qty END,' || chr(10)
          || '           driver_confirmed_breakdown = CASE' || chr(10)
          || '             WHEN s.driver_confirmed_at IS NOT NULL AND jsonb_typeof(s.driver_confirmed_breakdown) = ''array''' || chr(10)
          || '                  AND (SELECT COALESCE(SUM((e->>''qty'')::numeric), 0) FROM jsonb_array_elements(s.driver_confirmed_breakdown) e) <> p_filled_quantity' || chr(10)
          || '             THEN jsonb_build_array(jsonb_build_object(''qty'', p_filled_quantity, ''expiry'', s.driver_confirmed_breakdown->0->>''expiry''))' || chr(10)
          || '             ELSE s.driver_confirmed_breakdown END' || chr(10)
          || '     WHERE s.dispatch_id = v_dispatch.m2m_partner_id AND s.action = ''Remove'' AND COALESCE(s.is_m2m, false)' || chr(10)
          || '       AND NOT COALESCE(s.item_added, false) AND NOT COALESCE(s.cancelled, false)' || chr(10)
          || '       AND (s.quantity IS DISTINCT FROM p_filled_quantity' || chr(10)
          || '            OR (s.driver_confirmed_at IS NOT NULL AND s.driver_confirmed_qty IS DISTINCT FROM p_filled_quantity));' || chr(10)
          || '  END IF;' || chr(10)
          || '  UPDATE refill_dispatching' || chr(10)
          || '     SET filled_quantity = p_filled_quantity, item_added = true, dispatched = true, packed = true, picked_up = true,' || chr(10),
          '  UPDATE refill_dispatching' || chr(10)
          || '     SET filled_quantity = p_filled_quantity, item_added = true, dispatched = true, packed = true, picked_up = true,' || chr(10)]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p1_6 rollback: receive_dispatch_line anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.wh_approve_remove_receipt(uuid,numeric,jsonb,uuid,text)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  IF COALESCE(v_dispatch.is_m2m, false) OR v_dispatch.source_kind = ''m2m'' THEN  -- PRD-144 P1-6' || chr(10),
          '  IF COALESCE(v_dispatch.is_m2m, false) THEN' || chr(10)]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p1_6 rollback: wh_approve_remove_receipt anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.approve_m2m_transfer(uuid,uuid)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  PERFORM set_config(''app.rpc_name'',''approve_m2m_transfer'', true);' || chr(10)
          || '  PERFORM set_config(''app.m2m_close'', p_transfer_id::text, true);  -- PRD-144 P1-6' || chr(10),
          '  PERFORM set_config(''app.rpc_name'',''approve_m2m_transfer'', true);' || chr(10)]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p1_6 rollback: approve_m2m_transfer anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.confirm_m2m_delivery(uuid,numeric,numeric,uuid,text)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  PERFORM set_config(''app.rpc_name'', ''confirm_m2m_delivery'', true);' || chr(10)
          || '  PERFORM set_config(''app.m2m_close'', COALESCE(p_transfer_id::text, ''''), true);  -- PRD-144 P1-6' || chr(10),
          '  PERFORM set_config(''app.rpc_name'', ''confirm_m2m_delivery'', true);' || chr(10)]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p1_6 rollback: confirm_m2m_delivery anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.confirm_packed_transferred(uuid,uuid,jsonb)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  PERFORM set_config(''app.m2m_close'', COALESCE(v_src.m2m_transfer_id::text, ''''), true);  -- PRD-144 P1-6' || chr(10) || chr(10)
          || '  -- DEST leg: land the unit in the destination machine''s pod_inventory',
          '  -- DEST leg: land the unit in the destination machine''s pod_inventory']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p1_6 rollback: confirm_packed_transferred anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.receive_all_dispatches_for_machine(uuid,date,boolean)'::regprocedure);
  pairs := ARRAY[
    ARRAY['    -- PRD-144 P1-6: a machine-to-machine source leg is closed by approve_m2m_transfer, never received here.' || chr(10)
          || '    IF v_row.action = ''Remove'' AND (COALESCE(v_row.is_m2m, false) OR v_row.source_kind = ''m2m'') THEN' || chr(10)
          || '      v_skipped_moves := v_skipped_moves || jsonb_build_object(' || chr(10)
          || '        ''dispatch_id'', v_row.dispatch_id,' || chr(10)
          || '        ''shelf_id'',    v_row.shelf_id,' || chr(10)
          || '        ''quantity'',    v_row.quantity,' || chr(10)
          || '        ''reason'',      ''machine-to-machine transfer leg - closed by approve_m2m_transfer, nothing to credit'');' || chr(10)
          || '      CONTINUE;' || chr(10)
          || '    END IF;' || chr(10) || chr(10)
          || '    -- PRD-113 A7: an in-machine move has no warehouse leg.',
          '    -- PRD-113 A7: an in-machine move has no warehouse leg.']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p1_6 rollback: receive_all_dispatches_for_machine anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.resolve_incomplete_dispatch(uuid,date,text,text)'::regprocedure);
  pairs := ARRAY[
    ARRAY['    SELECT rd.dispatch_id, rd.action, rd.quantity, rd.filled_quantity, rd.packed, rd.is_m2m, rd.source_kind' || chr(10),
          '    SELECT rd.dispatch_id, rd.action, rd.quantity, rd.filled_quantity, rd.packed' || chr(10)],
    ARRAY['      ELSIF r.action = ''Remove'' AND p_mode = ''cancel''' || chr(10)
          || '            AND NOT (COALESCE(r.is_m2m, false) OR r.source_kind = ''m2m'') THEN  -- PRD-144 P1-6: M2M legs stay open' || chr(10),
          '      ELSIF r.action = ''Remove'' AND p_mode = ''cancel'' THEN' || chr(10)]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p1_6 rollback: resolve_incomplete_dispatch anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_viewdef('public.v_wm_confirmations'::regclass);
  n := (length(v_def) - length(replace(v_def, '(NOT COALESCE(rd.is_m2m, false)) AND (COALESCE(rd.source_kind, ''unknown''::text) <> ALL (ARRAY[''m2m''::text, ''intra_machine''::text])) AND ', ''))) / length('(NOT COALESCE(rd.is_m2m, false)) AND (COALESCE(rd.source_kind, ''unknown''::text) <> ALL (ARRAY[''m2m''::text, ''intra_machine''::text])) AND ');
  IF n <> 3 THEN RAISE EXCEPTION 'prd144_p1_6 rollback: v_wm_confirmations predicate count %', n; END IF;
  v_def := replace(v_def, '(NOT COALESCE(rd.is_m2m, false)) AND (COALESCE(rd.source_kind, ''unknown''::text) <> ALL (ARRAY[''m2m''::text, ''intra_machine''::text])) AND ', '');
  EXECUTE 'CREATE OR REPLACE VIEW public.v_wm_confirmations AS ' || v_def;
END
$patch$;
