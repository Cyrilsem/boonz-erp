-- Rollback for PRD-144 P2-4: reverses the push_plan_to_dispatch, write_refill_plan, engine_finalize_pod,
-- add_dispatch_row and receive_dispatch_line anchors, then drops lane_supply_origin. No data to restore: the
-- migration only changes how new Remove legs are tagged. Remove legs written while it was live keep
-- source_kind='venue'; under the rolled-back receive they fall back to the product_mapping rule.
DO $patch$
DECLARE
  v_def text; n int; i int; pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.push_plan_to_dispatch(date,text)'::regprocedure);
  pairs := ARRAY[
    ARRAY['    IF v_action IN (''Remove'',''Machine To Warehouse'') THEN' || chr(10)
          || '      -- PRD-144 P2-4: a Remove on a lane last filled from venue stock returns venue stock, never Boonz warehouse stock.' || chr(10)
          || '      IF v_source_kind IN (''wh'', ''unknown'') AND public.lane_supply_origin(v_machine_id, v_shelf_id) = ''vox_at_venue'' THEN' || chr(10)
          || '        v_source_kind := ''venue'';' || chr(10)
          || '      END IF;' || chr(10)
          || '      SELECT w.current_stock INTO v_lane_weimi_stock' || chr(10),
          '    IF v_action IN (''Remove'',''Machine To Warehouse'') THEN' || chr(10) || '      SELECT w.current_stock INTO v_lane_weimi_stock' || chr(10)],
    ARRAY['        CASE WHEN v_source_kind = ''venue'' THEN NULL ELSE v_primary_warehouse_id END, NULL, v_remove_lot_expiry, false,' || chr(10)
          || '        CASE WHEN v_source_kind = ''venue'' THEN ''vox_at_venue''::public.source_origin_enum' || chr(10)
          || '             ELSE COALESCE(line.source_origin, ''warehouse''::public.source_origin_enum) END,' || chr(10),
          '        v_primary_warehouse_id, NULL, v_remove_lot_expiry, false,' || chr(10)
          || '        COALESCE(line.source_origin, ''warehouse''::public.source_origin_enum),' || chr(10)]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p2_4 rollback: push_plan_to_dispatch anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.write_refill_plan(date,jsonb)'::regprocedure);
  pairs := ARRAY[
    ARRAY['      CASE WHEN COALESCE(line->>''action'', ''Refill'') IN (''Remove'', ''Machine To Warehouse'')  -- PRD-144 P2-4' || chr(10)
          || '             AND COALESCE(NULLIF(line->>''source_origin'', ''''), ''warehouse'') IN (''warehouse'', ''unknown'')' || chr(10)
          || '             AND public.lane_supply_origin(' || chr(10)
          || '                   (SELECT m.machine_id FROM public.machines m WHERE m.official_name = line->>''machine_name'' LIMIT 1),' || chr(10)
          || '                   (SELECT sc.shelf_id FROM public.shelf_configurations sc' || chr(10)
          || '                      JOIN public.machines m2 ON m2.machine_id = sc.machine_id AND m2.official_name = line->>''machine_name''' || chr(10)
          || '                     WHERE sc.shelf_code = upper(left(line->>''shelf_code'', 1)) || lpad(substr(line->>''shelf_code'', 2), 2, ''0'')' || chr(10)
          || '                     LIMIT 1)) = ''vox_at_venue''' || chr(10)
          || '           THEN ''vox_at_venue''::public.source_origin_enum' || chr(10)
          || '           ELSE COALESCE(NULLIF(line->>''source_origin'','''')::public.source_origin_enum, ''warehouse''::public.source_origin_enum) END,' || chr(10),
          '      COALESCE(NULLIF(line->>''source_origin'','''')::public.source_origin_enum, ''warehouse''::public.source_origin_enum),' || chr(10)]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p2_4 rollback: write_refill_plan anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.engine_finalize_pod(date,uuid[])'::regprocedure);
  pairs := ARRAY[
    ARRAY['           CASE WHEN u.action IN (''REMOVE'', ''M2W'') AND public.lane_supply_origin(u.machine_id, u.shelf_id) = ''vox_at_venue''' || chr(10)
          || '                THEN ''vox_at_venue''::public.source_origin_enum  -- PRD-144 P2-4' || chr(10)
          || '           ELSE COALESCE((' || chr(10) || '             SELECT CASE WHEN bool_and(x.source_of_supply = ''venue_team'')',
          '           COALESCE((' || chr(10) || '             SELECT CASE WHEN bool_and(x.source_of_supply = ''venue_team'')'],
    ARRAY['           ), ''warehouse''::public.source_origin_enum) END' || chr(10) || '      FROM unioned u',
          '           ), ''warehouse''::public.source_origin_enum)' || chr(10) || '      FROM unioned u']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p2_4 rollback: engine_finalize_pod anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.add_dispatch_row(uuid,text,uuid,numeric,text,date,text,uuid,uuid,text,text,text,uuid)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  v_swap_remove       jsonb;' || chr(10) || '  v_venue_rm          boolean := false;  -- PRD-144 P2-4' || chr(10),
          '  v_swap_remove       jsonb;' || chr(10)],
    ARRAY['  -- branches are deleted, same fix as push_plan_to_dispatch).' || chr(10)
          || '  -- PRD-144 P2-4: a Remove on a lane last filled from venue stock is a venue return (source_kind venue).' || chr(10)
          || '  v_venue_rm := p_source_kind IN (''wh'', ''unknown'')' || chr(10)
          || '                AND public.lane_supply_origin(p_machine_id, v_shelf_id) IS NOT DISTINCT FROM ''vox_at_venue''::public.source_origin_enum;' || chr(10),
          '  -- branches are deleted, same fix as push_plan_to_dispatch).' || chr(10)],
    ARRAY['     CASE WHEN v_venue_rm THEN ''venue'' ELSE p_source_kind END,' || chr(10)
          || '     CASE WHEN v_venue_rm THEN NULL ELSE p_source_warehouse_id END, p_source_machine_id,' || chr(10)
          || '     (p_source_kind = ''truck_transfer'' OR p_source_kind = ''m2m''), true,' || chr(10)
          || '     CASE WHEN p_source_kind = ''wh'' AND NOT v_venue_rm THEN p_source_warehouse_id ELSE NULL END, v_lot_expiry, v_lot_id,' || chr(10)
          || '     CASE WHEN v_venue_rm THEN ''vox_at_venue''::public.source_origin_enum ELSE v_source_origin END,' || chr(10),
          '     p_source_kind, p_source_warehouse_id, p_source_machine_id,' || chr(10)
          || '     (p_source_kind = ''truck_transfer'' OR p_source_kind = ''m2m''), true,' || chr(10)
          || '     CASE WHEN p_source_kind = ''wh'' THEN p_source_warehouse_id ELSE NULL END, v_lot_expiry, v_lot_id,' || chr(10)
          || '     v_source_origin,' || chr(10)]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p2_4 rollback: add_dispatch_row anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.receive_dispatch_line(uuid,numeric,uuid,jsonb,boolean,text)'::regprocedure);
  pairs := ARRAY[
    ARRAY['    ELSIF v_supply = ''venue_team'' OR v_dispatch.source_kind = ''venue'' THEN  -- PRD-144 P2-4: a venue Remove never credits a Boonz warehouse' || chr(10),
          '    ELSIF v_supply = ''venue_team'' THEN' || chr(10)],
    ARRAY['WHEN v_supply = ''venue_team'' THEN ''venue_team'' WHEN v_dispatch.source_kind = ''venue'' THEN ''venue'' ELSE NULL END',
          'WHEN v_supply = ''venue_team'' THEN ''venue_team'' ELSE NULL END']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p2_4 rollback: receive_dispatch_line anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;
DROP FUNCTION public.lane_supply_origin(uuid, uuid);
