-- Rollback for PRD-145 P3-5: restores pack_dispatch_line, receive_dispatch_line, driver_report_dispatch_outcome,
-- amend_dispatch_after_pickup and v_wm_confirmations to their pre-migration text, and puts the swept row back.
-- Lines received at 0 while the migration was live keep pack_outcome='not_filled' and item_added=false.
DO $patch$
DECLARE
  v_def text; n int; i int; pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.pack_dispatch_line(uuid,jsonb,uuid)'::regprocedure);
  pairs := ARRAY[
    ARRAY[$a$             item_added = false,  -- PRD-145 P3-5: a zero-unit pack is never a delivery
             bind_fail_reason = NULL, bind_fail_at = NULL
       WHERE dispatch_id = p_dispatch_id;
      RETURN jsonb_build_object('status', 'not_filled'$a$,
          $a$             bind_fail_reason = NULL, bind_fail_at = NULL
       WHERE dispatch_id = p_dispatch_id;
      RETURN jsonb_build_object('status', 'not_filled'$a$],
    ARRAY[$a$           item_added        = false,  -- PRD-145 P3-5: a zero-unit pack is never a delivery
           bind_fail_reason  = NULL,
           bind_fail_at      = NULL
     WHERE dispatch_id = p_dispatch_id;
    RETURN jsonb_build_object('status', 'not_filled'$a$,
          $a$           bind_fail_reason  = NULL,
           bind_fail_at      = NULL
     WHERE dispatch_id = p_dispatch_id;
    RETURN jsonb_build_object('status', 'not_filled'$a$]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd145_p3_5 rollback: pack_dispatch_line anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.receive_dispatch_line(uuid,numeric,uuid,jsonb,boolean,text)'::regprocedure);
  pairs := ARRAY[
    ARRAY[$a$  IF v_dispatch.item_added = true THEN RAISE EXCEPTION 'Dispatch % already received', p_dispatch_id; END IF;
  -- PRD-145 P3-5: a fill line received at 0 is closed as not_filled with item_added false, and its packed units were
  -- credited back then. A second receive would credit them twice.
  IF v_dispatch.pack_outcome = 'not_filled' AND v_dispatch.filled_quantity = 0 AND COALESCE(v_dispatch.remainder_credited, false) THEN
    RAISE EXCEPTION 'Dispatch % was already closed as not filled (0 delivered)', p_dispatch_id;
  END IF;
$a$,
          $a$  IF v_dispatch.item_added = true THEN RAISE EXCEPTION 'Dispatch % already received', p_dispatch_id; END IF;
$a$],
    ARRAY[$a$     SET filled_quantity = p_filled_quantity, dispatched = true, packed = true, picked_up = true,
         -- PRD-145 P3-5: 0 units on a fill line is not a delivery.
         item_added = NOT (v_is_fill AND p_filled_quantity = 0),
         not_filled_reason = CASE WHEN v_is_fill AND p_filled_quantity = 0 THEN COALESCE(not_filled_reason, 'driver delivered 0') ELSE not_filled_reason END,
$a$,
          $a$     SET filled_quantity = p_filled_quantity, item_added = true, dispatched = true, packed = true, picked_up = true,
$a$],
    ARRAY[$a$             THEN (CASE WHEN p_filled_quantity = 0 THEN 'not_filled' WHEN p_filled_quantity < v_planned THEN 'partial' ELSE 'packed' END)::public.pack_outcome_enum
$a$,
          $a$             THEN (CASE WHEN p_filled_quantity < v_planned THEN 'partial' ELSE 'packed' END)::public.pack_outcome_enum
$a$]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd145_p3_5 rollback: receive_dispatch_line anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.driver_report_dispatch_outcome(uuid,text,integer)'::regprocedure);
  pairs := ARRAY[
    ARRAY[$a$  IF COALESCE(v_rd.picked_up,false) = true
     AND NOT (p_outcome IN ('not_done','no_stock_on_truck') AND v_rd.filled_quantity = 0) THEN  -- PRD-145 P3-5
$a$,
          $a$  IF COALESCE(v_rd.picked_up,false) = true THEN
$a$]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd145_p3_5 rollback: driver_report_dispatch_outcome anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.amend_dispatch_after_pickup(uuid,text,numeric,boolean,text,uuid)'::regprocedure);
  pairs := ARRAY[
    ARRAY[$a$  IF NOT COALESCE(d.picked_up, false) OR d.delivered_at IS NOT NULL
     OR (COALESCE(d.item_added, false) AND NOT (COALESCE(p_void, false) AND d.filled_quantity = 0))  -- PRD-145 P3-5
$a$,
          $a$  IF NOT COALESCE(d.picked_up, false) OR d.delivered_at IS NOT NULL OR COALESCE(d.item_added, false)
$a$],
    ARRAY[$a$    IF d.filled_quantity = 0 THEN
      -- PRD-145 P3-5: nothing was packed on this line, so nothing goes back to the warehouse.
      v_ret := jsonb_build_object('status', 'returned', 'credited', 0, 'note', 'filled_quantity 0, no warehouse credit');
    ELSE
      v_ret := public.return_dispatch_line(p_dispatch_id, format('Voided after pickup: %s', v_reason), auth.uid(), NULL);
    END IF;
$a$,
          $a$    v_ret := public.return_dispatch_line(p_dispatch_id, format('Voided after pickup: %s', v_reason), auth.uid(), NULL);
$a$]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd145_p3_5 rollback: amend_dispatch_after_pickup anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_viewdef('public.v_wm_confirmations'::regclass);
  pairs := ARRAY[
    ARRAY[$a$((rd.action = ANY (ARRAY['Refill'::text, 'Add'::text, 'Add New'::text])) AND (rd.pack_outcome IS DISTINCT FROM 'not_filled'::pack_outcome_enum) AND (COALESCE(rd.returned, false) = true)$a$,
          $a$((rd.action = ANY (ARRAY['Refill'::text, 'Add'::text, 'Add New'::text])) AND (COALESCE(rd.returned, false) = true)$a$]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd145_p3_5 rollback: v_wm_confirmations anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_wm_confirmations AS ' || v_def;
END
$patch$;

DO $unsweep$
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'prd145_p3_5_rollback', true);
  UPDATE public.refill_dispatching
     SET pack_outcome = 'partial', include = true, not_filled_reason = NULL
   WHERE not_filled_reason = 'sweep PRD-145';
END
$unsweep$;
