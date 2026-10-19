-- PRD-144 P1-1: pending / incomplete machines, and CS plans supersede stale pre-picks.
-- 1. get_incomplete_dispatch_machines(p_days): every machine-day before today (Dubai) with include=true
--    lines that are not delivered (delivered_at or item_added), returned, cancelled, skipped or not_filled.
--    Runs as the caller (SECURITY INVOKER), so RLS decides what each role sees.
-- 2. resolve_incomplete_dispatch(machine, date, mode, reason), operator_admin/superadmin only:
--      complete: receive_dispatch_line(filled = packed qty, else planned qty, override) for each open Refill/Add New;
--      cancel:   return_dispatch_line for each open Refill/Add New, receive 0 for each open Remove leg.
--    Reason required. Each line runs in its own block; the result lists every line's outcome.
-- 3. write_refill_plan and pick_machine_manually first unpick (unpick_machine_to_visit) the date's
--    unconfirmed picker pre-picks that have no plan and no dispatch lines. write_refill_plan re-picks
--    a machine it writes lines for when that machine has no live pick on the date.

CREATE OR REPLACE FUNCTION public.get_incomplete_dispatch_machines(p_days integer DEFAULT 14)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH today AS (SELECT (now() AT TIME ZONE 'Asia/Dubai')::date AS d),
  open_lines AS (
    SELECT rd.dispatch_id, rd.machine_id, rd.dispatch_date, rd.action, rd.quantity, rd.filled_quantity,
           rd.packed, rd.picked_up, sc.shelf_code,
           COALESCE(bp.boonz_product_name, pp.pod_product_name) AS product_name
      FROM public.refill_dispatching rd
      CROSS JOIN today
      LEFT JOIN public.shelf_configurations sc ON sc.shelf_id = rd.shelf_id
      LEFT JOIN public.boonz_products bp ON bp.product_id = rd.boonz_product_id
      LEFT JOIN public.pod_products pp ON pp.pod_product_id = rd.pod_product_id
     WHERE rd.include
       AND rd.dispatch_date < today.d
       AND rd.dispatch_date >= today.d - LEAST(GREATEST(COALESCE(p_days, 14), 1), 90)
       AND rd.delivered_at IS NULL AND NOT COALESCE(rd.item_added, false)
       AND NOT COALESCE(rd.returned, false) AND NOT COALESCE(rd.cancelled, false)
       AND NOT COALESCE(rd.skipped, false)
       AND rd.pack_outcome IS DISTINCT FROM 'not_filled'::public.pack_outcome_enum
  )
  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'dispatch_date' DESC, x->>'official_name'), '[]'::jsonb)
    FROM (
      SELECT jsonb_build_object(
               'machine_id', m.machine_id, 'official_name', m.official_name,
               'dispatch_date', ol.dispatch_date, 'open_lines', count(*),
               'lines', jsonb_agg(jsonb_build_object(
                 'dispatch_id', ol.dispatch_id, 'shelf_code', ol.shelf_code, 'product', ol.product_name,
                 'action', ol.action, 'quantity', ol.quantity, 'filled_quantity', ol.filled_quantity,
                 'packed', COALESCE(ol.packed, false), 'picked_up', COALESCE(ol.picked_up, false),
                 'delivered', false, 'returned', false)
                 ORDER BY ol.shelf_code, ol.action)) AS x
        FROM open_lines ol
        JOIN public.machines m ON m.machine_id = ol.machine_id
       GROUP BY m.machine_id, m.official_name, ol.dispatch_date
    ) s;
