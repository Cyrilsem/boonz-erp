-- PRD-121 P0.1b: approve_refill_plan calls validate_refill_plan and RAISES on blocking.
-- THE LOAD-BEARING CHANGE. Every other refill-integrity fix in this program is advisory
-- until this lands -- a gate someone must remember to run manually has already failed
-- (34% of 09-12 dispatch rows needed post-approval intervention; 70 blocking doctrine
-- violations shipped anyway).
--
-- New p_waive jsonb DEFAULT '[]'::jsonb -- array of {gate, reason}, each reason >=10
-- chars, checked in this function body (not left to the table's own CHECK) so a bad
-- p_waive fails with a clear RPC-level message. Blocking violations whose gate code is
-- waived are removed from the residual set; if anything blocking remains, RAISE before
-- any row is touched -- this is strictly ADDITIVE safety, nothing that passed before is
-- newly rejected, and nothing that was rejected before is newly allowed. Warnings never
-- block, matching validate_refill_plan's own severity model.
--
-- Every gate actually waived (i.e. it had >=1 real blocking violation removed by it) gets
-- one row in refill_plan_gate_waivers (Dara-designed ledger, see companion migration).
-- Waiving a gate with zero live violations is a harmless no-op, not an error, and writes
-- no ledger row (nothing was actually waived).
--
-- validate_refill_plan itself is UNCHANGED (per the task's own "VERIFY, DO NOT REBUILD");
-- it reads refill_dispatching, the same table this function's pre-existing Gate-2/K/48h
-- checks already read -- so this gate has the same scope those checks have always had
-- (meaningful once a plan has been pushed at least once; a structural no-op before the
-- first push). Flagged to CS as a known scope boundary, not fixed here.
--
-- Cody: approve. Articles 1 (still the sole operator_status writer, check runs strictly
-- before that UPDATE), 4 (p_waive validated before use), 5 (status transition unchanged),
-- 12 (forward-only CREATE OR REPLACE).
--
-- AC verified: approving the unmodified 2026-09-12 plan (no p_waive) raises; the returned
-- error's violation_detail lists every blocking violation for the scoped machine set
-- (68 of the fleet-wide 70 -- the other 2 belong to machines outside this plan's own
-- pending-row scope, matching validate_refill_plan's own unchanged machine filtering).
--
-- Adding a third parameter to an existing function creates a SECOND overload rather than
-- replacing it (the CLAUDE.md function-naming gotcha, generalized) -- the old 2-arg
-- signature is dropped explicitly first so calling with 2 positional args stays
-- unambiguous.

DROP FUNCTION IF EXISTS public.approve_refill_plan(date, text[]);

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
  v_waive_entry     jsonb;
  v_waived_gates    text[] := ARRAY[]::text[];
  v_residual        jsonb;
  v_residual_n      int := 0;
  v_gate_counts     text;
  v_waivers_applied jsonb := '[]'::jsonb;
  v_waived_count    int;
  v_exc_detail      text;
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

  -- PRD-121 P0.1: validate p_waive shape before it's trusted for anything.
  IF p_waive IS NULL THEN
    p_waive := '[]'::jsonb;
  END IF;
  IF jsonb_typeof(p_waive) <> 'array' THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'p_waive must be a JSON array of {gate, reason}');
  END IF;
  FOR v_waive_entry IN SELECT * FROM jsonb_array_elements(p_waive)
  LOOP
    IF NULLIF(v_waive_entry->>'gate','') IS NULL THEN
      RETURN jsonb_build_object('status', 'error', 'error', 'each p_waive entry needs a non-empty gate code');
    END IF;
    IF length(COALESCE(v_waive_entry->>'reason','')) < 10 THEN
      RETURN jsonb_build_object('status', 'error', 'error',
        format('p_waive entry for gate %s needs a reason of at least 10 characters', v_waive_entry->>'gate'));
    END IF;
    v_waived_gates := array_append(v_waived_gates, v_waive_entry->>'gate');
  END LOOP;

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

  -- PRD-121 P0.1: THE LOAD-BEARING GATE. Merchandising-doctrine violations
  -- (validate_refill_plan, unchanged) must be resolved or explicitly waived with a
  -- reason before any row is approved. Warnings never block.
  v_validation := public.validate_refill_plan(p_plan_date, p_machine_names);

  SELECT jsonb_agg(v) INTO v_residual
  FROM jsonb_array_elements(v_validation->'violations') v
  WHERE (v->>'severity') = 'blocking'
    AND NOT ((v->>'code') = ANY(v_waived_gates));
  v_residual := COALESCE(v_residual, '[]'::jsonb);
  v_residual_n := jsonb_array_length(v_residual);

  IF v_residual_n > 0 THEN
    SELECT string_agg(format('%s: %s', code, cnt), ', ')
      INTO v_gate_counts
    FROM (
      SELECT (v->>'code') AS code, count(*) AS cnt
      FROM jsonb_array_elements(v_residual) v
      GROUP BY 1 ORDER BY 1
    ) x;
    RAISE EXCEPTION 'validate_refill_plan: % blocking violation(s) unresolved (%) — resolve or pass p_waive', v_residual_n, v_gate_counts
      USING DETAIL = v_residual::text;
  END IF;

  -- Record every gate that had at least one real blocking violation actually waived.
  FOR v_waive_entry IN SELECT * FROM jsonb_array_elements(p_waive)
  LOOP
    SELECT count(*) INTO v_waived_count
    FROM jsonb_array_elements(v_validation->'violations') v
    WHERE (v->>'severity') = 'blocking' AND (v->>'code') = (v_waive_entry->>'gate');

    IF v_waived_count > 0 THEN
      INSERT INTO public.refill_plan_gate_waivers (plan_date, machine_names, gate, reason, waived_by)
      VALUES (p_plan_date, p_machine_names, v_waive_entry->>'gate', v_waive_entry->>'reason', v_caller_id);

      v_waivers_applied := v_waivers_applied || jsonb_build_array(jsonb_build_object(
        'gate', v_waive_entry->>'gate', 'reason', v_waive_entry->>'reason', 'violations_waived', v_waived_count
      ));
    END IF;
  END LOOP;

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

  -- PRD-118 item C, Gate-2: refuse to complete the approval while any non-M2M,
  -- non-venue fill row for this date/machine set reached dispatch unbound
  -- (from_wh_inventory_id NULL, quantity>0).
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

  -- PRD-118 item K, Gate-2 (CS doctrine 2026-08-31, non-negotiable): refuse any
  -- Refill/Add New line whose resolved batch expiry is NULL or <= plan_date + 7 days,
  -- unless the row's comment carries an explicit override marker.
  --
  -- PRD-118 item K1 follow-up (2026-09-05, CS): vox_at_venue / internal_transfer
  -- lines carry no Boonz batch by design, so a NULL expiry on them is structural,
  -- not a data-quality problem — exempt those two source_origin values from the
  -- NULL-expiry branch, regardless of the machine's primary warehouse. A
  -- venue-supplied line that DOES resolve to a real short-dated expiry_date still
  -- hits the second branch unchanged; only "NULL means unknown/bad" is exempted.
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

  -- PRD-119 P1 48h dispatch guard (CS doctrine 02 Sep, absolute — NO override marker
  -- honoured here, unlike the K1 check above).
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
    'waivers_applied',          v_waivers_applied,
    'writer',                   'push_plan_to_dispatch'
  );

EXCEPTION WHEN OTHERS THEN
  -- PRD-121 P0.1: the pre-existing catch-all only ever surfaced SQLERRM/SQLSTATE,
  -- which would have silently discarded the RAISE ... USING DETAIL payload above
  -- (the full blocking-violations list) -- pull it back out explicitly so the AC
  -- ("raises and lists 70 violations") is actually met in the returned jsonb, not
  -- just in the exception the function itself immediately swallows. 'detail' keeps
  -- its prior meaning (SQLSTATE) for every existing caller; 'violation_detail' is
  -- new and only ever populated when a RAISE in this function set one.
  GET STACKED DIAGNOSTICS v_exc_detail = PG_EXCEPTION_DETAIL;
  RETURN jsonb_build_object(
    'status', 'error',
    'error',  SQLERRM,
    'detail', SQLSTATE,
    'violation_detail', NULLIF(v_exc_detail, '')
  );
END;
$function$;
