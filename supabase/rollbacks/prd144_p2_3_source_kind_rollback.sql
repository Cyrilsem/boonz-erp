-- Rollback for PRD-144 P2-3: reverses the pack_dispatch_line and receive_dispatch_line anchors and puts the
-- 35 WH_DFC placeholder rows back to batch NULL / expiry 2029-09-27.
DO $patch$
DECLARE
  v_def text; n int; i int; pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.pack_dispatch_line(uuid,jsonb,uuid)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  -- ===== v2 VOX GUARD: venue-supplied lines may only draw from 2099 placeholder rows =====' || chr(10),
          '  -- PRD-144 P2-3: venue, m2m and intra_machine lines move nothing in warehouse_inventory at pack.' || chr(10)
          || '  IF COALESCE(v_dispatch.source_kind, ''unknown'') IN (''venue'', ''m2m'', ''intra_machine'') THEN' || chr(10)
          || '    SELECT COALESCE(SUM((p->>''qty'')::numeric), 0) INTO v_total_picked FROM jsonb_array_elements(p_picks) p;' || chr(10)
          || '    IF v_total_picked < 1 THEN' || chr(10)
          || '      UPDATE refill_dispatching' || chr(10)
          || '         SET pack_outcome = ''not_filled'', filled_quantity = 0, original_quantity = COALESCE(original_quantity, quantity),' || chr(10)
          || '             not_filled_reason = COALESCE(NULLIF((SELECT p->>''reason'' FROM jsonb_array_elements(p_picks) p WHERE NULLIF(p->>''reason'','''') IS NOT NULL LIMIT 1), ''''), ''not filled at pack time''),' || chr(10)
          || '             bind_fail_reason = NULL, bind_fail_at = NULL' || chr(10)
          || '       WHERE dispatch_id = p_dispatch_id;' || chr(10)
          || '      RETURN jsonb_build_object(''status'', ''not_filled'', ''dispatch_id'', p_dispatch_id, ''planned_quantity'', v_dispatch.quantity,' || chr(10)
          || '                                ''filled_quantity'', 0, ''pack_outcome'', ''not_filled'', ''warehouse_moved'', false);' || chr(10)
          || '    END IF;' || chr(10)
          || '    IF v_total_picked > v_dispatch.quantity THEN RAISE EXCEPTION ''Pick total (%) exceeds planned quantity (%)'', v_total_picked, v_dispatch.quantity; END IF;' || chr(10)
          || '    UPDATE refill_dispatching' || chr(10)
          || '       SET packed = true, filled_quantity = v_total_picked, original_quantity = COALESCE(original_quantity, quantity),' || chr(10)
          || '           pack_outcome = (CASE WHEN v_total_picked < quantity THEN ''partial'' ELSE ''packed'' END)::public.pack_outcome_enum,' || chr(10)
          || '           bind_fail_reason = NULL, bind_fail_at = NULL' || chr(10)
          || '     WHERE dispatch_id = p_dispatch_id;' || chr(10)
          || '    RETURN jsonb_build_object(''status'', ''packed'', ''dispatch_id'', p_dispatch_id, ''total_picked'', v_total_picked,' || chr(10)
          || '      ''planned_quantity'', v_dispatch.quantity, ''pack_outcome'', CASE WHEN v_total_picked < v_dispatch.quantity THEN ''partial'' ELSE ''packed'' END,' || chr(10)
          || '      ''warehouse_moved'', false, ''source_kind'', v_dispatch.source_kind);' || chr(10)
          || '  END IF;' || chr(10) || chr(10)
          || '  -- ===== v2 VOX GUARD: venue-supplied lines may only draw from 2099 placeholder rows =====' || chr(10)]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][2], ''))) / length(pairs[i][2]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p2_3 rollback: pack_dispatch_line anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][2], pairs[i][1]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.receive_dispatch_line(uuid,numeric,uuid,jsonb,boolean,text)'::regprocedure);
  pairs := ARRAY[
    ARRAY['   IF NOT COALESCE(v_dispatch.is_m2m, false) THEN' || chr(10),
          '   -- PRD-144 P2-3: only warehouse-sourced lines draw warehouse stock; venue, m2m and intra_machine lines do not.' || chr(10)
          || '   IF NOT COALESCE(v_dispatch.is_m2m, false)' || chr(10)
          || '      AND COALESCE(v_dispatch.source_kind, ''unknown'') NOT IN (''venue'', ''m2m'', ''intra_machine'') THEN' || chr(10)],
    ARRAY['     v_path := ''add_m2m_no_wh_draw'';' || chr(10),
          '     v_path := CASE WHEN COALESCE(v_dispatch.is_m2m, false) THEN ''add_m2m_no_wh_draw''' || chr(10)
          || '                    ELSE format(''add_%s_no_wh_draw'', v_dispatch.source_kind) END;' || chr(10)],
    ARRAY['    IF COALESCE(v_dispatch.is_m2m, false) THEN' || chr(10) || '      v_path := ''remove_m2m_no_wh_credit'';' || chr(10),
          '    IF COALESCE(v_dispatch.is_m2m, false) THEN' || chr(10) || '      v_path := ''remove_m2m_no_wh_credit'';' || chr(10)
          || '    ELSIF v_dispatch.source_kind = ''intra_machine'' THEN  -- PRD-144 P2-3' || chr(10)
          || '      v_path := ''remove_intra_machine_no_wh_credit'';' || chr(10)]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][2], ''))) / length(pairs[i][2]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p2_3 rollback: receive_dispatch_line anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][2], pairs[i][1]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;
REVOKE EXECUTE ON FUNCTION public.pack_dispatch_line(uuid, jsonb, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.pack_dispatch_line(uuid, jsonb, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.receive_dispatch_line(uuid, numeric, uuid, jsonb, boolean, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.receive_dispatch_line(uuid, numeric, uuid, jsonb, boolean, text) TO authenticated, service_role;

DO $fix$
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'prd144_p2_3_rollback', true);
  UPDATE public.warehouse_inventory wi SET expiration_date = DATE '2029-09-27', batch_id = NULL
    FROM public.warehouses w
   WHERE w.warehouse_id = wi.warehouse_id AND w.name = 'WH_DFC' AND wi.batch_id LIKE 'VOXSOURCE-WH_DFC-%-999'
     AND wi.expiration_date = DATE '2099-12-31';
END
$fix$;
