-- PRD-125 D6 -- the waiver table is retired as an active writer.
--
-- approve_refill_plan no longer has any path from p_waive to bypassing a
-- blocking validate_refill_plan violation, and no longer writes
-- refill_plan_gate_waivers. p_waive is still accepted as a parameter
-- (kept, inert, for caller compatibility -- only one other function,
-- commit_refill_plan_atomic, calls this by name, and neither the caller
-- list nor the FE could be fully enumerated in the time available tonight;
-- changing arity risked a silent break there, so the parameter stays and
-- is simply ignored, disclosed here rather than assumed safe to drop).
-- The refill_plan_gate_waivers table itself is untouched (kept for
-- history, per the instruction).
CREATE OR REPLACE FUNCTION public.approve_refill_plan(p_plan_date date, p_machine_names text[], p_waive jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role    text;
  v_caller_id      uuid;
  v_rows_approved  int := 0;
  v_dispatch_rows  int := 0;
  v_slot_guard     jsonb := NULL;
  v_unbound_n      int := 0;
  v_unbound_summary text;
  v_shortdated_n    int := 0;
  v_shortdated_summary text;
  v_expired48_n     int := 0;
  v_expired48_summary text;
  v_validation      jsonb;
  v_gate_counts     text;
  v_exc_detail      text;
  v_mid_pack_n      int := 0;
  v_mid_pack_machines text[];
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'approve_refill_plan', true);

  v_caller_id := auth.uid();
  SELECT role INTO v_caller_role
  FROM user_profiles WHERE id = v_caller_id;

  IF v_caller_role NOT IN ('operator_admin', 'superadmin', 'manager') THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'error', 'Insufficient role — approval requires operator_admin, superadmin, or manager'
    );
  END IF;

  IF p_plan_date IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'p_plan_date is required');
  END IF;
  IF p_machine_names IS NULL OR array_length(p_machine_names, 1) = 0 THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'p_machine_names must be a non-empty array');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM refill_plan_output
    WHERE plan_date = p_plan_date
      AND machine_name = ANY(p_machine_names)
      AND operator_status = 'pending'
  ) THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'error', 'No pending rows found for the specified date and machines'
    );
  END IF;

  SELECT count(DISTINCT m.official_name), array_agg(DISTINCT m.official_name)
    INTO v_mid_pack_n, v_mid_pack_machines
  FROM refill_dispatching rd
  JOIN machines m ON m.machine_id = rd.machine_id
  WHERE rd.dispatch_date = p_plan_date
    AND m.official_name = ANY(p_machine_names)
    AND rd.packed = true
    AND COALESCE(rd.cancelled, false) = false
    AND COALESCE(rd.skipped, false) = false;
  v_mid_pack_machines := COALESCE(v_mid_pack_machines, ARRAY[]::text[]);

  v_validation := public.validate_refill_plan(p_plan_date, p_machine_names);

  IF COALESCE((v_validation->>'blocking')::int, 0) > 0 THEN
    SELECT string_agg(format('%s: %s', code, cnt), ', ')
      INTO v_gate_counts
    FROM (
      SELECT (v->>'code') AS code, count(*) AS cnt
      FROM jsonb_array_elements(v_validation->'violations') v
      WHERE (v->>'severity') = 'blocking'
      GROUP BY 1 ORDER BY 1
    ) x;
    RAISE EXCEPTION 'validate_refill_plan: % blocking violation(s) (%) -- the engine is wrong and must be fixed, this gate is not waivable (PRD-125 D6)',
      (v_validation->>'blocking')::int, v_gate_counts
      USING DETAIL = (v_validation->'violations')::text;
  END IF;

  v_slot_guard := public.assert_weimi_slot_match(p_plan_date, NULL, NULL);
  PERFORM set_config('app.rpc_name', 'approve_refill_plan', true);

  UPDATE refill_plan_output
  SET operator_status = 'approved',
      reviewed_at     = now()
  WHERE plan_date        = p_plan_date
    AND machine_name     = ANY(p_machine_names)
    AND operator_status  = 'pending';

  GET DIAGNOSTICS v_rows_approved = ROW_COUNT;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'approve_refill_plan', true);

  SELECT count(*) INTO v_dispatch_rows
  FROM refill_dispatching rd
  JOIN machines m ON m.machine_id = rd.machine_id
  WHERE rd.dispatch_date = p_plan_date
    AND m.official_name = ANY(p_machine_names)
    AND rd.include = true
    AND COALESCE(rd.cancelled, false) = false
    AND COALESCE(rd.skipped, false) = false;

  SELECT count(*),
         string_agg(format('%s/%s %s x%s (dispatch %s)',
           m2.official_name, COALESCE(sc.shelf_code,'?'), COALESCE(bp.boonz_product_name,'?'),
           rd2.quantity, rd2.dispatch_id), '; ')
    INTO v_unbound_n, v_unbound_summary
  FROM refill_dispatching rd2
  JOIN machines m2 ON m2.machine_id = rd2.machine_id
  LEFT JOIN shelf_configurations sc ON sc.shelf_id = rd2.shelf_id
  LEFT JOIN boonz_products bp ON bp.product_id = rd2.boonz_product_id
  WHERE rd2.dispatch_date = p_plan_date
    AND m2.official_name = ANY(p_machine_names)
    AND rd2.action IN ('Refill','Add New')
    AND rd2.from_wh_inventory_id IS NULL
    AND rd2.quantity > 0
    AND COALESCE(rd2.source_kind,'') <> 'm2m'
    AND COALESCE(rd2.source_origin::text,'') <> 'vox_at_venue'
    AND COALESCE(rd2.cancelled,false) = false
    AND COALESCE(rd2.skipped,false) = false;

  IF v_unbound_n > 0 THEN
    RAISE EXCEPTION 'Gate-2: % fill row(s) reached dispatch unbound (from_wh_inventory_id NULL, qty>0) — %', v_unbound_n, v_unbound_summary;
  END IF;

  SELECT count(*),
         string_agg(format('%s/%s %s exp=%s (dispatch %s)',
           m3.official_name, COALESCE(sc3.shelf_code,'?'), COALESCE(bp3.boonz_product_name,'?'),
           COALESCE(rd3.expiry_date::text,'NULL'), rd3.dispatch_id), '; ')
    INTO v_shortdated_n, v_shortdated_summary
  FROM refill_dispatching rd3
  JOIN machines m3 ON m3.machine_id = rd3.machine_id
  LEFT JOIN shelf_configurations sc3 ON sc3.shelf_id = rd3.shelf_id
  LEFT JOIN boonz_products bp3 ON bp3.product_id = rd3.boonz_product_id
  WHERE rd3.dispatch_date = p_plan_date
    AND m3.official_name = ANY(p_machine_names)
    AND rd3.action IN ('Refill','Add New')
    AND (
      (rd3.expiry_date IS NULL AND COALESCE(rd3.source_origin::text,'') NOT IN ('vox_at_venue','internal_transfer'))
      OR rd3.expiry_date <= (p_plan_date + GREATEST(7, LEAST(
          COALESCE(
            (SELECT MIN(mtv.plan_date) - p_plan_date
               FROM public.machines_to_visit mtv
              WHERE mtv.machine_id = rd3.machine_id
                AND mtv.plan_date > p_plan_date
                AND mtv.plan_date <= p_plan_date + 60
                AND mtv.status IN ('picked','cs_added')) + 3,
            7
          ),
          21
        )))
    )
    AND COALESCE(rd3.cancelled,false) = false
    AND COALESCE(rd3.skipped,false) = false
    AND COALESCE(rd3.comment,'') NOT ILIKE '%EXPIRY OVERRIDE%';

  IF v_shortdated_n > 0 THEN
    RAISE EXCEPTION 'Gate-2 (item K): % Refill/Add New line(s) resolved to a NULL batch, or a batch within the 7-day / next-visit+3d floor (docs/prds PRD-119 D4 correction), with no EXPIRY OVERRIDE comment — %', v_shortdated_n, v_shortdated_summary;
  END IF;

  SELECT count(*),
         string_agg(format('%s/%s %s exp=%s (dispatch %s)',
           m4.official_name, COALESCE(sc4.shelf_code,'?'), COALESCE(bp4.boonz_product_name,'?'),
           COALESCE(rd4.expiry_date::text,'NULL'), rd4.dispatch_id), '; ')
    INTO v_expired48_n, v_expired48_summary
  FROM refill_dispatching rd4
  JOIN machines m4 ON m4.machine_id = rd4.machine_id
  LEFT JOIN shelf_configurations sc4 ON sc4.shelf_id = rd4.shelf_id
  LEFT JOIN boonz_products bp4 ON bp4.product_id = rd4.boonz_product_id
  WHERE rd4.dispatch_date = p_plan_date
    AND m4.official_name = ANY(p_machine_names)
    AND rd4.action IN ('Refill','Add New')
    AND rd4.expiry_date IS NOT NULL
    AND rd4.expiry_date <= (p_plan_date + 2)
    AND COALESCE(rd4.cancelled,false) = false
    AND COALESCE(rd4.skipped,false) = false;

  IF v_expired48_n > 0 THEN
    RAISE EXCEPTION 'Gate-2 (PRD-119 48h floor): % Refill/Add New line(s) resolved to a batch <=48h from expiry — no override possible — %', v_expired48_n, v_expired48_summary;
  END IF;

  RETURN jsonb_build_object(
    'status',                   'ok',
    'plan_date',                p_plan_date,
    'rows_approved',            v_rows_approved,
    'dispatching_rows_present', v_dispatch_rows,
    'dispatching_rows_written', v_dispatch_rows,
    'weimi_slot_guard',         v_slot_guard,
    'machines',                 p_machine_names,
    'validation',               v_validation,
    'waivers_applied',          '[]'::jsonb,
    'mid_pack_warning', CASE WHEN v_mid_pack_n > 0 THEN
      jsonb_build_object('machines_already_packing', v_mid_pack_machines,
        'message', format('%s machine(s) already have packed dispatch rows for %s — this approval may land mid-pack.', v_mid_pack_n, p_plan_date))
      ELSE NULL END,
    'writer',                   'push_plan_to_dispatch'
  );

EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_exc_detail = PG_EXCEPTION_DETAIL;
  RETURN jsonb_build_object(
    'status', 'error',
    'error',  SQLERRM,
    'detail', SQLSTATE,
    'violation_detail', NULLIF(v_exc_detail, '')
  );
END;
$function$;
