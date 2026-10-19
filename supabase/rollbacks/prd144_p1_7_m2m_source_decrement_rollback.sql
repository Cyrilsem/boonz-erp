-- Rollback for PRD-144 P1-7 part 1: an M2M source receive archives the lane's lots again. Lots already decremented
-- while it was live keep their quantities.
DO $patch$
DECLARE
  v_def text; n int; i int; pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.receive_dispatch_line(uuid,numeric,uuid,jsonb,boolean,text)'::regprocedure);
  pairs := ARRAY[
    ARRAY['    IF COALESCE(v_dispatch.is_m2m, false) THEN' || chr(10)
          || '      -- PRD-144 P1-7: an M2M source leg removes only the moved units, earliest expiry first.' || chr(10)
          || '      v_need := p_filled_quantity;' || chr(10)
          || '      FOR v_fefo IN' || chr(10)
          || '        SELECT pi.pod_inventory_id, COALESCE(pi.current_stock, 0) AS stock FROM pod_inventory pi' || chr(10)
          || '         WHERE pi.machine_id = v_dispatch.machine_id AND pi.boonz_product_id = v_dispatch.boonz_product_id' || chr(10)
          || '           AND pi.shelf_id IS NOT DISTINCT FROM v_dispatch.shelf_id AND pi.status = ''Active''' || chr(10)
          || '         ORDER BY pi.expiration_date ASC NULLS LAST, pi.created_at ASC' || chr(10)
          || '         FOR UPDATE' || chr(10)
          || '      LOOP' || chr(10)
          || '        EXIT WHEN v_need <= 0;' || chr(10)
          || '        v_take := LEAST(v_need, GREATEST(v_fefo.stock, 0));' || chr(10)
          || '        IF v_take <= 0 THEN CONTINUE; END IF;' || chr(10)
          || '        UPDATE pod_inventory' || chr(10)
          || '           SET current_stock = current_stock - v_take,' || chr(10)
          || '               estimated_remaining = GREATEST(COALESCE(estimated_remaining, current_stock) - v_take, 0),' || chr(10)
          || '               status = CASE WHEN current_stock - v_take <= 0 THEN ''Inactive'' ELSE status END,' || chr(10)
          || '               removal_reason = CASE WHEN current_stock - v_take <= 0 THEN format(''moved_via_m2m_%s'', p_dispatch_id) ELSE removal_reason END,' || chr(10)
          || '               snapshot_at = now()' || chr(10)
          || '         WHERE pod_inventory_id = v_fefo.pod_inventory_id;' || chr(10)
          || '        IF v_fefo.stock - v_take <= 0 THEN v_pod_archived := v_pod_archived + 1; END IF;' || chr(10)
          || '        v_need := v_need - v_take;' || chr(10)
          || '      END LOOP;' || chr(10)
          || '    ELSE' || chr(10)
          || '    UPDATE pod_inventory SET status = ''Inactive'', removal_reason = format(''removed_via_dispatch_%s'', p_dispatch_id) WHERE machine_id = v_dispatch.machine_id AND boonz_product_id = v_dispatch.boonz_product_id AND (shelf_id = v_dispatch.shelf_id OR v_dispatch.shelf_id IS NULL) AND status = ''Active'';' || chr(10)
          || '    GET DIAGNOSTICS v_pod_archived = ROW_COUNT;' || chr(10)
          || '    END IF;' || chr(10),
          '    UPDATE pod_inventory SET status = ''Inactive'', removal_reason = format(''removed_via_dispatch_%s'', p_dispatch_id) WHERE machine_id = v_dispatch.machine_id AND boonz_product_id = v_dispatch.boonz_product_id AND (shelf_id = v_dispatch.shelf_id OR v_dispatch.shelf_id IS NULL) AND status = ''Active'';' || chr(10)
          || '    GET DIAGNOSTICS v_pod_archived = ROW_COUNT;' || chr(10)]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p1_7 rollback: receive_dispatch_line anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;
