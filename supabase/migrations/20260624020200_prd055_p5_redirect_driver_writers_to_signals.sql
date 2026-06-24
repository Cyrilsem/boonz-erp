-- PRD-055 P5: complete the consolidation — redirect the two driver writers' action_tracker
-- inserts to refill_edit_signals (source='action', signal_type='note'), so new driver feedback
-- lands in the single Signals channel instead of the (now CS-only) Issues board. Based on live
-- bodies; ONLY the action_tracker INSERT in each is changed. All other writes (driver_recommendations,
-- driver_feedback, the refill_dispatching outcome UPDATE) + input/role validation + app.via_rpc are
-- byte-preserved. signal_type='note' is inert: engine_swap_pod reads only signal_type='swap_rejected'
-- (md5 90f26896ba7e0a7099fa689e73eaab91 unchanged — engine not touched). Cody: Art 1,4,8,12. Forward-only.

CREATE OR REPLACE FUNCTION public.driver_propose_adjustment(p_machine_id uuid, p_kind text, p_note text, p_boonz_product_id uuid DEFAULT NULL::uuid, p_shelf_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_rec_id uuid;
  v_machine_name text;
  v_boonz_name text;
  v_owns boolean := true;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','driver_propose_adjustment',true);

  IF p_kind NOT IN ('needs_product','overstocked','wrong_product','machine_issue','other') THEN
    RAISE EXCEPTION 'driver_propose_adjustment: invalid kind %', p_kind;
  END IF;
  IF p_note IS NULL OR length(trim(p_note)) < 3 THEN
    RAISE EXCEPTION 'driver_propose_adjustment: note required';
  END IF;

  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'driver_propose_adjustment: role % not permitted', COALESCE(v_role,'none');
    END IF;
    IF v_role = 'field_staff' THEN
      v_owns := EXISTS (SELECT 1 FROM public.trip_events te
                        WHERE te.driver_user_id = v_uid AND te.machine_id = p_machine_id
                          AND te.dispatch_date >= CURRENT_DATE - 1);
      IF NOT v_owns THEN
        RAISE EXCEPTION 'driver_propose_adjustment: machine % is not on your recent route (ownership)', p_machine_id;
      END IF;
    END IF;
  END IF;

  SELECT official_name INTO v_machine_name FROM public.machines WHERE machine_id = p_machine_id;
  IF v_machine_name IS NULL THEN RAISE EXCEPTION 'machine % not found', p_machine_id; END IF;

  INSERT INTO public.driver_recommendations (created_by, machine_id, shelf_id, kind, boonz_product_id, note, status, source)
  VALUES (v_uid, p_machine_id, p_shelf_id, p_kind, p_boonz_product_id, p_note, 'open', 'driver_app')
  RETURNING rec_id INTO v_rec_id;

  IF p_boonz_product_id IS NOT NULL THEN
    SELECT boonz_product_name INTO v_boonz_name FROM public.boonz_products WHERE product_id = p_boonz_product_id;
    INSERT INTO public.driver_feedback (plan_date, machine_id, machine_name, shelf_code, boonz_product_id,
      boonz_product_name, requested_qty, feedback_type, source, note, submitted_by)
    VALUES (CURRENT_DATE + 1, p_machine_id, v_machine_name,
      (SELECT shelf_code FROM public.shelf_configurations WHERE shelf_id = p_shelf_id),
      p_boonz_product_id, COALESCE(v_boonz_name, 'unmapped'),
      1, CASE WHEN p_kind = 'needs_product' THEN 'add_missing' ELSE 'note' END,
      'driver_app', format('[RD-03 %s] %s', p_kind, p_note), v_uid);
  END IF;

  -- PRD-055 P5: was INSERT INTO action_tracker ('driver_feedback', ...). Now lands in the single
  -- Signals channel. signal_type='note' -> inert to engine_swap_pod (reads only swap_rejected).
  INSERT INTO public.refill_edit_signals (plan_date, machine_id, shelf_id, pod_product_id, signal_type, source, note, created_by)
  VALUES (CURRENT_DATE, p_machine_id, p_shelf_id, NULL, 'note', 'action',
          format('[driver_rec %s] %s%s', p_kind, p_note,
                 CASE WHEN v_boonz_name IS NOT NULL THEN ' | product: '||v_boonz_name ELSE '' END),
          v_uid);

  RETURN jsonb_build_object('status','proposed','rec_id',v_rec_id,'machine',v_machine_name,'kind',p_kind,
    'wrote', jsonb_build_object('driver_recommendations', true, 'driver_feedback', (p_boonz_product_id IS NOT NULL), 'refill_edit_signals', true));
END;
$function$;

CREATE OR REPLACE FUNCTION public.driver_report_dispatch_outcome(p_dispatch_id uuid, p_outcome text, p_actual_qty integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_rd record;
  v_machine_name text;
  v_is_field boolean := false;
  v_owns boolean := false;
  v_punch boolean := false;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','driver_report_dispatch_outcome',true);

  IF p_outcome NOT IN ('done','partial','not_done','machine_offline','no_stock_on_truck') THEN
    RAISE EXCEPTION 'driver_report_dispatch_outcome: invalid outcome %', p_outcome;
  END IF;

  SELECT * INTO v_rd FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'dispatch % not found', p_dispatch_id; END IF;

  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    v_is_field := (v_role = 'field_staff');
    IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'driver_report_dispatch_outcome: role % not permitted', COALESCE(v_role,'none');
    END IF;
    IF v_is_field THEN
      v_owns := EXISTS (SELECT 1 FROM public.trip_events te
                        WHERE te.driver_user_id = v_uid
                          AND te.machine_id = v_rd.machine_id
                          AND te.dispatch_date = v_rd.dispatch_date);
      IF NOT v_owns THEN
        RAISE EXCEPTION 'driver_report_dispatch_outcome: dispatch % is not on your route for % (ownership)', p_dispatch_id, v_rd.dispatch_date;
      END IF;
    END IF;
  END IF;

  IF COALESCE(v_rd.picked_up,false) = true THEN
    RAISE EXCEPTION 'dispatch % already picked_up/finalized — cannot record a driver outcome that reverses it', p_dispatch_id;
  END IF;

  IF v_rd.driver_outcome IS NOT DISTINCT FROM p_outcome THEN
    RETURN jsonb_build_object('status','already_recorded','dispatch_id',p_dispatch_id,'outcome',p_outcome);
  END IF;

  UPDATE public.refill_dispatching
     SET driver_outcome = p_outcome,
         driver_outcome_qty = CASE WHEN p_outcome = 'partial' THEN p_actual_qty ELSE NULL END,
         driver_outcome_at = now(),
         driver_outcome_by = v_uid
   WHERE dispatch_id = p_dispatch_id;

  SELECT official_name INTO v_machine_name FROM public.machines WHERE machine_id = v_rd.machine_id;

  -- PRD-055 P5: was INSERT INTO action_tracker ('task', 'Re-dispatch: ...'). Now lands in Signals.
  -- Idempotency guard moved onto refill_edit_signals (origin tag in note). signal_type='note' -> inert.
  IF p_outcome IN ('not_done','no_stock_on_truck')
     AND NOT EXISTS (
       SELECT 1 FROM public.refill_edit_signals
       WHERE source = 'action'
         AND note LIKE '[driver_outcome re-dispatch '||p_dispatch_id::text||']%'
     ) THEN
    INSERT INTO public.refill_edit_signals (plan_date, machine_id, shelf_id, pod_product_id, signal_type, source, note, created_by)
    VALUES (COALESCE(v_rd.dispatch_date, CURRENT_DATE), v_rd.machine_id, v_rd.shelf_id, NULL, 'note', 'action',
            format('[driver_outcome re-dispatch %s] Driver reported %s on dispatch %s (machine %s). Re-dispatch or resolve.',
                   p_dispatch_id, p_outcome, p_dispatch_id, v_machine_name),
            v_uid);
    v_punch := true;
  END IF;

  RETURN jsonb_build_object('status','recorded','dispatch_id',p_dispatch_id,'outcome',p_outcome,
    'machine', v_machine_name, 'punch_item', v_punch);
END;
$function$;
