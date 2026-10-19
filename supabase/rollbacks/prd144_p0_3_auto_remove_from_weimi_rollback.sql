-- Rollback for PRD-144 P0-3 (20261019063621_prd144_p0_3_auto_remove_from_weimi).
-- ensure_swap_remove_leg: rebuilt from the PRD-141 item 1 CREATE, then the item 1b and item 22 patches,
-- exactly as they shipped (md5 of the result checked equal to the pre-P0-3 body in a dry run).
-- engine_swap_pod / engine_finalize_pod: each P0-3 anchor reversed (count guarded).
-- weimi_lane_now is left in place (nothing else depends on it once these are restored).

CREATE OR REPLACE FUNCTION public.ensure_swap_remove_leg(p_machine_id uuid, p_shelf_code text, p_new_pod_product_id uuid, p_dispatch_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role       text;
  v_code       text;
  v_shelf_id   uuid;
  v_old_pod    uuid;
  v_onshelf    int;
  v_source     text := 'weimi';
  v_removed    numeric;
  v_planned_old numeric;
  v_need       int;
  v_left       int;
  v_qty        int;
  v_legs       jsonb := '[]'::jsonb;
  v_res        jsonb;
  v_pod_name   text;
  v_new_name   text;
  v_alloc      jsonb := '[]'::jsonb;
  v_fallback   uuid;
  r            record;
BEGIN
  IF auth.uid() IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
    IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'ensure_swap_remove_leg: forbidden for role %', COALESCE(v_role, 'unknown');
    END IF;
  END IF;

  v_code := upper(regexp_replace(trim(p_shelf_code), '^([A-Za-z])([0-9])$', '\1' || '0' || '\2'));
  SELECT shelf_id INTO v_shelf_id FROM public.shelf_configurations
   WHERE machine_id = p_machine_id AND shelf_code = v_code;
  IF v_shelf_id IS NULL THEN
    RETURN jsonb_build_object('status', 'no_shelf', 'shelf_code', v_code);
  END IF;

  -- What is physically on the lane: WEIMI first, slot_lifecycle for the pod if WEIMI has no row.
  SELECT vls.pod_product_id, vls.current_stock INTO v_old_pod, v_onshelf
    FROM public.v_live_shelf_stock vls
   WHERE vls.machine_id = p_machine_id
     AND upper(left(vls.slot_name, 1)) || lpad(regexp_replace(vls.slot_name, '^[A-Za-z]', ''), 2, '0') = v_code
   ORDER BY vls.snapshot_at DESC
   LIMIT 1;
  IF v_old_pod IS NULL THEN
    v_source := 'slot_lifecycle';
    SELECT sl.pod_product_id INTO v_old_pod FROM public.slot_lifecycle sl
     WHERE sl.machine_id = p_machine_id AND sl.shelf_id = v_shelf_id AND sl.is_current AND NOT sl.archived
     ORDER BY sl.rotated_in_at DESC NULLS LAST LIMIT 1;
  END IF;
  IF v_old_pod IS NULL OR v_old_pod = p_new_pod_product_id THEN
    RETURN jsonb_build_object('status', 'not_a_swap', 'shelf_code', v_code, 'lane_pod', v_old_pod);
  END IF;
  IF v_onshelf IS NULL THEN
    v_source := v_source || '+pod_inventory';
    SELECT COALESCE(SUM(pi.current_stock), 0)::int INTO v_onshelf FROM public.pod_inventory pi
     WHERE pi.machine_id = p_machine_id AND pi.shelf_id = v_shelf_id AND pi.status = 'Active'
       AND pi.boonz_product_id IN (SELECT pm.boonz_product_id FROM public.product_mapping pm
                                    WHERE pm.pod_product_id = v_old_pod);
  END IF;
  IF COALESCE(v_onshelf, 0) <= 0 THEN
    RETURN jsonb_build_object('status', 'lane_empty', 'shelf_code', v_code, 'lane_pod', v_old_pod);
  END IF;

  SELECT COALESCE(SUM(rd.quantity) FILTER (WHERE rd.action = 'Remove'), 0),
         COALESCE(SUM(rd.quantity) FILTER (WHERE rd.action IN ('Refill','Add New') AND rd.pod_product_id = v_old_pod), 0)
    INTO v_removed, v_planned_old
    FROM public.refill_dispatching rd
   WHERE rd.machine_id = p_machine_id AND rd.shelf_id = v_shelf_id AND rd.dispatch_date = p_dispatch_date
     AND COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false) AND NOT COALESCE(rd.skipped, false);
  v_need := v_onshelf - GREATEST(v_removed - v_planned_old, 0)::int;
  IF v_need <= 0 THEN
    RETURN jsonb_build_object('status', 'covered', 'shelf_code', v_code, 'on_shelf', v_onshelf,
      'remove_qty', v_removed, 'planned_old_qty', v_planned_old);
  END IF;

  -- Which boonz products leave: Active pod_inventory on the lane that is not the new pod's.
  v_left := v_need;
  FOR r IN
    SELECT pi.boonz_product_id, SUM(pi.current_stock)::int AS stock
      FROM public.pod_inventory pi
     WHERE pi.machine_id = p_machine_id AND pi.shelf_id = v_shelf_id AND pi.status = 'Active'
       AND COALESCE(pi.current_stock, 0) > 0
       AND pi.boonz_product_id NOT IN (SELECT pm.boonz_product_id FROM public.product_mapping pm
                                        WHERE pm.pod_product_id = p_new_pod_product_id AND pm.status = 'Active')
     GROUP BY pi.boonz_product_id
     ORDER BY 2 DESC, 1
  LOOP
    EXIT WHEN v_left <= 0;
    v_qty := LEAST(r.stock, v_left);
    v_alloc := v_alloc || jsonb_build_object('boonz_product_id', r.boonz_product_id, 'qty', v_qty);
    v_left := v_left - v_qty;
  END LOOP;
  IF v_left > 0 THEN
    IF jsonb_array_length(v_alloc) > 0 THEN
      -- WEIMI shows more than pod_inventory: the remainder rides on the largest variant.
      v_alloc := jsonb_set(v_alloc, '{0,qty}', to_jsonb((v_alloc->0->>'qty')::int + v_left));
    ELSE
      SELECT pm.boonz_product_id INTO v_fallback FROM public.product_mapping pm
       WHERE pm.pod_product_id = v_old_pod AND pm.status = 'Active'
         AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)
       ORDER BY (pm.machine_id = p_machine_id) DESC NULLS LAST, COALESCE(pm.split_pct, 0) DESC, pm.boonz_product_id
       LIMIT 1;
      IF v_fallback IS NULL THEN
        INSERT INTO public.monitoring_alerts (source, severity, payload)
        VALUES ('ensure_swap_remove_leg', 'warning', jsonb_build_object(
          'title', format('Swap on %s: lane holds pod %s with %s units but no boonz product resolves for the Remove leg', v_code, v_old_pod, v_onshelf),
          'machine_id', p_machine_id, 'shelf_code', v_code, 'dispatch_date', p_dispatch_date, 'detected_at', now()));
        RETURN jsonb_build_object('status', 'unresolved_product', 'shelf_code', v_code, 'lane_pod', v_old_pod, 'on_shelf', v_onshelf);
      END IF;
      v_alloc := jsonb_build_array(jsonb_build_object('boonz_product_id', v_fallback, 'qty', v_left));
    END IF;
  END IF;

  SELECT pod_product_name INTO v_pod_name FROM public.pod_products WHERE pod_product_id = v_old_pod;
  SELECT pod_product_name INTO v_new_name FROM public.pod_products WHERE pod_product_id = p_new_pod_product_id;
  FOR r IN SELECT (e->>'boonz_product_id')::uuid AS bpid, (e->>'qty')::int AS qty FROM jsonb_array_elements(v_alloc) e LOOP
    v_res := public.add_dispatch_row(
      p_machine_id, v_code, r.bpid, r.qty, 'Remove', p_dispatch_date, 'unknown', NULL, NULL,
      COALESCE(v_role, 'system'),
      format('PRD-141 item 1: auto Remove of %s on %s, lane swapped to %s', v_pod_name, v_code, v_new_name), NULL);
    UPDATE public.refill_dispatching
       SET comment = left(COALESCE(NULLIF(comment, '') || ' | ', '') || format('[auto-remove: swap to %s]', v_new_name), 500)
     WHERE dispatch_id = (v_res->>'dispatch_id')::uuid;
    v_legs := v_legs || jsonb_build_object('dispatch_id', v_res->>'dispatch_id', 'boonz_product_id', r.bpid, 'qty', r.qty);
  END LOOP;

  RETURN jsonb_build_object('status', 'created', 'shelf_code', v_code, 'lane_pod', v_old_pod,
    'on_shelf', v_onshelf, 'source', v_source, 'remove_legs', v_legs);
