-- PRD-118 K1 follow-up (2026-09-05, CS report): approve_refill_plan's item-K
-- Gate-2 expiry guard was firing on source_origin='vox_at_venue' lines when
-- the machine's primary warehouse is CENTRAL (live cases: ACTIVATEMCC-1037,
-- MPMCC-1054 on 2026-09-05), forcing operators to hand-type an "EXPIRY
-- OVERRIDE" comment on every venue-supplied line just to get past a guard
-- that shouldn't apply to them at all — confirmed live: both machines'
-- vox_at_venue dispatch rows already carried that exact workaround comment
-- before this fix.
--
-- Venue-supplied (vox_at_venue) and internal_transfer lines have no Boonz
-- batch by design, so their NULL expiry_date is structural, not a
-- data-quality problem the way a NULL on a warehouse-sourced line is. Item
-- C's sibling unbound-fill check just above this one already carries this
-- exact exemption for vox_at_venue; item K's guard never did. Exempts
-- source_origin IN ('vox_at_venue','internal_transfer') from the NULL-expiry
-- branch only, regardless of warehouse. The short-dated branch (a real,
-- non-NULL expiry_date <= plan_date+7) is untouched and still applies to
-- every source_origin — a venue line that happens to resolve to a genuinely
-- short-dated batch still gets caught.
--
-- Verified in a rolled-back transaction against real 2026-09-05 live rows
-- (their EXPIRY OVERRIDE comments stripped first, so the test proves the
-- exemption itself, not the pre-existing workaround) plus two synthetic
-- rows (internal_transfer NULL-expiry, and a warehouse-sourced short-dated
-- regression case): old predicate flagged 3 rows (the real vox_at_venue
-- line, the synthetic internal_transfer line, the synthetic warehouse
-- short-dated line); new predicate flags only 1 (the warehouse short-dated
-- line, correctly still caught).
--
-- Cody: approve, Articles 1 (still the sole approval gate, no new write
-- path), 4 (role/via_rpc/rpc_name unchanged), 5 (status-transition logic
-- untouched), 12 (forward-only CREATE OR REPLACE). Scope is exactly the
-- item-K WHERE clause; item C's unbound check, the 48h floor, and the
-- top-level approval flow are byte-identical to the prior live function.
CREATE OR REPLACE FUNCTION public.approve_refill_plan(p_plan_date date, p_machine_names text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role    text;
  v_rows_approved  int := 0;
  v_dispatch_rows  int := 0;
  v_slot_guard     jsonb := NULL;
  v_unbound_n      int := 0;
  v_unbound_summary text;
  v_shortdated_n    int := 0;
  v_shortdated_summary text;
  v_expired48_n     int := 0;
  v_expired48_summary text;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'approve_refill_plan', true);

  SELECT role INTO v_caller_role
  FROM user_profiles WHERE id = auth.uid();

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
      OR rd3.expiry_date <= (p_plan_date + 7)
    )
    AND COALESCE(rd3.cancelled,false) = false
    AND COALESCE(rd3.skipped,false) = false
    AND COALESCE(rd3.comment,'') NOT ILIKE '%EXPIRY OVERRIDE%';

  IF v_shortdated_n > 0 THEN
    RAISE EXCEPTION 'Gate-2 (item K): % Refill/Add New line(s) resolved to a NULL or short-dated batch (expiry <= plan_date+7d) with no EXPIRY OVERRIDE comment — %', v_shortdated_n, v_shortdated_summary;
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
    'writer',                   'push_plan_to_dispatch'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'status', 'error',
    'error',  SQLERRM,
    'detail', SQLSTATE
  );
END;
$function$;
