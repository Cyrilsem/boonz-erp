-- PRD-144 P0-3: auto-Remove legs for a swap take the on-shelf product and qty from WEIMI.
-- The lane's latest weimi_aisle_snapshots row (A1 zero-padded to A01 both ways) is the only source of
-- what sits on the lane and how many. pod_inventory is used for the expiry/lot of the leg only.
-- WEIMI has no row, or shows 0: no Remove leg, and the swap carries the warning "lane empty per WEIMI".
--   1. weimi_lane_now(machine, shelf): latest snapshot row with its pod_product_id resolved the same
--      way v_live_shelf_stock does (exact, case-insensitive, product_name_conventions, weimi_product_alias).
--   2. ensure_swap_remove_leg (used by add_dispatch_row Add New, push_plan_to_dispatch via
--      ensure_swap_remove_legs_for_machine, and the FE Add Product flow): rewritten on weimi_lane_now.
--   3. engine_swap_pod: final pass sets pod_swaps out pod and qty_out from WEIMI; empty lanes flagged.
--   4. engine_finalize_pod: no REMOVE/M2W line for a flagged swap; the ADD_NEW line carries the warning.
-- write_refill_plan writes no auto-Remove itself (G7 is a validate_refill_plan check); its swaps get
-- their Remove at push through (2).

CREATE OR REPLACE FUNCTION public.weimi_lane_now(p_machine_id uuid, p_shelf_code text)
 RETURNS TABLE(slot_code text, product_name text, pod_product_id uuid, current_stock integer, snapshot_at timestamp with time zone)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH w AS (
    SELECT w.slot_code, w.product_name, w.current_stock, w.snapshot_at
      FROM public.weimi_aisle_snapshots w
     WHERE w.machine_id = p_machine_id
       AND regexp_replace(w.slot_code, '^([A-Za-z]+)0*(\d+)$', '\1\2')
           = regexp_replace(upper(trim(p_shelf_code)), '^([A-Za-z]+)0*(\d+)$', '\1\2')
     ORDER BY w.snapshot_at DESC
     LIMIT 1
  )
  SELECT w.slot_code, w.product_name,
         COALESCE(
           (SELECT pp.pod_product_id FROM public.pod_products pp WHERE pp.pod_product_name = w.product_name LIMIT 1),
           (SELECT pp.pod_product_id FROM public.pod_products pp
             WHERE lower(trim(pp.pod_product_name)) = lower(trim(w.product_name)) LIMIT 1),
           (SELECT pp.pod_product_id FROM public.product_name_conventions pnc
              JOIN public.pod_products pp ON pp.pod_product_name = pnc.official_name
             WHERE pnc.original_name = w.product_name LIMIT 1),
           (SELECT a.pod_product_id FROM public.weimi_product_alias a
             WHERE a.weimi_name = w.product_name
             ORDER BY (EXISTS (SELECT 1 FROM public.product_mapping pm
                                WHERE pm.pod_product_id = a.pod_product_id AND pm.status = 'Active')) DESC
             LIMIT 1)),
         GREATEST(COALESCE(w.current_stock, 0), 0)::int,
         w.snapshot_at
    FROM w;