$function$;
REVOKE EXECUTE ON FUNCTION public.get_incomplete_dispatch_machines(integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_incomplete_dispatch_machines(integer) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.resolve_incomplete_dispatch(p_machine_id uuid, p_dispatch_date date, p_mode text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role    text;
  v_today   date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  v_reason  text := NULLIF(trim(COALESCE(p_reason, '')), '');
  r         record;
  v_res     jsonb;
  v_results jsonb := '[]'::jsonb;
  v_ok      int := 0;
  v_failed  int := 0;
  v_left    int := 0;
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NULL OR v_role IS NULL OR v_role NOT IN ('operator_admin', 'superadmin') THEN
    RAISE EXCEPTION 'resolve_incomplete_dispatch: operator_admin only (role %)', COALESCE(v_role, 'none');
  END IF;
  IF p_mode NOT IN ('complete', 'cancel') THEN
    RAISE EXCEPTION 'resolve_incomplete_dispatch: p_mode must be complete or cancel';
  END IF;
  IF v_reason IS NULL OR length(v_reason) < 5 THEN
    RAISE EXCEPTION 'resolve_incomplete_dispatch: a reason (5+ characters) is required';
  END IF;
  IF p_machine_id IS NULL OR p_dispatch_date IS NULL OR p_dispatch_date >= v_today THEN
    RAISE EXCEPTION 'resolve_incomplete_dispatch: only machine-days before today (Dubai) can be resolved';
  END IF;

  FOR r IN
    SELECT rd.dispatch_id, rd.action, rd.quantity, rd.filled_quantity, rd.packed
      FROM public.refill_dispatching rd
     WHERE rd.machine_id = p_machine_id AND rd.dispatch_date = p_dispatch_date
       AND rd.include
       AND rd.delivered_at IS NULL AND NOT COALESCE(rd.item_added, false)
       AND NOT COALESCE(rd.returned, false) AND NOT COALESCE(rd.cancelled, false)
       AND NOT COALESCE(rd.skipped, false)
       AND rd.pack_outcome IS DISTINCT FROM 'not_filled'::public.pack_outcome_enum
     ORDER BY rd.action, rd.dispatch_id
  LOOP
    BEGIN
      IF r.action IN ('Refill', 'Add New', 'Add') THEN
        IF p_mode = 'complete' THEN
          v_res := public.receive_dispatch_line(r.dispatch_id,
                     COALESCE(CASE WHEN r.packed THEN r.filled_quantity END, r.quantity),
                     auth.uid(), NULL, true, format('PRD-144 complete: %s', v_reason));
        ELSE
          v_res := public.return_dispatch_line(r.dispatch_id, format('PRD-144 cancel: %s', v_reason), auth.uid(), NULL);
        END IF;
      ELSIF r.action = 'Remove' AND p_mode = 'cancel' THEN
        v_res := public.receive_dispatch_line(r.dispatch_id, 0, auth.uid(), NULL, true, format('PRD-144 cancel: %s', v_reason));
      ELSE
        v_left := v_left + 1;
        v_results := v_results || jsonb_build_object('dispatch_id', r.dispatch_id, 'action', r.action, 'status', 'left_open');
        CONTINUE;
      END IF;
      v_ok := v_ok + 1;
      v_results := v_results || jsonb_build_object('dispatch_id', r.dispatch_id, 'action', r.action, 'status', 'ok');
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      v_results := v_results || jsonb_build_object('dispatch_id', r.dispatch_id, 'action', r.action, 'status', 'error', 'error', SQLERRM);
    END;
  END LOOP;

  RETURN jsonb_build_object('status', CASE WHEN v_failed = 0 THEN 'ok' WHEN v_ok > 0 THEN 'partial' ELSE 'error' END,
    'mode', p_mode, 'machine_id', p_machine_id, 'dispatch_date', p_dispatch_date,
    'lines_ok', v_ok, 'lines_failed', v_failed, 'lines_left_open', v_left, 'results', v_results);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.resolve_incomplete_dispatch(uuid, date, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.resolve_incomplete_dispatch(uuid, date, text, text) TO authenticated;

DO $patch$
DECLARE
  v_def text; n int; i int; pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.write_refill_plan(date,jsonb)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  v_map_block    jsonb;' || chr(10) || 'BEGIN',
          '  v_map_block    jsonb;' || chr(10)
          || '  v_pp           record;  -- PRD-144 P1-1' || chr(10)
          || '  v_pre_dropped  int := 0;' || chr(10)
          || '  v_repicked     int := 0;' || chr(10)
          || 'BEGIN'],
    ARRAY['  ) INTO v_machine_names;' || chr(10) || chr(10) || '  DELETE FROM refill_plan_output t',
          '  ) INTO v_machine_names;' || chr(10) || chr(10)
          || '  -- PRD-144 P1-1: the plan CS writes supersedes the picker''s unconfirmed pre-picks for the day.' || chr(10)
          || '  FOR v_pp IN' || chr(10)
          || '    SELECT mtv.machine_id FROM public.machines_to_visit mtv JOIN public.machines m ON m.machine_id = mtv.machine_id' || chr(10)
          || '     WHERE mtv.plan_date = p_plan_date AND mtv.status = ''picked'' AND mtv.confirmed_at IS NULL' || chr(10)
          || '       AND NOT (m.official_name = ANY(v_machine_names))' || chr(10)
          || '       AND NOT EXISTS (SELECT 1 FROM public.refill_plan_output r WHERE r.plan_date = p_plan_date AND r.machine_name = m.official_name)' || chr(10)
          || '       AND NOT EXISTS (SELECT 1 FROM public.refill_dispatching rd WHERE rd.machine_id = mtv.machine_id AND rd.dispatch_date = p_plan_date)' || chr(10)
          || '  LOOP' || chr(10)
          || '    BEGIN' || chr(10)
          || '      PERFORM public.unpick_machine_to_visit(p_plan_date, v_pp.machine_id, ''superseded by the plan CS wrote (PRD-144 P1-1)'');' || chr(10)
          || '      v_pre_dropped := v_pre_dropped + 1;' || chr(10)
          || '    EXCEPTION WHEN OTHERS THEN NULL;  -- e.g. a manager caller: unpick is operator_admin only' || chr(10)
          || '    END;' || chr(10)
          || '  END LOOP;' || chr(10)
          || '  FOR v_pp IN' || chr(10)
          || '    SELECT m.machine_id FROM public.machines m' || chr(10)
          || '     WHERE m.official_name = ANY(v_machine_names)' || chr(10)
          || '       AND NOT EXISTS (SELECT 1 FROM public.machines_to_visit mtv WHERE mtv.machine_id = m.machine_id' || chr(10)
          || '                        AND mtv.plan_date = p_plan_date AND mtv.status IN (''picked'', ''cs_added''))' || chr(10)
          || '  LOOP' || chr(10)
          || '    BEGIN' || chr(10)
          || '      PERFORM public.pick_machine_manually(p_plan_date, v_pp.machine_id, ''plan written by CS (PRD-144 P1-1)'');' || chr(10)
          || '      v_repicked := v_repicked + 1;' || chr(10)
          || '    EXCEPTION WHEN OTHERS THEN NULL;' || chr(10)
          || '    END;' || chr(10)
          || '  END LOOP;' || chr(10) || chr(10)
          || '  DELETE FROM refill_plan_output t'],
    ARRAY['  ) || jsonb_build_object(''stale_pending_preserved'', v_stale_pending);',
          '  ) || jsonb_build_object(''stale_pending_preserved'', v_stale_pending,' || chr(10)
          || '                        ''pre_picks_dropped'', v_pre_dropped, ''machines_repicked'', v_repicked);']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p1_1: write_refill_plan anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.pick_machine_manually(date,uuid,text)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  v_m_building text;' || chr(10) || 'BEGIN',
          '  v_m_building text;' || chr(10) || '  v_pp         record;  -- PRD-144 P1-1' || chr(10) || 'BEGIN'],
    ARRAY['  -- Upsert: if already in this plan',
          '  -- PRD-144 P1-1: a machine CS picks by hand supersedes the picker''s unconfirmed pre-picks for' || chr(10)
          || '  -- the day that have no plan and no dispatch lines yet.' || chr(10)
          || '  FOR v_pp IN' || chr(10)
          || '    SELECT mtv.machine_id FROM public.machines_to_visit mtv JOIN public.machines m ON m.machine_id = mtv.machine_id' || chr(10)
          || '     WHERE mtv.plan_date = p_plan_date AND mtv.status = ''picked'' AND mtv.confirmed_at IS NULL' || chr(10)
          || '       AND mtv.machine_id <> p_machine_id' || chr(10)
          || '       AND NOT EXISTS (SELECT 1 FROM public.refill_plan_output r WHERE r.plan_date = p_plan_date AND r.machine_name = m.official_name)' || chr(10)
          || '       AND NOT EXISTS (SELECT 1 FROM public.refill_dispatching rd WHERE rd.machine_id = mtv.machine_id AND rd.dispatch_date = p_plan_date)' || chr(10)
          || '  LOOP' || chr(10)
          || '    PERFORM public.unpick_machine_to_visit(p_plan_date, v_pp.machine_id, ''superseded by a machine CS picked (PRD-144 P1-1)'');' || chr(10)
          || '  END LOOP;' || chr(10) || chr(10)
          || '  -- Upsert: if already in this plan']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p1_1: pick_machine_manually anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;
REVOKE EXECUTE ON FUNCTION public.write_refill_plan(date, jsonb) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.write_refill_plan(date, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.pick_machine_manually(date, uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.pick_machine_manually(date, uuid, text) TO authenticated, service_role;