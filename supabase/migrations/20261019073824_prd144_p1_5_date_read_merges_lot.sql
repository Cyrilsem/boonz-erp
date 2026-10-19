-- PRD-144 P1-5: "Date read" merges into an existing lot instead of colliding with it.
-- apply_expiry_check(date_read) calls correct_expiry_v1('pod', ...), which archived the no-date row and
-- inserted a new Active row with the read date. When an Active lot already existed for the same machine,
-- shelf, product and date, that insert hit idx_pod_inv_active_shelf_expiry (MINDSHARE-1009 A09 Loacker
-- Creamkakao, 19 Oct). The pod branch now adds the quantity to that lot and archives the source row
-- (stock 0, Inactive), with both changes in pod_inventory_audit_log. split_pod_lot already merges this way
-- (P1-3). adjust_pod_inventory is a recount: it finds the lot by the same key and sets its count, so it
-- cannot hit the index and keeps its semantics.
-- Both functions also stop taking the role from a caller-supplied id: with a signed-in caller,
-- p_caller_id / p_actor must be that caller (service-role calls without a session are unchanged).
DO $patch$
DECLARE
  v_def text; n int; i int; pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.correct_expiry_v1(text,uuid,date,text,uuid,boolean,boolean)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  v_new_pod_id uuid;' || chr(10) || 'BEGIN' || chr(10),
          '  v_new_pod_id uuid;' || chr(10)
          || '  v_sib pod_inventory%ROWTYPE;  -- PRD-144 P1-5' || chr(10)
          || 'BEGIN' || chr(10)
          || '  IF auth.uid() IS NOT NULL AND p_caller_id IS NOT NULL AND p_caller_id <> auth.uid() THEN' || chr(10)
          || '    RAISE EXCEPTION ''correct_expiry_v1: p_caller_id must be the signed-in user'';' || chr(10)
          || '  END IF;' || chr(10)],
    ARRAY['    UPDATE pod_inventory SET status = ''Inactive'', removal_reason = format(''expiry_corrected_by_%s'', COALESCE(v_user_id::text,''system'')), snapshot_at = now()' || chr(10)
          || '     WHERE pod_inventory_id = p_row_id;' || chr(10),
          '    -- PRD-144 P1-5: an Active lot already carrying the new date absorbs this one.' || chr(10)
          || '    SELECT * INTO v_sib FROM pod_inventory' || chr(10)
          || '     WHERE machine_id = v_pod.machine_id AND shelf_id IS NOT DISTINCT FROM v_pod.shelf_id' || chr(10)
          || '       AND boonz_product_id = v_pod.boonz_product_id AND status = ''Active''' || chr(10)
          || '       AND expiration_date = p_new_expiry AND pod_inventory_id <> p_row_id' || chr(10)
          || '     FOR UPDATE;' || chr(10)
          || '    IF FOUND THEN' || chr(10)
          || '      UPDATE pod_inventory SET current_stock = 0, estimated_remaining = 0, status = ''Inactive'',' || chr(10)
          || '             removal_reason = format(''expiry_merged_into_%s'', v_sib.pod_inventory_id), snapshot_at = now()' || chr(10)
          || '       WHERE pod_inventory_id = p_row_id;' || chr(10)
          || '      UPDATE pod_inventory SET current_stock = current_stock + COALESCE(v_pod.current_stock, 0),' || chr(10)
          || '             estimated_remaining = COALESCE(estimated_remaining, current_stock) + COALESCE(v_pod.current_stock, 0), snapshot_at = now()' || chr(10)
          || '       WHERE pod_inventory_id = v_sib.pod_inventory_id;' || chr(10)
          || '      INSERT INTO pod_inventory_audit_log (pod_inventory_id, machine_id, shelf_id, boonz_product_id, expiration_date, source, operation,' || chr(10)
          || '        old_stock, new_stock, delta, old_status, new_status, actor, reference_id, notes)' || chr(10)
          || '      VALUES (p_row_id, v_pod.machine_id, v_pod.shelf_id, v_pod.boonz_product_id, v_old_expiry, ''correction'', ''update'',' || chr(10)
          || '        v_pod.current_stock, 0, -COALESCE(v_pod.current_stock, 0), v_pod.status, ''Inactive'', v_user_id,' || chr(10)
          || '        format(''correct_expiry_v1-%s'', p_row_id), format(''expiry read as %s; merged into lot %s: %s'', p_new_expiry, v_sib.pod_inventory_id, p_reason)),' || chr(10)
          || '             (v_sib.pod_inventory_id, v_pod.machine_id, v_pod.shelf_id, v_pod.boonz_product_id, p_new_expiry, ''correction'', ''update'',' || chr(10)
          || '        v_sib.current_stock, v_sib.current_stock + COALESCE(v_pod.current_stock, 0), COALESCE(v_pod.current_stock, 0), ''Active'', ''Active'', v_user_id,' || chr(10)
          || '        format(''correct_expiry_v1-%s'', p_row_id), format(''+%s from lot %s (expiry read as %s): %s'', v_pod.current_stock, p_row_id, p_new_expiry, p_reason));' || chr(10)
          || '      RETURN jsonb_build_object(''status'',''ok'',''scope'',p_scope,''old_row_id'',p_row_id,''merged_into'',v_sib.pod_inventory_id,' || chr(10)
          || '        ''old_expiry'',v_old_expiry,''new_expiry'',p_new_expiry,''current_stock'',v_pod.current_stock,' || chr(10)
          || '        ''merged_lot_stock'', v_sib.current_stock + COALESCE(v_pod.current_stock, 0),''reason'',p_reason);' || chr(10)
          || '    END IF;' || chr(10)
          || '    UPDATE pod_inventory SET status = ''Inactive'', removal_reason = format(''expiry_corrected_by_%s'', COALESCE(v_user_id::text,''system'')), snapshot_at = now()' || chr(10)
          || '     WHERE pod_inventory_id = p_row_id;' || chr(10)]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p1_5: correct_expiry_v1 anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.apply_expiry_check(uuid,text,numeric,date,uuid,boolean)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  v_user_id uuid := COALESCE(p_actor, auth.uid());',
          '  v_user_id uuid := COALESCE(auth.uid(), p_actor);  -- PRD-144 P1-5: the session decides the role'],
    ARRAY['  IF v_user_id IS NULL THEN RAISE EXCEPTION ''apply_expiry_check: anonymous caller refused''; END IF;',
          '  IF v_user_id IS NULL THEN RAISE EXCEPTION ''apply_expiry_check: anonymous caller refused''; END IF;' || chr(10)
          || '  IF auth.uid() IS NOT NULL AND p_actor IS NOT NULL AND p_actor <> auth.uid() THEN' || chr(10)
          || '    RAISE EXCEPTION ''apply_expiry_check: p_actor must be the signed-in user'';' || chr(10)
          || '  END IF;']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p1_5: apply_expiry_check anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;
REVOKE EXECUTE ON FUNCTION public.correct_expiry_v1(text, uuid, date, text, uuid, boolean, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.correct_expiry_v1(text, uuid, date, text, uuid, boolean, boolean) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.apply_expiry_check(uuid, text, numeric, date, uuid, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.apply_expiry_check(uuid, text, numeric, date, uuid, boolean) TO authenticated, service_role;