-- PRD-141 items 0 and 1 (A0, A1): every swap is two rows, in and out.
-- ensure_swap_remove_leg(machine, shelf_code, new_pod, date): when a lane that physically holds a
-- different pod product gets an Add New, write the missing Remove leg(s) for the on-shelf quantity
-- (WEIMI current_stock; pod_inventory when WEIMI has no row) through add_dispatch_row, so the
-- outgoing product goes through driver_confirm_remove -> Warehouse Confirmations like any Remove.
-- Idempotent: covered = Remove qty already on the lane and date minus planned deliveries of the OLD
-- pod there (swap_shelf_pod nets those with a Remove of the planned qty); only the gap is written.
-- Called from:
--   * add_dispatch_row, every Add New (FE Add Product on Packing and Dispatch Detail, driver
--     additions via driver_add_flagged_row, the Packing Swap sheet via swap_shelf_pod /
--     swap_dispatch_shelf). The Packing Swap only wrote Removes for TODAY'S PLANNED qty of the
--     old pod, so a swap on a lane that was not in the plan wrote Add New and no Remove (A0).
--   * push_plan_to_dispatch, after the plan lines are inserted (plans from write_refill_plan and
--     the cron 13 draft), for every Add New lane of the machine and date.
-- vox_at_venue lines are skipped (venue stock, VOX team).
-- Rollback: supabase/rollbacks/prd141_01_rollback.sql.

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
REVOKE EXECUTE ON FUNCTION public.ensure_swap_remove_leg(uuid, text, uuid, date) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.ensure_swap_remove_leg(uuid, text, uuid, date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.ensure_swap_remove_legs_for_machine(p_dispatch_date date, p_machine_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_out jsonb := '[]'::jsonb;
  v_res jsonb;
  r record;
BEGIN
  FOR r IN
    SELECT DISTINCT ON (sc.shelf_code) sc.shelf_code, rd.pod_product_id
      FROM public.refill_dispatching rd
      JOIN public.shelf_configurations sc ON sc.shelf_id = rd.shelf_id
     WHERE rd.machine_id = p_machine_id AND rd.dispatch_date = p_dispatch_date
       AND rd.action = 'Add New' AND rd.pod_product_id IS NOT NULL
       AND COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false) AND NOT COALESCE(rd.skipped, false)
       AND rd.source_origin IS DISTINCT FROM 'vox_at_venue'::public.source_origin_enum
     ORDER BY sc.shelf_code, rd.created_at
  LOOP
    v_res := public.ensure_swap_remove_leg(p_machine_id, r.shelf_code, r.pod_product_id, p_dispatch_date);
    IF v_res->>'status' = 'created' OR v_res->>'status' = 'unresolved_product' THEN
      v_out := v_out || v_res;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('status', 'ok', 'lanes', v_out);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.ensure_swap_remove_legs_for_machine(date, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.ensure_swap_remove_legs_for_machine(date, uuid) TO authenticated, service_role;

DO $patch$
DECLARE
  v_def text; n int;
  d_old text := '  v_transfer_id       uuid;' || chr(10) || 'BEGIN';
  d_new text := '  v_transfer_id       uuid;' || chr(10) || '  v_swap_remove       jsonb;' || chr(10) || 'BEGIN';
  h_old text := '    v_after := jsonb_build_object(' || chr(10) || '      ''dispatch_id'', v_new_id, ''machine_id'', p_machine_id, ''shelf_id'', v_shelf_id,';
  h_new text := '    -- PRD-141 item 1: an Add New on a lane holding a different pod writes its Remove leg.' || chr(10)
             || '    IF p_action = ''Add New'' THEN' || chr(10)
             || '      v_swap_remove := public.ensure_swap_remove_leg(p_machine_id, p_shelf_code, v_pod_product_id, p_dispatch_date);' || chr(10)
             || '    END IF;' || chr(10) || chr(10) || h_old;
  r_old text := '      ''rpc_version'',''v4_prd130_f1'');' || chr(10) || '  END IF;';
  r_new text := '      ''rpc_version'',''v4_prd130_f1'', ''swap_remove'', v_swap_remove);' || chr(10) || '  END IF;';
  p_old text := '  BEGIN' || chr(10) || '    v_fefo_bind := public.bind_dispatch_fefo(';
  p_new text := '  -- PRD-141 item 1: Add New lanes on an occupied shelf get their Remove leg.' || chr(10)
             || '  DECLARE v_swap jsonb;' || chr(10)
             || '  BEGIN' || chr(10)
             || '    v_swap := public.ensure_swap_remove_legs_for_machine(p_plan_date, v_machine_id);' || chr(10)
             || '  EXCEPTION WHEN OTHERS THEN' || chr(10)
             || '    INSERT INTO public.monitoring_alerts (source, severity, payload)' || chr(10)
             || '    VALUES (''push_swap_remove_failure'', ''warning'', jsonb_build_object(' || chr(10)
             || '      ''title'', format(''Auto Remove legs for swaps failed on push: %s @ %s'', p_machine_name, p_plan_date),' || chr(10)
             || '      ''plan_date'', p_plan_date, ''machine_name'', p_machine_name, ''error'', SQLERRM, ''detected_at'', now()));' || chr(10)
             || '  END;' || chr(10) || p_old;
BEGIN
  v_def := pg_get_functiondef('public.add_dispatch_row(uuid,text,uuid,numeric,text,date,text,uuid,uuid,text,text,text,uuid)'::regprocedure);
  IF (length(v_def) - length(replace(v_def, d_old, ''))) / length(d_old) <> 1 THEN RAISE EXCEPTION 'prd141_01: add_dispatch_row declare anchor'; END IF;
  IF (length(v_def) - length(replace(v_def, h_old, ''))) / length(h_old) <> 1 THEN RAISE EXCEPTION 'prd141_01: add_dispatch_row hook anchor'; END IF;
  IF (length(v_def) - length(replace(v_def, r_old, ''))) / length(r_old) <> 1 THEN RAISE EXCEPTION 'prd141_01: add_dispatch_row return anchor'; END IF;
  EXECUTE replace(replace(replace(v_def, d_old, d_new), h_old, h_new), r_old, r_new);

  v_def := pg_get_functiondef('public.push_plan_to_dispatch(date,text)'::regprocedure);
  IF (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old) <> 1 THEN RAISE EXCEPTION 'prd141_01: push anchor'; END IF;
  EXECUTE replace(v_def, p_old, p_new);
END
$patch$;

REVOKE EXECUTE ON FUNCTION public.add_dispatch_row(uuid, text, uuid, numeric, text, date, text, uuid, uuid, text, text, text, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.add_dispatch_row(uuid, text, uuid, numeric, text, date, text, uuid, uuid, text, text, text, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.push_plan_to_dispatch(date, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.push_plan_to_dispatch(date, text) TO authenticated, service_role;