END;
$function$;

DO $patch$
DECLARE
  v_def text; n int;
  a_old text := '    v_res := public.add_dispatch_row(' || chr(10)
             || '      p_machine_id, v_code, r.bpid, r.qty, ''Remove'', p_dispatch_date, ''unknown'', NULL, NULL,' || chr(10)
             || '      COALESCE(v_role, ''system''),' || chr(10)
             || '      format(''PRD-141 item 1: auto Remove of %s on %s, lane swapped to %s'', v_pod_name, v_code, v_new_name), NULL);';
  a_new text := '    BEGIN' || chr(10)
             || '      v_res := public.add_dispatch_row(' || chr(10)
             || '        p_machine_id, v_code, r.bpid, r.qty, ''Remove'', p_dispatch_date, ''unknown'', NULL, NULL,' || chr(10)
             || '        COALESCE(v_role, ''system''),' || chr(10)
             || '        format(''PRD-141 item 1: auto Remove of %s on %s, lane swapped to %s'', v_pod_name, v_code, v_new_name), NULL);' || chr(10)
             || '    EXCEPTION WHEN OTHERS THEN' || chr(10)
             || '      v_res := NULL;' || chr(10)
             || '      SELECT pm.boonz_product_id INTO v_fallback FROM public.product_mapping pm' || chr(10)
             || '       WHERE pm.pod_product_id = v_old_pod AND pm.status = ''Active'' AND pm.boonz_product_id <> r.bpid' || chr(10)
             || '         AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)' || chr(10)
             || '       ORDER BY (pm.machine_id = p_machine_id) DESC NULLS LAST, COALESCE(pm.split_pct, 0) DESC, pm.boonz_product_id LIMIT 1;' || chr(10)
             || '      IF v_fallback IS NOT NULL THEN' || chr(10)
             || '        BEGIN' || chr(10)
             || '          v_res := public.add_dispatch_row(' || chr(10)
             || '            p_machine_id, v_code, v_fallback, r.qty, ''Remove'', p_dispatch_date, ''unknown'', NULL, NULL,' || chr(10)
             || '            COALESCE(v_role, ''system''),' || chr(10)
             || '            format(''PRD-141 item 1: auto Remove of %s on %s (variant to confirm at warehouse), lane swapped to %s'', v_pod_name, v_code, v_new_name), NULL);' || chr(10)
             || '        EXCEPTION WHEN OTHERS THEN v_res := NULL;' || chr(10)
             || '        END;' || chr(10)
             || '      END IF;' || chr(10)
             || '      IF v_res IS NULL THEN' || chr(10)
             || '        INSERT INTO public.monitoring_alerts (source, severity, payload)' || chr(10)
             || '        VALUES (''ensure_swap_remove_leg'', ''warning'', jsonb_build_object(' || chr(10)
             || '          ''title'', format(''Swap on %s: Remove leg for %s x%s could not be written (%s); add it by hand'', v_code, v_pod_name, r.qty, SQLERRM),' || chr(10)
             || '          ''machine_id'', p_machine_id, ''shelf_code'', v_code, ''dispatch_date'', p_dispatch_date, ''boonz_product_id'', r.bpid, ''detected_at'', now()));' || chr(10)
             || '        v_legs := v_legs || jsonb_build_object(''status'', ''remove_failed'', ''boonz_product_id'', r.bpid, ''qty'', r.qty, ''error'', SQLERRM);' || chr(10)
             || '        CONTINUE;' || chr(10)
             || '      END IF;' || chr(10)
             || '    END;';
