-- PRD-110 P4.4 migration C - golden fixture 18: the atomic spot buy.
--
-- LAW 1: create_spot_purchase_v3 shipped BUILT-NOT-FIXTURED at leg 91. This is
-- the proof. It exercises the RPC's REAL write path (p_dry_run=false) against
-- four protected entities and still leaves zero rows behind.
--
-- HOW IT LEAVES NOTHING, AND WHY IT IS NOT A DELETE-BASED RECLAIM.
--   The scenario runs plant + refusals + dry run + the real write inside ONE
--   plpgsql subtransaction and ends it with `RAISE EXCEPTION 'FX18_ROLLBACK'`.
--   Rows vanish; plpgsql VARIABLES survive. Everything the assertions read is
--   captured into s_* variables BEFORE the unwind and written to golden.scratch
--   after it. This is the same mechanism create_spot_purchase_v3 uses for its
--   own p_dry_run path.
--   A delete-based reclaim is not merely inferior here, it is IMPOSSIBLE:
--   warehouse_inventory is referenced by inventory_audit_log, so DELETEing the
--   received batch requires erasing append-only audit rows (Article 7). Rolling
--   back never writes them in the first place.
--   The ONE thing a rollback cannot undo is nextval('po_number_seq') - sequences
--   are non-transactional, so each run burns one po_number. Same accepted class
--   as fixture 60's permanent miner_runs_v3 rows.
--
-- THREE LANDMINES THIS FIXTURE HAD TO DISCOVER (none in the design doc):
--   * uq_blocked_demand_open is keyed (plan_date, machine, shelf, pod, source)
--     among OPEN rows. Its grain is the SHELF, not the product - two open blocks
--     on one machine need two shelves.
--   * refill_dispatching_source_consistency_chk pairs source_kind with its id
--     column: 'wh' REQUIRES source_warehouse_id. 'warehouse' is not a legal
--     source_kind at all.
--   * enforce_canonical_dispatch_write LOGS rather than blocks, so a harness
--     plant without app.via_trigger mints bypass_violation_log rows on every
--     run - residue in a governance table, invisible until someone reads it.
--
-- ⛔ WHY THE CALLER IS A `warehouse` USER AND NOT operator_admin.
--   S-145: add_purchase_order_lines is owner-only, so a warehouse caller can
--   NEVER take the attach path - po_path is deterministically 'minted'. An
--   operator_admin caller would attach to whatever open walk-in PO happens to
--   exist for that supplier TODAY, then stamp received_date on it. On a day
--   when procurement has an open Carrefour PO, this fixture would receive a
--   REAL production purchase order. The role choice is the safety property.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes, enabled, baseline_status)
VALUES (
  18,
  'A spot buy is one transaction: goods bought at the counter land in the REQUESTED warehouse (not CENTRAL), the walk-in driver task that told a driver to go buy them is closed rather than deleted, the waiting dispatch line binds to that exact batch and no other machine''s does, and a part-covered block stays OPEN',
  'PRD-110 P4.4 / WS-I 2026-07-30 01:21: a driver bought 8 Zigi at Carrefour plus 1 from WH, entered Filled=9, and receive_dispatch_line correctly refused because WH was short - so the driver was stranded holding goods the system had no way to accept. The guard stays; this is the happy path it was missing.',
  'P4',
  DATE '2030-07-15',
$fx18body$
DO $fx18$
DECLARE
  -- ---- fixed cast (every id probed live, LAW 13) -------------------------
  c_mach_a   uuid := '9acce2bf-0e65-48f4-bf44-cefa0326f2c5'; -- MPMCC-1058-0000-R0
  c_mach_b   uuid := '981a155e-8bfc-4d6e-b168-0770ef082dc9'; -- AMZ-1046-2406-O1 (control)
  c_shelf_a  uuid := '06c84aca-b417-4131-aa5a-cf0753fa131b';
  -- uq_blocked_demand_open is keyed (plan_date, machine, shelf, pod, source)
  -- among OPEN rows - its grain is the SHELF, not the product. Two open blocks
  -- on one machine therefore need two shelves.
  c_shelf_a2 uuid := '209ce28c-3dba-4158-94ae-ec249580553e';
  c_shelf_b  uuid := '008dee40-ad59-47bc-9c7e-7b2c8aadb535';
  c_pod      uuid := '00512d0e-e356-4f47-b19c-2b9b09d2fc4f';
  c_p1       uuid := '51c132ff-7d8e-463a-9324-03903105da4c'; -- Zigi - Sweet Chilli
  c_p2       uuid := 'c8e1eaa3-70a7-4b49-86b3-9330ad3b498c'; -- Zigi - Sea Salted
  c_pblk     uuid := '5c821266-fe04-46c1-95c2-145e014795c2'; -- Sun Blast (never_order_flavor)
  c_sup      uuid := 'a44b3e6c-0b6f-45b9-a5fa-9c911b8ac322'; -- Carrefour, Active walk_in
  c_sup_inac uuid := '3cec0b3a-be06-4104-a88b-6a69e8f247d7'; -- Union Coop DUP, Inactive
  c_sup_del  uuid := 'd22c79f1-3557-464c-a92a-b6edc826d640'; -- Amazon Online, supplier_delivered
  c_mcc      uuid := '4fcfb52c-271f-4aa7-a373-3495e3271cd3';
  c_central  uuid := '4bebef68-9e36-4a5c-9c2c-142f8dbdae85';
  c_u_wh     uuid := '7f4ecaa4-1efe-4a32-b233-35f5516f6131'; -- warehouse
  c_u_field  uuid := 'bddaec3c-fe18-40db-93e4-8ca543819519'; -- field_staff
  c_date     date := DATE '2030-07-15';
  c_exp1     date := CURRENT_DATE + 90;
  c_exp2     date := CURRENT_DATE + 60;

  v_b1 uuid; v_b2 uuid; v_d_a uuid; v_d_b uuid;
  v_live_open uuid[];
  v_res jsonb := '{}'::jsonb; v_dry jsonb := '{}'::jsonb;
  v_po_id text;
  v_n_po int; v_n_wh int; v_n_bd int; v_n_pe int; v_n_ie int;
  v_ie_before int;
  v_lines jsonb;
  -- everything the assertions read is captured into these BEFORE the rollback.
  -- plpgsql variables survive a subtransaction rollback; rows do not. That is
  -- the whole mechanism.
  s_dry jsonb; s_po jsonb; s_wh jsonb; s_bind jsonb; s_blocked jsonb;
  s_task jsonb; s_events jsonb; s_refusals jsonb; s_gucs jsonb; s_dials jsonb;
  v_r1 text:='NOT REFUSED'; v_r2 text:='NOT REFUSED'; v_r3 text:='NOT REFUSED';
  v_r4 text:='NOT REFUSED'; v_r5 text:='NOT REFUSED'; v_r6 text:='NOT REFUSED';
  v_r7 text:='NOT REFUSED'; v_r8 text:='NOT REFUSED'; v_r9 text:='NOT REFUSED';
  v_r10 text:='NOT REFUSED'; v_r11 text:='NOT REFUSED'; v_r12 text:='NOT REFUSED';
BEGIN
  PERFORM set_config('app.rpc_name', 'golden.fixture_18', true);
  DELETE FROM golden.scratch WHERE fixture_id = 18;

  -- =======================================================================
  -- ONE SUBTRANSACTION. Everything below is rolled back by the RAISE at the
  -- end; only the s_* variables survive. This fixture therefore leaves ZERO
  -- rows in FOUR protected tables (purchase_orders, warehouse_inventory,
  -- refill_dispatching, blocked_demand) without ever DELETEing from any of
  -- them - which matters, because warehouse_inventory is referenced by the
  -- append-only inventory_audit_log and a delete-based reclaim would have to
  -- erase audit rows to succeed (Article 7). Rolling back never writes them.
  -- ⚠️ The ONE thing a rollback cannot undo is nextval('po_number_seq'):
  --    sequences are non-transactional, so each run burns one po_number.
  --    That is the same accepted class as fixture 60's permanent log rows.
  -- =======================================================================
  BEGIN
    ------------------------------------------------------------- 1. plant --
    -- via_trigger: enforce_canonical_dispatch_write LOGS rather than blocks,
    -- so a harness plant without this mints bypass_violation_log rows.
    PERFORM set_config('app.via_trigger', 'true', true);

    INSERT INTO public.blocked_demand
      (plan_date, machine_id, shelf_id, pod_product_id, boonz_product_id,
       qty_blocked, reason, source, detected_by, reasoning)
    VALUES (c_date, c_mach_a, c_shelf_a, c_pod, c_p1, 8, 'blocked_no_wh',
            'engine_add', 'golden.fixture_18',
            jsonb_build_object('fx','FX18','role','fully_covered'))
    RETURNING blocked_demand_id INTO v_b1;

    INSERT INTO public.blocked_demand
      (plan_date, machine_id, shelf_id, pod_product_id, boonz_product_id,
       qty_blocked, reason, source, detected_by, reasoning)
    VALUES (c_date, c_mach_a, c_shelf_a2, c_pod, c_p2, 10, 'blocked_no_wh',
            'engine_add', 'golden.fixture_18',
            jsonb_build_object('fx','FX18','role','partially_covered'))
    RETURNING blocked_demand_id INTO v_b2;

    -- every OTHER open row in the table. The live-safety invariant proves the
    -- RPC closed none of them - the assertion that keeps this fixture safe as
    -- production data drifts underneath it.
    SELECT COALESCE(array_agg(blocked_demand_id), '{}') INTO v_live_open
      FROM public.blocked_demand
     WHERE resolved_at IS NULL AND blocked_demand_id NOT IN (v_b1, v_b2);

    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date,
       action, quantity, from_warehouse_id, comment, source_kind, source_warehouse_id)
    VALUES (c_mach_a, c_shelf_a, c_pod, c_p1, c_date, 'Refill', 8, c_mcc,
            'FX18 target line', 'wh', c_mcc)
    RETURNING dispatch_id INTO v_d_a;

    -- S-143: the control. Identically blocked, DIFFERENT machine. Someone who
    -- "simplifies" the bind to bind_dispatch_fefo(NULL) sweeps the fleet and
    -- binds this row; the assertion turns red the moment they do.
    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date,
       action, quantity, from_warehouse_id, comment, source_kind, source_warehouse_id)
    VALUES (c_mach_b, c_shelf_b, c_pod, c_p1, c_date, 'Refill', 8, c_mcc,
            'FX18 CONTROL line - must stay unbound', 'wh', c_mcc)
    RETURNING dispatch_id INTO v_d_b;

    PERFORM set_config('app.via_trigger', '', true);

    v_lines := jsonb_build_array(
      jsonb_build_object('boonz_product_id', c_p1, 'qty', 8,
        'price_per_unit_aed', 3.5, 'expiry_date', c_exp1, 'wh_location', 'FX18'),
      jsonb_build_object('boonz_product_id', c_p2, 'qty', 4,
        'price_per_unit_aed', 2.5, 'expiry_date', c_exp2, 'wh_location', 'FX18'));

    ---------------------------------------------------------- 2. refusals --
    -- Every probe runs p_dry_run=>true. If a guard has been removed the call
    -- RETURNS instead of raising, the probe records 'NOT REFUSED', and nothing
    -- was committed to find that out.
    PERFORM set_config('request.jwt.claims',
      format('{"sub":"%s","role":"authenticated"}', c_u_field), true);
    BEGIN
      PERFORM public.create_spot_purchase_v3(c_mach_a, c_mcc, c_sup, v_lines,
        c_date, NULL, NULL, 'FX18', true);
    EXCEPTION WHEN OTHERS THEN v_r1 := SQLERRM; END;

    PERFORM set_config('request.jwt.claims',
      format('{"sub":"%s","role":"authenticated"}', c_u_wh), true);

    BEGIN
      PERFORM public.create_spot_purchase_v3(c_mach_a, c_mcc, c_sup,
        jsonb_build_array(jsonb_build_object('boonz_product_id', c_p1,
          'qty', 2, 'price_per_unit_aed', 3.5)),
        c_date, NULL, NULL, 'FX18', true);
    EXCEPTION WHEN OTHERS THEN v_r2 := SQLERRM; END;

    BEGIN
      PERFORM public.create_spot_purchase_v3(c_mach_a, c_mcc, c_sup,
        jsonb_build_array(jsonb_build_object('boonz_product_id', c_p1,
          'qty', 2, 'price_per_unit_aed', 3.5, 'expiry_date', CURRENT_DATE - 1)),
        c_date, NULL, NULL, 'FX18', true);
    EXCEPTION WHEN OTHERS THEN v_r3 := SQLERRM; END;

    BEGIN
      PERFORM public.create_spot_purchase_v3(c_mach_a, c_mcc, c_sup,
        jsonb_build_array(jsonb_build_object('boonz_product_id', c_p1,
          'qty', 0, 'price_per_unit_aed', 3.5, 'expiry_date', c_exp1)),
        c_date, NULL, NULL, 'FX18', true);
    EXCEPTION WHEN OTHERS THEN v_r4 := SQLERRM; END;

    BEGIN
      PERFORM public.create_spot_purchase_v3(c_mach_a, c_mcc, c_sup_inac,
        v_lines, c_date, NULL, NULL, 'FX18', true);
    EXCEPTION WHEN OTHERS THEN v_r5 := SQLERRM; END;

    BEGIN
      PERFORM public.create_spot_purchase_v3(c_mach_a, c_mcc, c_sup_del,
        v_lines, c_date, NULL, NULL, 'FX18', true);
    EXCEPTION WHEN OTHERS THEN v_r6 := SQLERRM; END;

    BEGIN
      PERFORM public.create_spot_purchase_v3(c_mach_a, c_mcc, c_sup,
        jsonb_build_array(jsonb_build_object('boonz_product_id', c_pblk,
          'qty', 2, 'price_per_unit_aed', 3.5, 'expiry_date', c_exp1)),
        c_date, NULL, NULL, 'FX18', true);
    EXCEPTION WHEN OTHERS THEN v_r7 := SQLERRM; END;

    BEGIN
      PERFORM public.create_spot_purchase_v3(c_mach_a,
        '00000000-0000-0000-0000-0000000000ff'::uuid, c_sup, v_lines,
        c_date, NULL, NULL, 'FX18', true);
    EXCEPTION WHEN OTHERS THEN v_r8 := SQLERRM; END;

    BEGIN
      PERFORM public.create_spot_purchase_v3(c_mach_a, NULL, c_sup, v_lines,
        c_date, NULL, NULL, 'FX18', true);
    EXCEPTION WHEN OTHERS THEN v_r9 := SQLERRM; END;

    BEGIN
      PERFORM public.create_spot_purchase_v3(c_mach_a, c_mcc, c_sup,
        jsonb_build_array(jsonb_build_object('boonz_product_id',
          '00000000-0000-0000-0000-0000000000fe'::uuid, 'qty', 2,
          'price_per_unit_aed', 3.5, 'expiry_date', c_exp1)),
        c_date, NULL, NULL, 'FX18', true);
    EXCEPTION WHEN OTHERS THEN v_r10 := SQLERRM; END;

    BEGIN
      PERFORM public.create_spot_purchase_v3(c_mach_a, c_mcc, c_sup,
        '[]'::jsonb, c_date, NULL, NULL, 'FX18', true);
    EXCEPTION WHEN OTHERS THEN v_r11 := SQLERRM; END;

    BEGIN
      PERFORM public.create_spot_purchase_v3(
        '00000000-0000-0000-0000-0000000000fd'::uuid, c_mcc, c_sup, v_lines,
        c_date, NULL, NULL, 'FX18', true);
    EXCEPTION WHEN OTHERS THEN v_r12 := SQLERRM; END;

    v_r1 := left(v_r1, 400); v_r2 := left(v_r2, 400); v_r3 := left(v_r3, 400);
    v_r4 := left(v_r4, 400); v_r5 := left(v_r5, 400); v_r6 := left(v_r6, 400);
    v_r7 := left(v_r7, 400); v_r8 := left(v_r8, 400); v_r9 := left(v_r9, 400);
    v_r10 := left(v_r10, 400); v_r11 := left(v_r11, 400); v_r12 := left(v_r12, 400);

    s_refusals := jsonb_build_object(
      'field_staff', v_r1, 'null_expiry', v_r2, 'past_expiry', v_r3,
      'qty_zero', v_r4, 'sup_inactive', v_r5, 'sup_not_walkin', v_r6,
      'blocked_product', v_r7, 'wh_unknown', v_r8, 'wh_null', v_r9,
      'prod_unknown', v_r10, 'no_lines', v_r11, 'machine_unknown', v_r12);

    --------------------------------------------------- 3. dry-run residue --
    SELECT count(*) INTO v_n_po FROM public.purchase_orders;
    SELECT count(*) INTO v_n_wh FROM public.warehouse_inventory;
    SELECT count(*) INTO v_n_bd FROM public.blocked_demand WHERE resolved_at IS NOT NULL;
    SELECT count(*) INTO v_n_pe FROM public.procurement_events;
    SELECT count(*) INTO v_n_ie FROM public.inventory_events;

    v_dry := public.create_spot_purchase_v3(c_mach_a, c_mcc, c_sup, v_lines,
               c_date, 'fx18/receipt.jpg', NULL, 'FX18 dry', true);

    SELECT jsonb_build_object(
      'po', (SELECT count(*) FROM public.purchase_orders)     - v_n_po,
      'wh', (SELECT count(*) FROM public.warehouse_inventory) - v_n_wh,
      'bd', (SELECT count(*) FROM public.blocked_demand WHERE resolved_at IS NOT NULL) - v_n_bd,
      'pe', (SELECT count(*) FROM public.procurement_events)  - v_n_pe,
      'ie', (SELECT count(*) FROM public.inventory_events)    - v_n_ie,
      'ok', v_dry->>'ok', 'committed', v_dry->>'committed',
      'deferred_flag', v_dry->>'deferred_constraints_unchecked',
      'bound_a', (SELECT from_wh_inventory_id IS NOT NULL
                    FROM public.refill_dispatching WHERE dispatch_id = v_d_a))
    INTO s_dry;

    ------------------------------------------------ 4. the real write path --
    SELECT count(*) INTO v_ie_before FROM public.inventory_events;

    v_res := public.create_spot_purchase_v3(c_mach_a, c_mcc, c_sup, v_lines,
               c_date, 'fx18/receipt.jpg', NULL, 'FX18 live', false);
    v_po_id := v_res->>'po_id';

    ------------------------------------------------------------ 5. capture --
    SELECT jsonb_agg(jsonb_build_object(
             'received_date_set', received_date IS NOT NULL,
             'received_date_today', received_date = CURRENT_DATE,
             'received_qty', received_qty, 'ordered_qty', ordered_qty,
             'outcome', purchase_outcome, 'price', price_per_unit_aed,
             'total', total_price_aed, 'total_is_qty_x_price',
             total_price_aed = received_qty * price_per_unit_aed,
             'expiry', expiry_date, 'po_number_set', po_number IS NOT NULL)
             ORDER BY boonz_product_id::text)
      INTO s_po FROM public.purchase_orders WHERE po_id = v_po_id;

    SELECT jsonb_agg(jsonb_build_object(
             'is_mcc', warehouse_id = c_mcc, 'is_central', warehouse_id = c_central,
             'status', status, 'stock', warehouse_stock, 'exp', expiration_date,
             'batch_has_spot', batch_id LIKE '%-SPOT-B%',
             'quarantined', COALESCE(quarantined, false),
             'snapshot_today', snapshot_date = CURRENT_DATE)
             ORDER BY boonz_product_id::text)
      INTO s_wh FROM public.warehouse_inventory WHERE wh_location = 'FX18';

    SELECT jsonb_build_object(
      'a_bound', (SELECT from_wh_inventory_id IS NOT NULL
                    FROM public.refill_dispatching WHERE dispatch_id = v_d_a),
      'a_from_wh_is_mcc', (SELECT from_warehouse_id = c_mcc
                    FROM public.refill_dispatching WHERE dispatch_id = v_d_a),
      'a_batch_is_ours', (SELECT wi.wh_location = 'FX18'
                    FROM public.refill_dispatching rd
                    JOIN public.warehouse_inventory wi
                      ON wi.wh_inventory_id = rd.from_wh_inventory_id
                   WHERE rd.dispatch_id = v_d_a),
      'b_bound', (SELECT from_wh_inventory_id IS NOT NULL
                    FROM public.refill_dispatching WHERE dispatch_id = v_d_b))
      INTO s_bind;

    SELECT jsonb_build_object(
      'b1_resolution', (SELECT resolution FROM public.blocked_demand WHERE blocked_demand_id = v_b1),
      'b1_resolved_at_set', (SELECT resolved_at IS NOT NULL FROM public.blocked_demand WHERE blocked_demand_id = v_b1),
      'b1_resolved_by_is_caller', (SELECT resolved_by = c_u_wh FROM public.blocked_demand WHERE blocked_demand_id = v_b1),
      'b2_still_open', (SELECT resolved_at IS NULL AND resolution IS NULL FROM public.blocked_demand WHERE blocked_demand_id = v_b2),
      'b2_note', (SELECT resolution_note FROM public.blocked_demand WHERE blocked_demand_id = v_b2),
      'live_rows_closed', (SELECT count(*) FROM public.blocked_demand
                            WHERE blocked_demand_id = ANY(v_live_open) AND resolved_at IS NOT NULL))
      INTO s_blocked;

    SELECT jsonb_build_object('n', count(*), 'status', min(status),
             'outcome', min(outcome),
             'collected_set', bool_and(collected_at IS NOT NULL),
             'comment_has_auto', bool_and(outcome_comment LIKE '%auto-closed by create_spot_purchase_v3%'))
      INTO s_task FROM public.driver_tasks WHERE po_id = v_po_id;

    SELECT jsonb_build_object(
      'types', (SELECT string_agg(DISTINCT event_type, ',' ORDER BY event_type)
                  FROM public.procurement_events WHERE po_id = v_po_id),
      'ie_delta', (SELECT count(*) FROM public.inventory_events) - v_ie_before)
      INTO s_events;

    PERFORM set_config('request.jwt.claims', '', true);

    SELECT jsonb_build_object(
      'via_rpc',  COALESCE(current_setting('app.via_rpc', true), '<unset>'),
      'rpc_name', COALESCE(current_setting('app.rpc_name', true), '<unset>'),
      'prov',     COALESCE(current_setting('app.provenance_reason', true), '<unset>'))
      INTO s_gucs;

    SELECT jsonb_build_object('cap', spot_buy_price_cap_aed,
             'enf', spot_buy_cap_enforcement)
      INTO s_dials FROM public.refill_policy_params ORDER BY id LIMIT 1;

    ------------------------------------------------------------ 6. unwind --
    RAISE EXCEPTION 'FX18_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'FX18_ROLLBACK' THEN RAISE; END IF;
  END;

  PERFORM set_config('app.via_trigger', '', true);
  PERFORM set_config('request.jwt.claims', '', true);

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES
    (18, 'result',   v_res),
    (18, 'dry',      s_dry),
    (18, 'po',       s_po),
    (18, 'wh',       s_wh),
    (18, 'bind',     s_bind),
    (18, 'blocked',  s_blocked),
    (18, 'task',     s_task),
    (18, 'events',   s_events),
    (18, 'refusals', s_refusals),
    (18, 'gucs',     s_gucs),
    (18, 'dials',    s_dials),
    (18, 'residue',  jsonb_build_object(
       'po', (SELECT count(*) FROM public.purchase_orders WHERE po_id = v_res->>'po_id'),
       'wh', (SELECT count(*) FROM public.warehouse_inventory WHERE wh_location = 'FX18'),
       'rd', (SELECT count(*) FROM public.refill_dispatching
               WHERE dispatch_date = c_date AND comment LIKE 'FX18%'),
       'bd', (SELECT count(*) FROM public.blocked_demand WHERE reasoning->>'fx' = 'FX18'),
       'dt', (SELECT count(*) FROM public.driver_tasks WHERE po_id = v_res->>'po_id'),
       'pe', (SELECT count(*) FROM public.procurement_events WHERE po_id = v_res->>'po_id')));
