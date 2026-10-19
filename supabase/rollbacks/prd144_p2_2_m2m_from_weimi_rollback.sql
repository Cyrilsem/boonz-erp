-- Rollback for PRD-144 P2-2: reverses the add_dispatch_row and push_plan_to_dispatch anchors.
DO $patch$
DECLARE
  v_def text; n int; i int; pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.add_dispatch_row(uuid,text,uuid,numeric,text,date,text,uuid,uuid,text,text,text,uuid)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  v_swap_remove       jsonb;' || chr(10),
          '  v_swap_remove       jsonb;' || chr(10)
          || '  v_w                 record;   -- PRD-144 P2-2' || chr(10)
          || '  v_src_code          text;' || chr(10)
          || '  v_pod_units         numeric;' || chr(10)],
    ARRAY['    IF NOT EXISTS (' || chr(10)
          || '      SELECT 1 FROM public.pod_inventory' || chr(10)
          || '      WHERE machine_id = p_source_machine_id' || chr(10)
          || '        AND boonz_product_id = p_boonz_product_id' || chr(10)
          || '        AND status = ''Active'' AND current_stock > 0' || chr(10)
          || '    ) THEN' || chr(10),
          '    -- PRD-144 P2-2: the pod_inventory gate that stood here is replaced by the WEIMI check below.' || chr(10)
          || '    IF false THEN' || chr(10)],
    ARRAY['    v_transfer_id := gen_random_uuid();' || chr(10) || '  END IF;',
          '    -- PRD-144 P2-2: the source lane (the partner Remove''s shelf) must hold the product per WEIMI.' || chr(10)
          || '    SELECT shelf_code INTO v_src_code FROM public.shelf_configurations WHERE shelf_id = v_partner.shelf_id;' || chr(10)
          || '    SELECT official_name INTO v_src_name FROM public.machines WHERE machine_id = p_source_machine_id;' || chr(10)
          || '    SELECT boonz_product_name INTO v_bp_name FROM public.boonz_products WHERE product_id = p_boonz_product_id;' || chr(10)
          || '    SELECT * INTO v_w FROM public.weimi_lane_now(p_source_machine_id, v_src_code);' || chr(10)
          || '    IF NOT FOUND OR COALESCE(v_w.current_stock, 0) <= 0 THEN' || chr(10)
          || '      RAISE EXCEPTION ''Source lane % on % is empty per WEIMI; nothing to transfer'', v_src_code, COALESCE(v_src_name, p_source_machine_id::text);' || chr(10)
          || '    END IF;' || chr(10)
          || '    IF v_w.pod_product_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.product_mapping pm' || chr(10)
          || '         WHERE pm.pod_product_id = v_w.pod_product_id AND pm.boonz_product_id = p_boonz_product_id AND pm.status = ''Active''' || chr(10)
          || '           AND (pm.machine_id = p_source_machine_id OR pm.machine_id IS NULL)) THEN' || chr(10)
          || '      RAISE EXCEPTION ''WEIMI shows % on source lane % of %, which is not mapped to %'', COALESCE(v_w.product_name, ''nothing''), v_src_code,' || chr(10)
          || '        COALESCE(v_src_name, p_source_machine_id::text), COALESCE(v_bp_name, p_boonz_product_id::text);' || chr(10)
          || '    END IF;' || chr(10)
          || '    IF p_quantity > v_w.current_stock THEN' || chr(10)
          || '      RAISE EXCEPTION ''Transfer of % exceeds the % WEIMI shows on source lane % of %'', p_quantity, v_w.current_stock, v_src_code,' || chr(10)
          || '        COALESCE(v_src_name, p_source_machine_id::text);' || chr(10)
          || '    END IF;' || chr(10)
          || '    SELECT COALESCE(SUM(pi.current_stock), 0) INTO v_pod_units FROM public.pod_inventory pi' || chr(10)
          || '     WHERE pi.machine_id = p_source_machine_id AND pi.shelf_id = v_partner.shelf_id AND pi.status = ''Active''' || chr(10)
          || '       AND pi.boonz_product_id IN (SELECT pm.boonz_product_id FROM public.product_mapping pm WHERE pm.pod_product_id = v_w.pod_product_id);' || chr(10)
          || '    IF v_pod_units <> v_w.current_stock THEN' || chr(10)
          || '      INSERT INTO public.monitoring_alerts (source, severity, payload)' || chr(10)
          || '      VALUES (''m2m_pod_weimi_drift'', ''warning'', jsonb_build_object(' || chr(10)
          || '        ''title'', format(''M2M from %s %s: pod lots show %s, WEIMI %s; transfer uses WEIMI'', COALESCE(v_src_name, p_source_machine_id::text), v_src_code, v_pod_units, v_w.current_stock),' || chr(10)
          || '        ''machine_id'', p_source_machine_id, ''shelf_code'', v_src_code, ''pod_units'', v_pod_units, ''weimi_units'', v_w.current_stock,' || chr(10)
          || '        ''writer'', ''add_dispatch_row'', ''detected_at'', now()));' || chr(10)
          || '    END IF;' || chr(10)
          || '    v_transfer_id := gen_random_uuid();' || chr(10) || '  END IF;']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][2], ''))) / length(pairs[i][2]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p2_2 rollback: add_dispatch_row anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][2], pairs[i][1]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.push_plan_to_dispatch(date,text)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  v_lane_weimi_stock     int;' || chr(10),
          '  v_lane_weimi_stock     int;' || chr(10)
          || '  v_m2m_w                record;   -- PRD-144 P2-2' || chr(10)
          || '  v_m2m_qty              numeric;' || chr(10)
          || '  v_m2m_pod              numeric;' || chr(10)],
    ARRAY['        v_transfer_id := gen_random_uuid();' || chr(10) || '        v_first_remove_id := NULL;' || chr(10),
          '        -- PRD-144 P2-2: what moves is what WEIMI shows on the source lane; pod lots only raise drift.' || chr(10)
          || '        SELECT * INTO v_m2m_w FROM public.weimi_lane_now(v_src_machine_id, v_src_normalized_shelf);' || chr(10)
          || '        IF NOT FOUND OR COALESCE(v_m2m_w.current_stock, 0) <= 0 THEN' || chr(10)
          || '          v_transfer_skipped := v_transfer_skipped + 1;' || chr(10)
          || '          INSERT INTO public.monitoring_alerts (source, severity, payload)' || chr(10)
          || '          VALUES (''m2m_push_lane_empty_weimi'', ''warning'', jsonb_build_object(' || chr(10)
          || '            ''title'', format(''M2M not pushed: source lane %s is empty per WEIMI (%s @ %s)'', v_src_normalized_shelf, line.boonz_product_name, p_machine_name),' || chr(10)
          || '            ''plan_line_id'', line.id, ''plan_date'', p_plan_date, ''from_machine_id'', v_src_machine_id, ''detected_at'', now()));' || chr(10)
          || '          CONTINUE;' || chr(10)
          || '        END IF;' || chr(10)
          || '        v_m2m_qty := LEAST(line.quantity, v_m2m_w.current_stock);' || chr(10)
          || '        IF v_m2m_qty < line.quantity THEN' || chr(10)
          || '          INSERT INTO public.monitoring_alerts (source, severity, payload)' || chr(10)
          || '          VALUES (''m2m_push_capped_to_weimi'', ''warning'', jsonb_build_object(' || chr(10)
          || '            ''title'', format(''M2M %s @ %s: plan %s, WEIMI shows %s on %s; transfer capped to WEIMI'', line.boonz_product_name, p_machine_name, line.quantity, v_m2m_w.current_stock, v_src_normalized_shelf),' || chr(10)
          || '            ''plan_line_id'', line.id, ''plan_date'', p_plan_date, ''from_machine_id'', v_src_machine_id, ''detected_at'', now()));' || chr(10)
          || '        END IF;' || chr(10)
          || '        SELECT COALESCE(SUM(pi.current_stock), 0) INTO v_m2m_pod FROM public.pod_inventory pi' || chr(10)
          || '         WHERE pi.machine_id = v_src_machine_id AND pi.shelf_id = v_src_shelf_id AND pi.status = ''Active''' || chr(10)
          || '           AND pi.boonz_product_id IN (SELECT pm.boonz_product_id FROM public.product_mapping pm WHERE pm.pod_product_id = v_m2m_w.pod_product_id);' || chr(10)
          || '        IF v_m2m_pod <> v_m2m_w.current_stock THEN' || chr(10)
          || '          INSERT INTO public.monitoring_alerts (source, severity, payload)' || chr(10)
          || '          VALUES (''m2m_pod_weimi_drift'', ''warning'', jsonb_build_object(' || chr(10)
          || '            ''title'', format(''M2M from %s: pod lots show %s, WEIMI %s; transfer uses WEIMI'', v_src_normalized_shelf, v_m2m_pod, v_m2m_w.current_stock),' || chr(10)
          || '            ''machine_id'', v_src_machine_id, ''shelf_code'', v_src_normalized_shelf, ''pod_units'', v_m2m_pod, ''weimi_units'', v_m2m_w.current_stock,' || chr(10)
          || '            ''writer'', ''push_plan_to_dispatch'', ''detected_at'', now()));' || chr(10)
          || '        END IF;' || chr(10) || chr(10)
          || '        v_transfer_id := gen_random_uuid();' || chr(10) || '        v_first_remove_id := NULL;' || chr(10)],
    ARRAY['          line.plan_date, ''Remove'', line.quantity, true,',
          '          line.plan_date, ''Remove'', v_m2m_qty, true,  -- PRD-144 P2-2: WEIMI-capped']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][2], ''))) / length(pairs[i][2]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p2_2 rollback: push_plan_to_dispatch anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][2], pairs[i][1]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;
REVOKE EXECUTE ON FUNCTION public.add_dispatch_row(uuid,text,uuid,numeric,text,date,text,uuid,uuid,text,text,text,uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.add_dispatch_row(uuid,text,uuid,numeric,text,date,text,uuid,uuid,text,text,text,uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.push_plan_to_dispatch(date, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.push_plan_to_dispatch(date, text) TO authenticated, service_role;