BEGIN
  v_def := pg_get_functiondef('public.ensure_swap_remove_leg(uuid,text,uuid,date)'::regprocedure);
  n := (length(v_def) - length(replace(v_def, a_old, ''))) / length(a_old);
  IF n <> 1 THEN RAISE EXCEPTION 'prd141_01b: anchor count %', n; END IF;
  EXECUTE replace(v_def, a_old, a_new);
END
$patch$;

DO $patch$
DECLARE
  v_def text; n int; i int;
  pairs text[][];
BEGIN
  -- ensure_swap_remove_leg (item 1) opens the relabel request for the swap it detected.
  v_def := pg_get_functiondef('public.ensure_swap_remove_leg(uuid,text,uuid,date)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  RETURN jsonb_build_object(''status'', ''created'', ''shelf_code'', v_code, ''lane_pod'', v_old_pod,',
          '  -- PRD-141 item 22: a swap is also a WEIMI relabel to do.' || chr(10)
          || '  INSERT INTO public.weimi_relabel_requests (machine_id, shelf_code, from_pod, to_pod, dispatch_date, source, requested_by)' || chr(10)
          || '  VALUES (p_machine_id, v_code, v_old_pod, p_new_pod_product_id, p_dispatch_date, ''swap'', auth.uid())' || chr(10)
          || '  ON CONFLICT (machine_id, shelf_code, to_pod) WHERE done_at IS NULL DO NOTHING;' || chr(10) || chr(10)
          || '  RETURN jsonb_build_object(''status'', ''created'', ''shelf_code'', v_code, ''lane_pod'', v_old_pod,']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd141_22: ensure_swap_remove_leg anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