END
$fx18$;
$fx18body$,
  'Leaves ZERO rows in purchase_orders, warehouse_inventory, refill_dispatching and blocked_demand: the whole scenario is one subtransaction that rolls itself back, and the assertions read golden.scratch written from variables afterwards. Burns one po_number per run (sequences are non-transactional). Caller is a warehouse user on purpose - see the header note on why operator_admin would be unsafe. ~1-2 s.',
  true,
  'passing'
)
ON CONFLICT (fixture_id) DO UPDATE SET
  name            = EXCLUDED.name,
  source_incident = EXCLUDED.source_incident,
  phase_required  = EXCLUDED.phase_required,
  plan_date       = EXCLUDED.plan_date,
  scenario_sql    = EXCLUDED.scenario_sql,
  notes           = EXCLUDED.notes,
  enabled         = EXCLUDED.enabled,
  baseline_status = EXCLUDED.baseline_status;

DELETE FROM golden.assertions WHERE fixture_id = 18;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
SELECT 18, t.seq, t.descr, t.sql, t.op, t.expect, true, 'P4'
FROM (VALUES

-- A. the object exists in the shape Cody approved -------------------------
(1,'exactly ONE overload of create_spot_purchase_v3 - a second would be a silent fork of the spot-buy path',
 $q$SELECT count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='create_spot_purchase_v3'$q$,'eq','1'),
(2,'⛔ the WHOLE proacl string (S-140). anon must not hold EXECUTE, and the three legitimate grants must all survive - a revoke that quietly took service_role would break the nightly runner with no error anywhere',
 $q$SELECT proacl::text FROM pg_proc WHERE oid='public.create_spot_purchase_v3(uuid,uuid,uuid,jsonb,date,text,text,text,boolean)'::regprocedure$q$,'eq',
 '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
(3,'SECURITY DEFINER with search_path pinned (Article 4)',
 $q$SELECT (prosecdef::text || '|' || COALESCE(array_to_string(proconfig,','),'<none>')) FROM pg_proc WHERE oid='public.create_spot_purchase_v3(uuid,uuid,uuid,jsonb,date,text,text,text,boolean)'::regprocedure$q$,'eq',
 'true|search_path=public, pg_temp'),
(4,'the pre-auth cap dial exists and still defaults to 15 AED (D-D)',
 $q$SELECT column_default FROM information_schema.columns WHERE table_name='refill_policy_params' AND column_name='spot_buy_price_cap_aed'$q$,'contains','15'),
(5,'⛔ the cap ENFORCEMENT dial is still ''warn''. The flip to ''block'' is the parked DECISIONS-READY item; the day CS flips it this goes RED, which is the assertion working. Re-baseline expect AND description together (S-103).',
 $q$SELECT spot_buy_cap_enforcement FROM public.refill_policy_params ORDER BY id LIMIT 1$q$,'eq','warn'),
(6,'the enforcement dial is CHECK-constrained to the three legal modes - a typo like ''blocked'' must not silently disable the cap',
 $q$SELECT count(*)::text FROM pg_constraint WHERE conrelid='public.refill_policy_params'::regclass AND pg_get_constraintdef(oid) LIKE '%spot_buy_cap_enforcement%' AND pg_get_constraintdef(oid) LIKE '%block%' AND pg_get_constraintdef(oid) LIKE '%warn%' AND pg_get_constraintdef(oid) LIKE '%off%'$q$,'eq','1'),
(7,'⛔ blocked_demand_resolution_pair still exists: resolved_at and resolution move together or not at all. Without it a row could carry a resolution while still counting as open.',
 $q$SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname='blocked_demand_resolution_pair'$q$,'contains','resolved_at IS NULL) AND (resolution IS NULL)'),
(8,'''spot_buy'' is a legal blocked_demand resolution - the value this RPC writes',
 $q$SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname='blocked_demand_resolution_check'$q$,'contains','spot_buy'),
(9,'procurement_events admits BOTH spot event types (S-148: the CHECK was a closed list of 11 and refused them until the additive rebuild)',
 $q$SELECT (pg_get_constraintdef(oid) LIKE '%spot_purchase_created%' AND pg_get_constraintdef(oid) LIKE '%spot_purchase_task_autoclosed%')::text FROM pg_constraint WHERE conrelid='public.procurement_events'::regclass AND pg_get_constraintdef(oid) LIKE '%event_type%'$q$,'eq','true'),
(10,'⭐ uq_blocked_demand_open is keyed at SHELF grain, not product grain. This fixture had to discover it; pinning it stops the next author re-learning it the hard way.',
 $q$SELECT indexdef FROM pg_indexes WHERE indexname='uq_blocked_demand_open'$q$,'contains','plan_date, machine_id, shelf_id, pod_product_id, source'),

-- B. the happy path ---------------------------------------------------------
(11,'the run reports ok',
 $q$SELECT (value->>'ok') FROM golden.scratch WHERE fixture_id=18 AND key='result'$q$,'eq','true'),
(12,'⛔ S-145: a warehouse caller MINTS, never attaches. add_purchase_order_lines is owner-only, so the attach path is unreachable for this role - and that is what stops the fixture from ever receiving a real open production PO.',
 $q$SELECT (value->>'po_path') FROM golden.scratch WHERE fixture_id=18 AND key='result'$q$,'eq','minted'),
(13,'a real po_number was allocated from po_number_seq',
 $q$SELECT ((value->>'po_number')::int > 0)::text FROM golden.scratch WHERE fixture_id=18 AND key='result'$q$,'eq','true'),
(14,'both lines were received',
 $q$SELECT (value->>'lines_received') FROM golden.scratch WHERE fixture_id=18 AND key='result'$q$,'eq','2'),
(15,'8 + 4 = 12 units received',
 $q$SELECT (value->>'units_received') FROM golden.scratch WHERE fixture_id=18 AND key='result'$q$,'eq','12'),
(16,'spend is 8x3.5 + 4x2.5 = 38 AED',
 $q$SELECT (value->>'spend_aed') FROM golden.scratch WHERE fixture_id=18 AND key='result'$q$,'eq','38'),
(17,'⛔ THE L1/S-141 ASSERTION. The goods landed in the REQUESTED warehouse (WH_MCC). receive_purchase_order hardcodes wh_central_id(), which is exactly why this RPC has its own receive path.',
 $q$SELECT (value->>'warehouse_id') FROM golden.scratch WHERE fixture_id=18 AND key='result'$q$,'eq','4fcfb52c-271f-4aa7-a373-3495e3271cd3'),
(18,'⛔ ...and it is NOT central. Stated independently so the assertion can actually fail: a regression to the hardcoded path would still satisfy a "warehouse_id is not null" check.',
 $q$SELECT ((value->>'warehouse_id') <> public.wh_central_id()::text)::text FROM golden.scratch WHERE fixture_id=18 AND key='result'$q$,'eq','true'),
(19,'every warehouse_inventory row written sits in MCC',
 $q$SELECT bool_and((e->>'is_mcc')::boolean)::text FROM golden.scratch s, LATERAL jsonb_array_elements(s.value) e WHERE s.fixture_id=18 AND s.key='wh'$q$,'eq','true'),
(20,'and none of them sits in CENTRAL',
 $q$SELECT bool_or((e->>'is_central')::boolean)::text FROM golden.scratch s, LATERAL jsonb_array_elements(s.value) e WHERE s.fixture_id=18 AND s.key='wh'$q$,'eq','false'),
(21,'⭐ Article 6: the rows are INSERTed Active and unquarantined. The RPC must never UPDATE status on an existing row - a spot buy creates a new batch, it does not resurrect an Inactive one.',
 $q$SELECT bool_and((e->>'status')='Active' AND NOT (e->>'quarantined')::boolean)::text FROM golden.scratch s, LATERAL jsonb_array_elements(s.value) e WHERE s.fixture_id=18 AND s.key='wh'$q$,'eq','true'),
(22,'each batch_id carries the SPOT marker, so spot stock is traceable in FEFO forever',
 $q$SELECT bool_and((e->>'batch_has_spot')::boolean)::text FROM golden.scratch s, LATERAL jsonb_array_elements(s.value) e WHERE s.fixture_id=18 AND s.key='wh'$q$,'eq','true'),
(23,'the received quantities are the quantities bought',
 $q$SELECT string_agg(e->>'stock', ',' ORDER BY (e->>'stock')::numeric) FROM golden.scratch s, LATERAL jsonb_array_elements(s.value) e WHERE s.fixture_id=18 AND s.key='wh'$q$,'eq','4,8'),
(24,'snapshot_date is today on every batch - a spot receive is a today fact',
 $q$SELECT bool_and((e->>'snapshot_today')::boolean)::text FROM golden.scratch s, LATERAL jsonb_array_elements(s.value) e WHERE s.fixture_id=18 AND s.key='wh'$q$,'eq','true'),

-- C. PO-side parity with receive_purchase_order -----------------------------
(25,'received_date is stamped on every line',
 $q$SELECT bool_and((e->>'received_date_set')::boolean)::text FROM golden.scratch s, LATERAL jsonb_array_elements(s.value) e WHERE s.fixture_id=18 AND s.key='po'$q$,'eq','true'),
(26,'...and it is TODAY, not the 2030 dispatch date. The plan date and the purchase date are different clocks and mixing them would corrupt procurement reporting.',
 $q$SELECT bool_and((e->>'received_date_today')::boolean)::text FROM golden.scratch s, LATERAL jsonb_array_elements(s.value) e WHERE s.fixture_id=18 AND s.key='po'$q$,'eq','true'),
(27,'purchase_outcome is ''received'' on every line',
 $q$SELECT bool_and((e->>'outcome')='received')::text FROM golden.scratch s, LATERAL jsonb_array_elements(s.value) e WHERE s.fixture_id=18 AND s.key='po'$q$,'eq','true'),
(28,'received_qty equals ordered_qty - a full spot receive',
 $q$SELECT bool_and((e->>'received_qty')::numeric = (e->>'ordered_qty')::numeric)::text FROM golden.scratch s, LATERAL jsonb_array_elements(s.value) e WHERE s.fixture_id=18 AND s.key='po'$q$,'eq','true'),
(29,'total_price_aed is qty x price on every line, computed rather than trusted',
 $q$SELECT bool_and((e->>'total_is_qty_x_price')::boolean)::text FROM golden.scratch s, LATERAL jsonb_array_elements(s.value) e WHERE s.fixture_id=18 AND s.key='po'$q$,'eq','true'),
(30,'the per-line expiry_date propagated to the PO row (BUG-007/009 lives on the other side of this)',
 $q$SELECT bool_and((e->>'expiry') IS NOT NULL)::text FROM golden.scratch s, LATERAL jsonb_array_elements(s.value) e WHERE s.fixture_id=18 AND s.key='po'$q$,'eq','true'),
(31,'every line carries the po_number (trg_po_number_one_po_id keeps one number per po_id)',
 $q$SELECT bool_and((e->>'po_number_set')::boolean)::text FROM golden.scratch s, LATERAL jsonb_array_elements(s.value) e WHERE s.fixture_id=18 AND s.key='po'$q$,'eq','true'),

-- D. the FEFO bind, and the assertion that keeps it machine-scoped ----------
(32,'the waiting dispatch line is now bound',
 $q$SELECT (value->>'a_bound') FROM golden.scratch WHERE fixture_id=18 AND key='bind'$q$,'eq','true'),
(33,'⭐ it is bound to THIS spot batch, not to some pre-existing stock that happened to be pickable - otherwise the whole spot buy proved nothing',
 $q$SELECT (value->>'a_batch_is_ours') FROM golden.scratch WHERE fixture_id=18 AND key='bind'$q$,'eq','true'),
(34,'the bound line still sources from MCC',
 $q$SELECT (value->>'a_from_wh_is_mcc') FROM golden.scratch WHERE fixture_id=18 AND key='bind'$q$,'eq','true'),
(35,'⛔ S-143 - THE ASSERTION THAT MUST NOT BE WEAKENED. A second machine''s identically-blocked line is STILL UNBOUND. bind_dispatch_fefo(NULL) sweeps the entire fleet; anyone who "simplifies" the call to drop the machine scope binds other machines to this driver''s Carrefour batch, and only this assertion catches it.',
 $q$SELECT (value->>'b_bound') FROM golden.scratch WHERE fixture_id=18 AND key='bind'$q$,'eq','false'),
(36,'⭐ still_unbound_no_wh_stock is SURFACED in the return payload, not swallowed - a spot buy of the wrong item binds nothing and the caller has to be told',
 $q$SELECT ((value->'still_unbound_no_wh_stock') IS NOT NULL)::text FROM golden.scratch WHERE fixture_id=18 AND key='result'$q$,'eq','true'),

-- E. blocked_demand: the first resolutions in the table's history -----------
(37,'the fully-covered block is resolved as a spot buy',
 $q$SELECT (value->>'b1_resolution') FROM golden.scratch WHERE fixture_id=18 AND key='blocked'$q$,'eq','spot_buy'),
(38,'resolved_at is stamped (and the pair constraint therefore held)',
 $q$SELECT (value->>'b1_resolved_at_set') FROM golden.scratch WHERE fixture_id=18 AND key='blocked'$q$,'eq','true'),
(39,'resolved_by is the CALLER, not the definer - a SECURITY DEFINER function that credits itself loses the audit trail',
 $q$SELECT (value->>'b1_resolved_by_is_caller') FROM golden.scratch WHERE fixture_id=18 AND key='blocked'$q$,'eq','true'),
(40,'⛔ LAW 5. A 4-unit spot buy does NOT close a 10-unit block: the row stays OPEN. Silently closing it is exactly the silent-qty-0 failure the law exists for.',
 $q$SELECT (value->>'b2_still_open') FROM golden.scratch WHERE fixture_id=18 AND key='blocked'$q$,'eq','true'),
(41,'...and the shortfall is written down in words, so the next reader knows 6 units are still owed',
 $q$SELECT (value->>'b2_note') FROM golden.scratch WHERE fixture_id=18 AND key='blocked'$q$,'contains','6 still outstanding'),
(42,'⛔ THE LIVE-SAFETY INVARIANT. Every OTHER open blocked_demand row in the table is still open. The RPC resolves by machine+product; if production data ever grows a row matching this fixture''s machine and SKU, this assertion goes red BEFORE the fixture closes a real block.',
 $q$SELECT (value->>'live_rows_closed') FROM golden.scratch WHERE fixture_id=18 AND key='blocked'$q$,'eq','0'),

-- F. L2 / S-142 / S-147: the driver task ------------------------------------
(43,'⭐ S-142 confirmed live: the walk-in supplier really did force a driver task - the incumbent created exactly one',
 $q$SELECT (value->>'n') FROM golden.scratch WHERE fixture_id=18 AND key='task'$q$,'eq','1'),
(44,'⛔ S-147: it is CLOSED as ''collected'', which is literally true (the goods were collected at the counter). driver_tasks.status has no ''completed'' - the design''s auto-close would have raised.',
 $q$SELECT (value->>'status') FROM golden.scratch WHERE fixture_id=18 AND key='task'$q$,'eq','collected'),
(45,'⛔ ...and it was CLOSED, never DELETEd (Article 7). n=1 above plus a terminal status here is the pair that proves it: a deleted task would read n=0.',
 $q$SELECT (value->>'outcome') FROM golden.scratch WHERE fixture_id=18 AND key='task'$q$,'eq','purchased_full'),
(46,'collected_at is stamped, so the task has a real terminal timestamp rather than a status flipped in place',
 $q$SELECT (value->>'collected_set') FROM golden.scratch WHERE fixture_id=18 AND key='task'$q$,'eq','true'),
(47,'the auto-close says who closed it and why - a task that closes itself with no explanation is how people stop trusting the board',
 $q$SELECT (value->>'comment_has_auto') FROM golden.scratch WHERE fixture_id=18 AND key='task'$q$,'eq','true'),

-- G. the event log ----------------------------------------------------------
(48,'the spot purchase itself is logged',
 $q$SELECT (value->>'types') FROM golden.scratch WHERE fixture_id=18 AND key='events'$q$,'contains','spot_purchase_created'),
(49,'and so is the task auto-close, separately - one event that meant two things would be unreadable later',
 $q$SELECT (value->>'types') FROM golden.scratch WHERE fixture_id=18 AND key='events'$q$,'contains','spot_purchase_task_autoclosed'),
(50,'⛔ S-146 AS A CORRECTNESS PROPERTY, NOT AN OMISSION. The RPC writes ZERO inventory_events. That table is machine+shelf grained with both NOT NULL; inventing a shelf_id for a WAREHOUSE receive would poison the P1.4 composition estimator. spot_buy_receive belongs to the moment goods enter a SHELF - P4.4b, not here.',
 $q$SELECT (value->>'ie_delta') FROM golden.scratch WHERE fixture_id=18 AND key='events'$q$,'eq','0'),

-- H. the dry run is genuinely dry -------------------------------------------
(51,'a dry run creates NO purchase_orders rows',
 $q$SELECT (value->>'po') FROM golden.scratch WHERE fixture_id=18 AND key='dry'$q$,'eq','0'),
(52,'⛔ a dry run creates NO warehouse_inventory rows - phantom WH stock is pickable by the live FEFO binder within minutes',
 $q$SELECT (value->>'wh') FROM golden.scratch WHERE fixture_id=18 AND key='dry'$q$,'eq','0'),
(53,'a dry run resolves NO blocked demand',
 $q$SELECT (value->>'bd') FROM golden.scratch WHERE fixture_id=18 AND key='dry'$q$,'eq','0'),
(54,'a dry run writes NO procurement_events',
 $q$SELECT (value->>'pe') FROM golden.scratch WHERE fixture_id=18 AND key='dry'$q$,'eq','0'),
(55,'a dry run binds NOTHING - the dispatch line is still unbound after it',
 $q$SELECT (value->>'bound_a') FROM golden.scratch WHERE fixture_id=18 AND key='dry'$q$,'eq','false'),
(56,'it reports committed=false rather than implying success',
 $q$SELECT (value->>'committed') FROM golden.scratch WHERE fixture_id=18 AND key='dry'$q$,'eq','false'),
(57,'⭐ S-133 is stated in the payload: a rolled-back dry run does NOT check DEFERRED constraints, so it must not be read as full validation',
 $q$SELECT (value->>'deferred_flag') FROM golden.scratch WHERE fixture_id=18 AND key='dry'$q$,'eq','true'),

-- I. every guard actually fires (S-126: a guard that never fires is not a guard)
(58,'⛔ S-144 INVERTED FROM THE DESIGN. field_staff is REFUSED, not allowed. bind_dispatch_fefo refuses field_staff outright, so gating this RPC lower would have raised inside the happy path. A new RPC must never hand a role a power its own component writers deny.',
 $q$SELECT (value->>'field_staff') FROM golden.scratch WHERE fixture_id=18 AND key='refusals'$q$,'contains','not authorized (warehouse+ only'),
(59,'a NULL expiry is refused - the spot path must not become the hole through which NULL-expiry rows enter warehouse_inventory (BUG-007/009)',
 $q$SELECT (value->>'null_expiry') FROM golden.scratch WHERE fixture_id=18 AND key='refusals'$q$,'contains','expiry_date is REQUIRED'),
(60,'an already-expired line is refused (EXPIRY IRON RULE)',
 $q$SELECT (value->>'past_expiry') FROM golden.scratch WHERE fixture_id=18 AND key='refusals'$q$,'contains','is in the past'),
(61,'qty 0 is refused rather than silently received as nothing (LAW 5)',
 $q$SELECT (value->>'qty_zero') FROM golden.scratch WHERE fixture_id=18 AND key='refusals'$q$,'contains','qty must be > 0'),
(62,'an Inactive supplier is refused',
 $q$SELECT (value->>'sup_inactive') FROM golden.scratch WHERE fixture_id=18 AND key='refusals'$q$,'contains','Active required'),
(63,'a supplier_delivered supplier is refused - a spot buy is walk_in by definition',
 $q$SELECT (value->>'sup_not_walkin') FROM golden.scratch WHERE fixture_id=18 AND key='refusals'$q$,'contains','walk_in by definition'),
(64,'⭐ the PRD-1 blocked-product guardrail is INHERITED from create_purchase_order, not re-implemented - a spot buy of a decommissioned product fails exactly as a planned order does',
 $q$SELECT (value->>'blocked_product') FROM golden.scratch WHERE fixture_id=18 AND key='refusals'$q$,'contains','BLOCKED for ordering'),
(65,'an unknown warehouse is refused',
 $q$SELECT (value->>'wh_unknown') FROM golden.scratch WHERE fixture_id=18 AND key='refusals'$q$,'contains','not found'),
(66,'⛔ a NULL warehouse is refused outright. There is no safe default: defaulting to CENTRAL is precisely the L1 bug, and the binder would then look in the wrong place.',
 $q$SELECT (value->>'wh_null') FROM golden.scratch WHERE fixture_id=18 AND key='refusals'$q$,'contains','p_warehouse_id is REQUIRED'),
(67,'an unknown product is refused',
 $q$SELECT (value->>'prod_unknown') FROM golden.scratch WHERE fixture_id=18 AND key='refusals'$q$,'contains','not found'),
(68,'an empty line array is refused',
 $q$SELECT (value->>'no_lines') FROM golden.scratch WHERE fixture_id=18 AND key='refusals'$q$,'contains','at least one line is required'),
(69,'an unknown machine is refused - the machine name is what scopes the bind, so a bad one must not fall through to a fleet sweep',
 $q$SELECT (value->>'machine_unknown') FROM golden.scratch WHERE fixture_id=18 AND key='refusals'$q$,'contains','machine 00000000-0000-0000-0000-0000000000fd not found'),

-- J. Cody condition 3: the provenance GUCs do not leak ----------------------
(70,'⛔ app.via_rpc is RESTORED after the RPC returns. These GUCs leak across statements in this codebase (PRD-016B); a spot buy that left via_rpc set would make the next unrelated write look like an RPC.',
 $q$SELECT (value->>'via_rpc') FROM golden.scratch WHERE fixture_id=18 AND key='gucs'$q$,'eq',''),
(71,'⭐ app.rpc_name is restored to the CALLER''s value, not merely cleared - the harness set golden.fixture_18 before the call and it is still that afterwards. A blanket reset would look identical on an empty inbound value, which is why the harness sets one.',
 $q$SELECT (value->>'rpc_name') FROM golden.scratch WHERE fixture_id=18 AND key='gucs'$q$,'eq','golden.fixture_18'),
(72,'app.provenance_reason is restored too, so the next warehouse write names its own provenance',
 $q$SELECT (value->>'prov') FROM golden.scratch WHERE fixture_id=18 AND key='gucs'$q$,'eq',''),

-- K. the fixture leaves nothing behind --------------------------------------
(73,'⛔ ZERO purchase_orders residue (S-124: fixture residue has landed on live protected plan tables before)',
 $q$SELECT (value->>'po') FROM golden.scratch WHERE fixture_id=18 AND key='residue'$q$,'eq','0'),
(74,'⛔ ZERO warehouse_inventory residue - phantom spot stock would be handed to a real dispatch line by the next FEFO bind',
 $q$SELECT (value->>'wh') FROM golden.scratch WHERE fixture_id=18 AND key='residue'$q$,'eq','0'),
(75,'⛔ ZERO refill_dispatching residue on the 2030 plan date (LAW 12)',
 $q$SELECT (value->>'rd') FROM golden.scratch WHERE fixture_id=18 AND key='residue'$q$,'eq','0'),
(76,'ZERO blocked_demand residue - the planted blocks are gone, so the open count is unchanged run to run',
 $q$SELECT (value->>'bd') FROM golden.scratch WHERE fixture_id=18 AND key='residue'$q$,'eq','0'),
(77,'ZERO driver_tasks residue',
 $q$SELECT (value->>'dt') FROM golden.scratch WHERE fixture_id=18 AND key='residue'$q$,'eq','0'),
(78,'ZERO procurement_events residue',
 $q$SELECT (value->>'pe') FROM golden.scratch WHERE fixture_id=18 AND key='residue'$q$,'eq','0'),
(79,'⭐ and the proof is independent of the scenario''s own bookkeeping: no FX18-marked warehouse row exists in the table right now, read live at assertion time',
 $q$SELECT count(*)::text FROM public.warehouse_inventory WHERE wh_location='FX18'$q$,'eq','0'),
(80,'⭐ likewise no dispatch row survives on the fixture''s 2030 date, read live',
 $q$SELECT count(*)::text FROM public.refill_dispatching WHERE dispatch_date=DATE '2030-07-15'$q$,'eq','0')

) AS t(seq, descr, sql, op, expect);