$function$;
REVOKE EXECUTE ON FUNCTION public.weimi_lane_now(uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.weimi_lane_now(uuid, text) TO authenticated, service_role;

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
  v_w          record;
  v_old_pod    uuid;
  v_onshelf    int;
  v_removed    numeric;
  v_planned_old numeric;
  v_need       int;
  v_res        jsonb;
  v_pod_name   text;
  v_new_name   text;
  v_legs       jsonb := '[]'::jsonb;
  v_err        text;
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

  -- PRD-144 P0-3: WEIMI is the only source of what is on the lane and how many.
  SELECT * INTO v_w FROM public.weimi_lane_now(p_machine_id, v_code);
  IF NOT FOUND OR COALESCE(v_w.current_stock, 0) <= 0 THEN
    RETURN jsonb_build_object('status', 'lane_empty', 'warning', 'lane empty per WEIMI', 'shelf_code', v_code,
      'weimi_product', v_w.product_name, 'weimi_snapshot_at', v_w.snapshot_at, 'source', 'weimi_aisle_snapshots');
  END IF;
  v_old_pod := v_w.pod_product_id;
  v_onshelf := v_w.current_stock;
  IF v_old_pod IS NULL THEN
    INSERT INTO public.monitoring_alerts (source, severity, payload)
    VALUES ('ensure_swap_remove_leg', 'warning', jsonb_build_object(
      'title', format('Swap on %s: WEIMI shows %s x%s but that name matches no pod product; add the Remove by hand', v_code, v_w.product_name, v_onshelf),
      'machine_id', p_machine_id, 'shelf_code', v_code, 'dispatch_date', p_dispatch_date, 'detected_at', now()));
    RETURN jsonb_build_object('status', 'unresolved_product', 'warning', format('WEIMI product %s not matched to a pod product', v_w.product_name),
      'shelf_code', v_code, 'weimi_product', v_w.product_name, 'on_shelf', v_onshelf);
  END IF;
  IF v_old_pod = p_new_pod_product_id THEN
    RETURN jsonb_build_object('status', 'not_a_swap', 'shelf_code', v_code, 'lane_pod', v_old_pod);
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

  SELECT pod_product_name INTO v_pod_name FROM public.pod_products WHERE pod_product_id = v_old_pod;
  SELECT pod_product_name INTO v_new_name FROM public.pod_products WHERE pod_product_id = p_new_pod_product_id;

  -- One Remove leg for the WEIMI quantity, as a boonz product mapped to the WEIMI pod. A variant with a
  -- live lot on the shelf goes first only so add_dispatch_row can bind its expiry; the next candidates
  -- are the fallbacks when add_dispatch_row refuses one.
  FOR r IN
    SELECT pm.boonz_product_id AS bpid
      FROM public.product_mapping pm
     WHERE pm.pod_product_id = v_old_pod AND pm.status = 'Active'
       AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)
     GROUP BY pm.boonz_product_id
     ORDER BY bool_or(EXISTS (SELECT 1 FROM public.pod_inventory pi
                               WHERE pi.machine_id = p_machine_id AND pi.shelf_id = v_shelf_id
                                 AND pi.status = 'Active' AND COALESCE(pi.current_stock, 0) > 0
                                 AND pi.boonz_product_id = pm.boonz_product_id)) DESC,
              bool_or(pm.machine_id = p_machine_id) DESC NULLS LAST,
              MAX(COALESCE(pm.split_pct, 0)) DESC, pm.boonz_product_id
     LIMIT 3
  LOOP
    BEGIN
      v_res := public.add_dispatch_row(
        p_machine_id, v_code, r.bpid, v_need, 'Remove', p_dispatch_date, 'unknown', NULL, NULL,
        COALESCE(v_role, 'system'),
        format('PRD-144 P0-3: auto Remove of %s x%s on %s per WEIMI, lane swapped to %s', v_pod_name, v_need, v_code, v_new_name), NULL);
    EXCEPTION WHEN OTHERS THEN
      v_res := NULL;
      v_err := SQLERRM;
    END;
    EXIT WHEN v_res IS NOT NULL;
  END LOOP;

  IF v_res IS NULL THEN
    INSERT INTO public.monitoring_alerts (source, severity, payload)
    VALUES ('ensure_swap_remove_leg', 'warning', jsonb_build_object(
      'title', format('Swap on %s: Remove leg for %s x%s (per WEIMI) could not be written (%s); add it by hand', v_code, v_pod_name, v_need, COALESCE(v_err, 'no Active mapping')),
      'machine_id', p_machine_id, 'shelf_code', v_code, 'dispatch_date', p_dispatch_date, 'detected_at', now()));
    v_legs := v_legs || jsonb_build_object('status', 'remove_failed', 'qty', v_need, 'error', COALESCE(v_err, 'no Active mapping for the WEIMI pod'));
  ELSE
    UPDATE public.refill_dispatching
       SET comment = left(COALESCE(NULLIF(comment, '') || ' | ', '') || format('[auto-remove: swap to %s]', v_new_name), 500)
     WHERE dispatch_id = (v_res->>'dispatch_id')::uuid;
    v_legs := v_legs || jsonb_build_object('dispatch_id', v_res->>'dispatch_id', 'boonz_product_id', r.bpid, 'qty', v_need);
  END IF;

  -- PRD-141 item 22: a swap is also a WEIMI relabel to do.
  INSERT INTO public.weimi_relabel_requests (machine_id, shelf_code, from_pod, to_pod, dispatch_date, source, requested_by)
  VALUES (p_machine_id, v_code, v_old_pod, p_new_pod_product_id, p_dispatch_date, 'swap', auth.uid())
  ON CONFLICT (machine_id, shelf_code, to_pod) WHERE done_at IS NULL DO NOTHING;

  RETURN jsonb_build_object('status', 'created', 'shelf_code', v_code, 'lane_pod', v_old_pod,
    'on_shelf', v_onshelf, 'source', 'weimi_aisle_snapshots', 'weimi_snapshot_at', v_w.snapshot_at,
    'remove_legs', v_legs);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.ensure_swap_remove_leg(uuid, text, uuid, date) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.ensure_swap_remove_leg(uuid, text, uuid, date) TO authenticated, service_role;

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
  n := (length(v_def) - length(replace(v_def, a_old, ''))) / length(a_old);
  IF n <> 1 THEN RAISE EXCEPTION 'prd144_p0_3: engine_swap_pod anchor count %', n; END IF;
  EXECUTE replace(v_def, a_old, a_new);

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
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p0_3: engine_finalize_pod anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;
REVOKE EXECUTE ON FUNCTION public.engine_swap_pod(date, integer, numeric, integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.engine_swap_pod(date, integer, numeric, integer) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.engine_finalize_pod(date, uuid[]) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.engine_finalize_pod(date, uuid[]) TO authenticated, service_role;