DO $patch$
DECLARE
  v_def text; n int; i int; a_old text; a_new text; pairs text[][];
BEGIN
  -- 3. engine_swap_pod
  v_def := pg_get_functiondef('public.engine_swap_pod(date,integer,numeric,integer)'::regprocedure);
  a_old := '  RETURN jsonb_build_object(' || chr(10) || '    ''plan_date'',p_plan_date, ''max_swaps_per_machine'',p_max_swaps_per_machine,';
  a_new := '  -- PRD-144 P0-3: the Remove side of every swap comes from WEIMI (latest weimi_aisle_snapshots row' || chr(10)
        || '  -- for the lane): out pod and qty_out. pod_inventory is never the source. A lane WEIMI shows empty,' || chr(10)
        || '  -- or has no row for, gets no Remove leg: flagged here, skipped by engine_finalize_pod.' || chr(10)
        || '  UPDATE public.pod_swaps ps' || chr(10)
        || '     SET qty_out = CASE WHEN COALESCE(w.current_stock, 0) > 0 THEN w.current_stock ELSE ps.qty_out END,' || chr(10)
        || '         pod_product_id_out = CASE WHEN COALESCE(w.current_stock, 0) > 0 AND w.pod_product_id IS NOT NULL' || chr(10)
        || '                                    AND NOT EXISTS (SELECT 1 FROM public.pod_swaps x' || chr(10)
        || '                                                     WHERE x.plan_date = ps.plan_date AND x.machine_id = ps.machine_id' || chr(10)
        || '                                                       AND x.shelf_id = ps.shelf_id AND x.pod_product_id_out = w.pod_product_id' || chr(10)
        || '                                                       AND x.swap_id <> ps.swap_id)' || chr(10)
        || '                                   THEN w.pod_product_id ELSE ps.pod_product_id_out END,' || chr(10)
        || '         reasoning = ps.reasoning || jsonb_build_object(''remove_source'', ''weimi_aisle_snapshots'',' || chr(10)
        || '                       ''weimi_product'', w.product_name, ''weimi_stock'', COALESCE(w.current_stock, 0), ''weimi_snapshot_at'', w.snapshot_at)' || chr(10)
        || '                     || CASE WHEN COALESCE(w.current_stock, 0) <= 0' || chr(10)
        || '                             THEN jsonb_build_object(''weimi_lane_empty'', true, ''warning'', ''lane empty per WEIMI'')' || chr(10)
        || '                             ELSE ''{}''::jsonb END' || chr(10)
        || '    FROM public.shelf_configurations sc' || chr(10)
        || '    LEFT JOIN LATERAL public.weimi_lane_now(sc.machine_id, sc.shelf_code) w ON true' || chr(10)
        || '   WHERE ps.plan_date = p_plan_date AND sc.shelf_id = ps.shelf_id' || chr(10)
        || '     AND NOT EXISTS (SELECT 1 FROM _committed_machines cm WHERE cm.machine_id = ps.machine_id);' || chr(10) || chr(10)
        || a_old;
  n := (length(v_def) - length(replace(v_def, a_new, ''))) / length(a_new);
  IF n <> 1 THEN RAISE EXCEPTION 'prd144_p0_3 rollback: engine_swap_pod anchor count %', n; END IF;
  EXECUTE replace(v_def, a_new, a_old);

  -- 4. engine_finalize_pod
  v_def := pg_get_functiondef('public.engine_finalize_pod(date,uuid[])'::regprocedure);
  pairs := ARRAY[
    ARRAY['    WHERE ps.plan_date = p_plan_date' || chr(10) || '      AND ps.pod_product_id_in IS NOT NULL' || chr(10)
          || '      AND (p_machine_ids IS NULL OR ps.machine_id = ANY(p_machine_ids))' || chr(10) || '  ),' || chr(10) || '  swap_add_lines AS (',
          '    WHERE ps.plan_date = p_plan_date' || chr(10) || '      AND ps.pod_product_id_in IS NOT NULL' || chr(10)
          || '      AND (p_machine_ids IS NULL OR ps.machine_id = ANY(p_machine_ids))' || chr(10)
          || '      AND NOT COALESCE((ps.reasoning->>''weimi_lane_empty'')::boolean, false)  -- PRD-144 P0-3' || chr(10)
          || '  ),' || chr(10) || '  swap_add_lines AS ('],
    ARRAY['             ''pod_product_id_out'', ps.pod_product_id_out, ''source'',''engine_swap_pod'') AS reasoning,',
          '             ''pod_product_id_out'', ps.pod_product_id_out, ''source'',''engine_swap_pod'',' || chr(10)
          || '             ''warning'', ps.reasoning->>''warning'') AS reasoning,  -- PRD-144 P0-3'],
    ARRAY['    WHERE ps.plan_date = p_plan_date AND ps.pod_product_id_in IS NULL' || chr(10),
          '    WHERE ps.plan_date = p_plan_date AND ps.pod_product_id_in IS NULL' || chr(10)
          || '      AND NOT COALESCE((ps.reasoning->>''weimi_lane_empty'')::boolean, false)  -- PRD-144 P0-3' || chr(10)]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][2], ''))) / length(pairs[i][2]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p0_3 rollback: engine_finalize_pod anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][2], pairs[i][1]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;
REVOKE EXECUTE ON FUNCTION public.ensure_swap_remove_leg(uuid, text, uuid, date) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.ensure_swap_remove_leg(uuid, text, uuid, date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.engine_swap_pod(date, integer, numeric, integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.engine_swap_pod(date, integer, numeric, integer) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.engine_finalize_pod(date, uuid[]) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.engine_finalize_pod(date, uuid[]) TO authenticated, service_role;
