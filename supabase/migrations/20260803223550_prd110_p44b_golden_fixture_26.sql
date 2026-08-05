-- PRD-110 P4.4b Migration D - golden fixture 26: the post-facto fill at the machine.
--
-- LAW 1 clause 2: the 2026-07-30 01:21 incident is not closed until this is green.
-- Migrations A/B/C shipped the table and the two RPCs; this is the proof, and it
-- is the ONLY thing that can close the incident.
--
-- WHAT THE INCIDENT WAS, IN ONE LINE. A driver filled a shelf with 9 units - 8
-- bought at Carrefour, 1 from the warehouse - typed Filled=9, and
-- receive_dispatch_line REFUSED because the warehouse could not cover an
-- 8-unit overfill. The guard was RIGHT. The driver was stranded anyway.
--
-- ⛔ THE CONTROL IS WHAT MAKES THIS FIXTURE MEAN ANYTHING (design §7).
--    seq 5-7 call the OLD path receive_dispatch_line(d, 9) on the SAME shape and
--    require it to STILL RAISE the overfill error. A fixture that only shows the
--    new path working cannot tell you the guard survived - and the guard
--    surviving is half the design. receive_dispatch_line md5 28195f57, untouched.
--
-- HOW IT LEAVES NOTHING (the fixture-18 mechanism, reused deliberately).
--   The whole scenario is one plpgsql subtransaction ended by
--   `RAISE EXCEPTION 'FX26_ROLLBACK'`. Rows vanish; plpgsql VARIABLES survive.
--   Everything the assertions read is captured into s_* variables BEFORE the
--   unwind and written to golden.scratch after it.
--   ⚠️ The one thing a rollback cannot undo is nextval('po_number_seq'). This
--      fixture mints THREE POs per run (see below), so it burns three po_numbers.
--      Same accepted class as fixture 18's one and fixture 60's log rows.
--
-- ⛔ WHY THREE SEPARATE POs AND NOT ONE. Phase 1's caller here is field_staff,
--    and S-145 makes the attach path (add_purchase_order_lines) owner-only. So
--    _resolve_open_walkin_po_v3 ALWAYS mints for a driver. That is not a
--    limitation to work around - it is the property that stops this fixture from
--    ever attaching to, and then receiving, a REAL open Carrefour PO that
--    procurement happens to have open today. The role choice is the safety
--    property, exactly as it was in fixture 18.
--
-- THE TWO THINGS THIS FIXTURE HAD TO MEASURE RATHER THAN ASSUME:
--   * receive_dispatch_line debits the warehouse ONLY for the OVERFILL
--     (GREATEST(filled - planned, 0)); the planned units left the warehouse at
--     pack time. So on the incident replay (planned 1, n=1) the correct WH delta
--     is ZERO, not -1. Asserting "debited exactly n" there would have been
--     asserting a falsehood. seq 20 pins the zero; seq 21-22 add a SECOND leg
--     (planned 1, n=2, m=3) where the debit is genuinely non-zero, so that
--     "exactly n, never n+m" is proven by a delta that can actually move.
--   * shelf_composition for the target shelf was EMPTY before this fixture
--     (probed live), so the composition assertions read clean deltas.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes, enabled, baseline_status)
VALUES (
  26,
  'Post-facto spot buy at the machine: a driver who bought 8 units at a counter and put them straight in the machine can record filled=9 as an explicit 1-from-warehouse + 8-spot split - the warehouse is debited for the warehouse units ONLY, the spot units reach the shelf immediately and the PO line that pays for them stays unreceived until a receipt expiry closes it, and the OLD single-quantity path still refuses the same shape',
  'LIVE 2026-07-30 01:21 (driver: "I put 9 bcz I buy 8 zigi in carrefour and 1 pc from warehouse"). receive_dispatch_line correctly refused an 8-unit overfill the warehouse could not cover, and the driver was left holding goods the system had no way to accept. The guard stays; this is the happy path it was missing.',
  'P4',
  DATE '2030-08-04',
$fx26body$
DO $fx26$
DECLARE
  -- ---- fixed cast (every id re-probed live this leg, LAW 13) --------------
  c_mach     uuid := '98868de9-a977-40f4-b0ea-ce787877f24a'; -- Batch_2, primary WH = CENTRAL
  -- ⛔ ONE SHELF PER LEG, AND IT IS NOT COSMETIC. prevent_duplicate_unstarted_dispatch
  --    refuses a second unstarted row for the same (machine, shelf, product, action,
  --    date) - discovered by this fixture, not documented anywhere. Separate shelves
  --    also keep the composition assertions readable: shelf_composition has no date
  --    grain, so five legs on one shelf would sum into a single unreadable total.
  --    All six probed live this leg: zero composition rows on every one.
  c_shelf    uuid := '0038e555-7883-4262-9b1b-ae9bd265214a'; -- A08 happy path
  c_sh2      uuid := '3388ead3-0e5b-4c7f-841e-31dc59ad6108'; -- A13 control
  c_sh3      uuid := '0e9367d8-48fa-445b-af11-ffa2bd0674a2'; -- A09 exact-n
  c_sh4      uuid := 'c86d8cff-53a6-428f-80e6-24925767f162'; -- A10 breakdown
  c_sh5      uuid := '04d07da0-7ccc-4ee8-84a6-9b8b66263d72'; -- A11 refusals + dry run
  c_sh6      uuid := 'b0e240a0-b398-44ea-aec7-d8150f36b1cd'; -- A12 Remove leg
  c_pA       uuid := '00103662-15c4-47c8-9a32-26d421fa9827'; -- NRJ Nut - Trail Mix
  c_pB       uuid := '8442c7aa-7c41-425e-9b0f-f2d5a3eb87c3'; -- NRJ Nut - Cashew Sesame
  c_sup      uuid := 'a44b3e6c-0b6f-45b9-a5fa-9c911b8ac322'; -- Carrefour, Active walk_in
  c_sup_inac uuid := '3cec0b3a-be06-4104-a88b-6a69e8f247d7'; -- Union Coop DUP, Inactive walk_in
  c_sup_deli uuid := '7140e8d1-ba97-4265-8bc1-959817fe7eb0'; -- Active but supplier_delivered
  c_u_field  uuid := '34b19df6-d6c7-4008-9a51-63e5c09fa134'; -- field_staff (phase 1 gate)
  c_u_wh     uuid := '7f4ecaa4-1efe-4a32-b233-35f5516f6131'; -- warehouse   (phase 2 gate)
  c_central  uuid := '4bebef68-9e36-4a5c-9c2c-142f8dbdae85';
  c_date     date := DATE '2030-08-04';
  c_exp      date := CURRENT_DATE + 120;

  v_d1 uuid; v_d2 uuid; v_d3 uuid; v_d4 uuid; v_d5 uuid; v_d6 uuid;
  v_batch uuid; v_b0 numeric; v_b1 numeric; v_b2 numeric;
  v_wh_rows_before int; v_wh_rows_after int; v_bvl_before bigint;
  v_res jsonb; v_res3 jsonb; v_res4 jsonb; v_dry jsonb;
  v_p2a jsonb; v_p2b jsonb; v_p2lines jsonb; v_bd jsonb;
  v_po1 text; v_po3 text; v_po4 text;
  v_comp_a jsonb; v_comp_b jsonb;

  s_ctrl jsonb; s_happy jsonb; s_split jsonb; s_bd jsonb;
  s_p2 jsonb; s_refusals jsonb; s_dry jsonb; s_gucs jsonb;

  v_ctrl  text := 'NOT REFUSED';
  v_r1 text:='NOT REFUSED'; v_r2 text:='NOT REFUSED'; v_r3 text:='NOT REFUSED';
  v_r4 text:='NOT REFUSED'; v_r5 text:='NOT REFUSED'; v_r6 text:='NOT REFUSED';
  v_r7 text:='NOT REFUSED'; v_r8 text:='NOT REFUSED'; v_r9 text:='NOT REFUSED';
  v_r10 text:='NOT REFUSED'; v_r11 text:='NOT REFUSED';
BEGIN
  PERFORM set_config('app.rpc_name', 'golden.fixture_26', true);
  DELETE FROM golden.scratch WHERE fixture_id = 26;
  -- Governance-table residue is the kind nobody notices: enforce_canonical_dispatch_write
  -- LOGS rather than blocks, so a harness plant that forgot app.via_trigger would mint
  -- bypass_violation_log rows on every run and nothing would ever go red.
  SELECT count(*) INTO v_bvl_before FROM public.bypass_violation_log;

  BEGIN
    ------------------------------------------------------------- 1. plant --
    -- via_trigger: enforce_canonical_dispatch_write LOGS rather than blocks, so
    -- a harness plant without this mints bypass_violation_log rows on every run
    -- - residue in a governance table, invisible until someone reads it.
    PERFORM set_config('app.via_trigger', 'true', true);

    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity,
       from_warehouse_id, comment, source_kind, source_warehouse_id)
    VALUES (c_mach, c_shelf, c_pA, c_date, 'Refill', 1, c_central,
            'FX26 the incident line - planned 1, driver fills 9', 'wh', c_central)
    RETURNING dispatch_id INTO v_d1;

    -- the CONTROL: identical shape, reserved for the OLD call path.
    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity,
       from_warehouse_id, comment, source_kind, source_warehouse_id)
    VALUES (c_mach, c_sh2, c_pA, c_date, 'Refill', 1, c_central,
            'FX26 CONTROL - receive_dispatch_line(9) must still refuse', 'wh', c_central)
    RETURNING dispatch_id INTO v_d2;

    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity,
       from_warehouse_id, comment, source_kind, source_warehouse_id)
    VALUES (c_mach, c_sh3, c_pA, c_date, 'Refill', 1, c_central,
            'FX26 exact-n leg - n exceeds planned so the WH delta can move', 'wh', c_central)
    RETURNING dispatch_id INTO v_d3;

    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity,
       from_warehouse_id, comment, source_kind, source_warehouse_id)
    VALUES (c_mach, c_sh4, c_pA, c_date, 'Refill', 1, c_central,
            'FX26 breakdown leg - flavours enumerated', 'wh', c_central)
    RETURNING dispatch_id INTO v_d4;

    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity,
       from_warehouse_id, comment, source_kind, source_warehouse_id)
    VALUES (c_mach, c_sh5, c_pA, c_date, 'Refill', 1, c_central,
            'FX26 refusal + dry-run probe line', 'wh', c_central)
    RETURNING dispatch_id INTO v_d5;

    -- a Remove leg: a spot fill has nowhere to land on one.
    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity,
       from_warehouse_id, comment, source_kind, source_warehouse_id)
    VALUES (c_mach, c_sh6, c_pA, c_date, 'Remove', 1, c_central,
            'FX26 Remove leg - spot fill must be refused here', 'wh', c_central)
    RETURNING dispatch_id INTO v_d6;

    -- ⛔ THE FIXTURE PLANTS ITS OWN WAREHOUSE BATCH, AND THE REASON IS THE 2030
    --    PLAN DATE. wh_fefo_for_line judges shelf life against the LINE's date, so
    --    on a 2030 date EVERY real batch of this product (all expiring 2026-09-08)
    --    is already expired and pickable stock is ZERO. Measured, not guessed: the
    --    first draft of this fixture leaned on the two real Active units and the
    --    exact-n leg raised "short by 1".
    --    Planting 2 units at a 2031 expiry makes all three legs deterministic and
    --    independent of production stock drift:
    --      control (overfill 8) -> short by 6 -> still RAISES, which is the point
    --      happy   (n=1=planned, overfill 0) -> no debit at all
    --      exact-n (n=2, overfill 1)          -> debits exactly 1
    --    ⛔ EXPIRY IRON RULE is not in play: this is a plant of in-date stock, not
    --       an assumption about expired stock leaving.
    PERFORM set_config('app.via_trigger', 'true', true);
    -- ⛔ provenance_reason IS NOT OPTIONAL HERE, AND OMITTING IT FAILS SILENTLY.
    --    warehouse_inventory.quarantined is a GENERATED column: TRUE whenever
    --    provenance_reason IS NULL (or is 'unknown_pre_migration' /
    --    'dispatch_return_unverified'). v_wh_pickable excludes quarantined rows,
    --    so a plant without this lands a row that LOOKS Active and in-date and is
    --    invisible to FEFO. That is exactly how the second draft of this fixture
    --    failed - with the same "short by 1" message as the first, for a
    --    completely different reason.
    --    ⛔ AND 'snapshot' IS THE ONLY HONEST CHOICE OF THE FIFTEEN LEGAL VALUES:
    --       wh_provenance_event_required demands a source_event_id for every
    --       provenance EXCEPT manual_adjust / snapshot / status_flip /
    --       unknown_pre_migration / unattributed_write, and of those only
    --       snapshot and manual_adjust avoid quarantining the row. This IS a
    --       planted snapshot; naming it 'dispatch_receive' would have been a lie
    --       that also needed a fake event id.
    INSERT INTO public.warehouse_inventory
      (boonz_product_id, warehouse_stock, expiration_date, status, batch_id,
       snapshot_date, warehouse_id, wh_location, provenance_reason)
    VALUES (c_pA, 2, DATE '2031-12-31', 'Active', 'FX26-PLANT', CURRENT_DATE,
            c_central, 'FX26', 'snapshot')
    RETURNING wh_inventory_id, warehouse_stock INTO v_batch, v_b0;
    PERFORM set_config('app.via_trigger', '', true);

    SELECT count(*) INTO v_wh_rows_before FROM public.warehouse_inventory;

    PERFORM set_config('request.jwt.claims',
      format('{"sub":"%s","role":"authenticated"}', c_u_field), true);

    -------------------------------------------------- 2. THE CONTROL FIRST --
    -- The old path, the incident's exact call, on an untouched line. It must
    -- still raise. Its own subtransaction, so the failed attempt leaves nothing.
    BEGIN
      PERFORM public.receive_dispatch_line(v_d2, 9, c_u_field);
      v_ctrl := 'NOT REFUSED';
    EXCEPTION WHEN OTHERS THEN v_ctrl := SQLERRM; END;

    SELECT jsonb_build_object(
      'err', v_ctrl,
      'line_untouched', (SELECT NOT COALESCE(item_added,false) FROM public.refill_dispatching WHERE dispatch_id = v_d2),
      'batch_untouched', ((SELECT warehouse_stock FROM public.warehouse_inventory WHERE wh_inventory_id = v_batch) = v_b0))
      INTO s_ctrl;

    ------------------------------------------------- 3. THE HAPPY PATH (d1) --
    -- planned 1; the driver puts in 9 = 1 from the warehouse + 8 bought at a
    -- counter. p_spot_breakdown NULL: the 07-30 driver said "8 zigi" and never
    -- enumerated the flavours. An honest pod-level record beats an invented one.
    v_res := public.receive_dispatch_line_sourced_v3(
               v_d1, 1, 8, c_sup, NULL, 3.5, 'receipt://FX26', 'FX26 pod-level', c_u_field, false);
    v_po1 := v_res->>'po_id';
    SELECT warehouse_stock INTO v_b1 FROM public.warehouse_inventory WHERE wh_inventory_id = v_batch;

    SELECT jsonb_build_object(
      'ok',              v_res->>'ok',
      'po_path',         v_res->>'po_path',
      'filled_quantity', v_res->>'filled_quantity',
      'qty_from_wh',     v_res->>'qty_from_wh',
      'qty_spot',        v_res->>'qty_spot',
      'sku_resolved',    v_res->>'sku_resolved',
      'phase_2_pending', v_res->>'phase_2_pending',
      'rd_filled',      (SELECT filled_quantity::int FROM public.refill_dispatching WHERE dispatch_id = v_d1),
      'rd_received',    (SELECT COALESCE(item_added,false) FROM public.refill_dispatching WHERE dispatch_id = v_d1),
      'sf_n',           (SELECT count(*)::int FROM public.spot_fill_v3 WHERE dispatch_id = v_d1),
      'sf_qty',         (SELECT COALESCE(sum(qty),0)::int FROM public.spot_fill_v3 WHERE dispatch_id = v_d1),
      'sf_status',      (SELECT min(status) FROM public.spot_fill_v3 WHERE dispatch_id = v_d1),
      'sf_expiry_null', (SELECT bool_and(expiry_date IS NULL) FROM public.spot_fill_v3 WHERE dispatch_id = v_d1),
      'sf_sku_res',     (SELECT bool_and(sku_resolved) FROM public.spot_fill_v3 WHERE dispatch_id = v_d1),
      'sf_is_line_prod',(SELECT bool_and(boonz_product_id = c_pA) FROM public.spot_fill_v3 WHERE dispatch_id = v_d1),
      'comp_null',      (SELECT COALESCE(sum(est_qty),0)::int FROM public.shelf_composition
                          WHERE shelf_id = c_shelf AND boonz_product_id = c_pA AND expiry_bucket IS NULL),
      'comp_total',     (SELECT COALESCE(sum(est_qty),0)::int FROM public.shelf_composition
                          WHERE shelf_id = c_shelf AND boonz_product_id = c_pA),
      'ie_kind',        (SELECT string_agg(DISTINCT kind, ',') FROM public.inventory_events
                          WHERE source_ref LIKE 'spot_fill:%'),
      'ie_delta',       (SELECT COALESCE(sum(qty_delta),0)::int FROM public.inventory_events
                          WHERE source_ref LIKE 'spot_fill:%'),
      'batch_delta',    (v_b1 - v_b0)::int,
      'po_lines',       (SELECT count(*)::int FROM public.purchase_orders WHERE po_id = v_po1),
      'po_ordered',     (SELECT COALESCE(sum(ordered_qty),0)::int FROM public.purchase_orders WHERE po_id = v_po1),
      'po_unreceived',  (SELECT bool_and(received_date IS NULL) FROM public.purchase_orders WHERE po_id = v_po1),
      'pe_phase1',      (SELECT count(*)::int FROM public.procurement_events
                          WHERE po_id = v_po1 AND event_type = 'post_facto_fill_recorded'))
      INTO s_happy;

    ------------------------------------- 4. the exact-n leg (d3): n=2, m=3 ---
    -- planned 1, so overfill = n - planned = 1 and the warehouse delta is a real
    -- non-zero number. If the implementation ever passed n+m to the incumbent,
    -- overfill would be 4, the batch would be short, and this leg would RAISE.
    v_res3 := public.receive_dispatch_line_sourced_v3(
                v_d3, 2, 3, c_sup, NULL, 3.5, NULL, 'FX26 exact-n', c_u_field, false);
    v_po3 := v_res3->>'po_id';
    SELECT warehouse_stock INTO v_b2 FROM public.warehouse_inventory WHERE wh_inventory_id = v_batch;

    SELECT jsonb_build_object(
      'filled',      v_res3->>'filled_quantity',
      'batch_delta', (v_b2 - v_b1)::int,
      'wh_overfill', (v_res3->'wh_leg'->>'overfill'),
      'sf_qty',      (SELECT COALESCE(sum(qty),0)::int FROM public.spot_fill_v3 WHERE dispatch_id = v_d3))
      INTO s_split;

    ----------------------------------------- 5. the breakdown leg (d4) ------
    v_bd := jsonb_build_array(
      jsonb_build_object('boonz_product_id', c_pA, 'qty', 2),
      jsonb_build_object('boonz_product_id', c_pB, 'qty', 2));
    v_res4 := public.receive_dispatch_line_sourced_v3(
                v_d4, 1, 4, c_sup, v_bd, 2.0, NULL, 'FX26 breakdown', c_u_field, false);
    v_po4 := v_res4->>'po_id';

    SELECT jsonb_build_object(
      'sku_resolved', v_res4->>'sku_resolved',
      'rows',        (SELECT count(*)::int FROM public.spot_fill_v3 WHERE dispatch_id = v_d4),
      'sum',         (SELECT COALESCE(sum(qty),0)::int FROM public.spot_fill_v3 WHERE dispatch_id = v_d4),
      'all_resolved',(SELECT bool_and(sku_resolved) FROM public.spot_fill_v3 WHERE dispatch_id = v_d4),
      'products',    (SELECT count(DISTINCT boonz_product_id)::int FROM public.spot_fill_v3 WHERE dispatch_id = v_d4))
      INTO s_bd;

    ----------------------------------------------- 6. PHASE 2, RUN TWICE ----
    -- ⛔ The highest-risk defect in the whole unit is a phase-2 double-add.
    --    Composition after run 2 must equal composition after run 1.
    PERFORM set_config('request.jwt.claims',
      format('{"sub":"%s","role":"authenticated"}', c_u_wh), true);

    SELECT jsonb_agg(jsonb_build_object(
             'spot_fill_id', spot_fill_id,
             'expiry_date',  c_exp::text,
             'price_per_unit_aed', 3.5))
      INTO v_p2lines FROM public.spot_fill_v3 WHERE dispatch_id = v_d1;

    v_p2a := public.receive_spot_fill_po_v3(v_po1, v_p2lines, c_u_wh, false);
    SELECT jsonb_build_object(
      'total', COALESCE(sum(est_qty),0)::int,
      'null_bucket', COALESCE(sum(est_qty) FILTER (WHERE expiry_bucket IS NULL),0)::int,
      'exp_bucket',  COALESCE(sum(est_qty) FILTER (WHERE expiry_bucket = c_exp),0)::int)
      INTO v_comp_a
      FROM public.shelf_composition WHERE shelf_id = c_shelf AND boonz_product_id = c_pA;

    v_p2b := public.receive_spot_fill_po_v3(v_po1, v_p2lines, c_u_wh, false);
    SELECT jsonb_build_object(
      'total', COALESCE(sum(est_qty),0)::int,
      'null_bucket', COALESCE(sum(est_qty) FILTER (WHERE expiry_bucket IS NULL),0)::int,
      'exp_bucket',  COALESCE(sum(est_qty) FILTER (WHERE expiry_bucket = c_exp),0)::int)
      INTO v_comp_b
      FROM public.shelf_composition WHERE shelf_id = c_shelf AND boonz_product_id = c_pA;

    SELECT count(*) INTO v_wh_rows_after FROM public.warehouse_inventory;

    SELECT jsonb_build_object(
      'a_received',  v_p2a->>'lines_received',
      'a_wh_rows',   v_p2a->>'warehouse_rows_created',
      'a_net_delta', v_p2a->>'composition_net_delta',
      'b_received',  v_p2b->>'lines_received',
      'b_skipped',   v_p2b->>'lines_skipped',
      'b_skip_reason', (v_p2b->'skipped'->0->>'reason'),
      'comp_a', v_comp_a, 'comp_b', v_comp_b,
      'comp_identical', (v_comp_a = v_comp_b),
      'sf_status',    (SELECT min(status) FROM public.spot_fill_v3 WHERE dispatch_id = v_d1),
      'sf_expiry',    (SELECT min(expiry_date)::text FROM public.spot_fill_v3 WHERE dispatch_id = v_d1),
      'po_outcome',   (SELECT min(purchase_outcome) FROM public.purchase_orders WHERE po_id = v_po1),
      'po_recv_qty',  (SELECT COALESCE(sum(received_qty),0)::int FROM public.purchase_orders WHERE po_id = v_po1),
      'po_expiry',    (SELECT min(expiry_date)::text FROM public.purchase_orders WHERE po_id = v_po1),
      'pe_received',  (SELECT count(*)::int FROM public.procurement_events
                        WHERE po_id = v_po1 AND event_type = 'post_facto_fill_received'),
      'wh_rows_created', (v_wh_rows_after - v_wh_rows_before))
      INTO s_p2;

    ------------------------------------------- 7. every refusal, made to fire --
    PERFORM set_config('request.jwt.claims',
      format('{"sub":"%s","role":"authenticated"}', c_u_field), true);

    BEGIN PERFORM public.receive_dispatch_line_sourced_v3(v_d5, 1, 2, NULL, NULL, 3.5, NULL, 'FX26 r1', c_u_field, false);
    EXCEPTION WHEN OTHERS THEN v_r1 := SQLERRM; END;

    BEGIN PERFORM public.receive_dispatch_line_sourced_v3(v_d5, 1, 2, c_sup_inac, NULL, 3.5, NULL, 'FX26 r2', c_u_field, false);
    EXCEPTION WHEN OTHERS THEN v_r2 := SQLERRM; END;

    BEGIN PERFORM public.receive_dispatch_line_sourced_v3(v_d5, 1, 2, c_sup_deli, NULL, 3.5, NULL, 'FX26 r3', c_u_field, false);
    EXCEPTION WHEN OTHERS THEN v_r3 := SQLERRM; END;

    BEGIN PERFORM public.receive_dispatch_line_sourced_v3(v_d5, 0, 0, c_sup, NULL, 3.5, NULL, 'FX26 r4', c_u_field, false);
    EXCEPTION WHEN OTHERS THEN v_r4 := SQLERRM; END;

    BEGIN PERFORM public.receive_dispatch_line_sourced_v3(v_d5, -1, 2, c_sup, NULL, 3.5, NULL, 'FX26 r5', c_u_field, false);
    EXCEPTION WHEN OTHERS THEN v_r5 := SQLERRM; END;

    BEGIN PERFORM public.receive_dispatch_line_sourced_v3(v_d5, 1, 4, c_sup,
      jsonb_build_array(jsonb_build_object('boonz_product_id', c_pA, 'qty', 2)),
      3.5, NULL, 'FX26 r6', c_u_field, false);
    EXCEPTION WHEN OTHERS THEN v_r6 := SQLERRM; END;

    BEGIN PERFORM public.receive_dispatch_line_sourced_v3(v_d6, 1, 2, c_sup, NULL, 3.5, NULL, 'FX26 r7', c_u_field, false);
    EXCEPTION WHEN OTHERS THEN v_r7 := SQLERRM; END;

    -- S-177: prove the CHECK by attempting the forbidden UPDATE, never by
    -- reading the predicate. A received row with a NULL expiry is the exact hole
    -- through which undated stock would reach a shelf.
    BEGIN
      UPDATE public.spot_fill_v3 SET status = 'received', received_at = now()
       WHERE dispatch_id = v_d4;
      v_r8 := 'NOT REFUSED';
    EXCEPTION WHEN OTHERS THEN v_r8 := SQLERRM; END;

    -- phase 2 is warehouse+; the driver who filled the machine cannot close the
    -- money side. Still impersonating field_staff here.
    BEGIN PERFORM public.receive_spot_fill_po_v3(v_po4, '[]'::jsonb, c_u_field, false);
    EXCEPTION WHEN OTHERS THEN v_r9 := SQLERRM; END;

    PERFORM set_config('request.jwt.claims',
      format('{"sub":"%s","role":"authenticated"}', c_u_wh), true);

    BEGIN
      PERFORM public.receive_spot_fill_po_v3(v_po4,
        (SELECT jsonb_agg(jsonb_build_object('spot_fill_id', spot_fill_id))
           FROM public.spot_fill_v3 WHERE dispatch_id = v_d4), c_u_wh, false);
    EXCEPTION WHEN OTHERS THEN v_r10 := SQLERRM; END;

    BEGIN
      PERFORM public.receive_spot_fill_po_v3(v_po4,
        (SELECT jsonb_agg(jsonb_build_object('spot_fill_id', spot_fill_id,
                                             'expiry_date', '2099-12-31'))
           FROM public.spot_fill_v3 WHERE dispatch_id = v_d4), c_u_wh, false);
    EXCEPTION WHEN OTHERS THEN v_r11 := SQLERRM; END;

    s_refusals := jsonb_build_object(
      'no_supplier', v_r1, 'sup_inactive', v_r2, 'sup_not_walkin', v_r3,
      'nothing', v_r4, 'negative', v_r5, 'breakdown_mismatch', v_r6,
      'remove_leg', v_r7, 'received_null_expiry', v_r8,
      'p2_field_staff', v_r9, 'p2_null_expiry', v_r10, 'p2_sentinel', v_r11);

    -------------------------------------------------- 8. the dry run is dry --
    PERFORM set_config('request.jwt.claims',
      format('{"sub":"%s","role":"authenticated"}', c_u_field), true);
    v_dry := public.receive_dispatch_line_sourced_v3(
               v_d5, 1, 2, c_sup, NULL, 3.5, NULL, 'FX26 dry', c_u_field, true);

    SELECT jsonb_build_object(
      'committed',  v_dry->>'committed',
      'deferred',   v_dry->>'deferred_constraints_unchecked',
      'sf_rows',    (SELECT count(*)::int FROM public.spot_fill_v3 WHERE dispatch_id = v_d5),
      'rd_touched', (SELECT COALESCE(item_added,false) FROM public.refill_dispatching WHERE dispatch_id = v_d5))
      INTO s_dry;

    ------------------------------------- 9. Article 4: the GUCs are restored --
    PERFORM set_config('request.jwt.claims', '', true);
    SELECT jsonb_build_object(
      'via_rpc',  COALESCE(current_setting('app.via_rpc', true), '<unset>'),
      'rpc_name', COALESCE(current_setting('app.rpc_name', true), '<unset>'),
      'prov',     COALESCE(current_setting('app.provenance_reason', true), '<unset>'))
      INTO s_gucs;

    ------------------------------------------------------------ 10. unwind --
    RAISE EXCEPTION 'FX26_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'FX26_ROLLBACK' THEN RAISE; END IF;
  END;

  PERFORM set_config('app.via_trigger', '', true);
  PERFORM set_config('request.jwt.claims', '', true);

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES
    (26, 'control',  s_ctrl),
    (26, 'happy',    s_happy),
    (26, 'split',    s_split),
    (26, 'bd',       s_bd),
    (26, 'p2',       s_p2),
    (26, 'refusals', s_refusals),
    (26, 'dry',      s_dry),
    (26, 'gucs',     s_gucs),
    (26, 'residue',  jsonb_build_object(
       'rd', (SELECT count(*) FROM public.refill_dispatching
               WHERE dispatch_date = c_date AND comment LIKE 'FX26%'),
       'sf', (SELECT count(*) FROM public.spot_fill_v3 WHERE note LIKE 'FX26%'),
       'po', (SELECT count(*) FROM public.purchase_orders
               WHERE po_id IN (COALESCE(v_po1,'-'), COALESCE(v_po3,'-'), COALESCE(v_po4,'-'))),
       'pe', (SELECT count(*) FROM public.procurement_events
               WHERE po_id IN (COALESCE(v_po1,'-'), COALESCE(v_po3,'-'), COALESCE(v_po4,'-'))),
       'ie', (SELECT count(*) FROM public.inventory_events
               WHERE source_ref LIKE 'spot_fill:%' OR source_ref LIKE 'spot_fill_recv:%'),
       'sc', (SELECT count(*) FROM public.shelf_composition
               WHERE shelf_id IN (c_shelf, c_sh2, c_sh3, c_sh4, c_sh5, c_sh6)),
       'wh', (SELECT count(*) FROM public.warehouse_inventory WHERE wh_location = 'FX26'),
       'bvl',(SELECT count(*) FROM public.bypass_violation_log) - v_bvl_before));
END
$fx26$;
$fx26body$,
  'One subtransaction, rolled back by RAISE FX26_ROLLBACK; assertions read golden.scratch written from plpgsql variables that survive the unwind. Leaves ZERO rows in refill_dispatching, purchase_orders, spot_fill_v3, procurement_events, inventory_events and shelf_composition. Burns THREE po_numbers per run (po_number_seq is non-transactional) because a field_staff caller always MINTS - S-145, and that is the property that stops this fixture receiving a real open Carrefour PO. ~2-4 s.',
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

DELETE FROM golden.assertions WHERE fixture_id = 26;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
SELECT 26, t.seq, t.descr, t.sql, t.op, t.expect, true, 'P4'
FROM (VALUES

-- A. shape and ACL: the objects exist as Cody approved them ------------------
(1,'exactly ONE overload of receive_dispatch_line_sourced_v3 - a second would be a silent fork of the driver path',
 $q$SELECT count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='receive_dispatch_line_sourced_v3'$q$,'eq','1'),
(2,'exactly ONE overload of receive_spot_fill_po_v3',
 $q$SELECT count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='receive_spot_fill_po_v3'$q$,'eq','1'),
(3,'⛔ the WHOLE proacl string on phase 1 (S-140/S-178). Supabase arms every new public object at birth and a GRANT does not reduce an existing ACL - anon must not appear, and all three legitimate grants must survive.',
 $q$SELECT proacl::text FROM pg_proc WHERE oid='public.receive_dispatch_line_sourced_v3(uuid,numeric,numeric,uuid,jsonb,numeric,text,text,uuid,boolean)'::regprocedure$q$,'eq',
 '{postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}'),
(4,'⛔ the WHOLE proacl string on phase 2',
 $q$SELECT proacl::text FROM pg_proc WHERE oid='public.receive_spot_fill_po_v3(text,jsonb,uuid,boolean)'::regprocedure$q$,'eq',
 '{postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}'),
(5,'⭐ the internal helper is NOT executable by authenticated - _resolve_open_walkin_po_v3 mints POs and is reached as definer only',
 $q$SELECT proacl::text FROM pg_proc WHERE oid='public._resolve_open_walkin_po_v3(uuid,jsonb,text)'::regprocedure$q$,'eq',
 '{postgres=X/postgres,service_role=X/postgres}'),
(6,'phase 1 is SECURITY DEFINER with search_path pinned (Article 4)',
 $q$SELECT (prosecdef::text||'|'||COALESCE(array_to_string(proconfig,','),'<none>')) FROM pg_proc WHERE oid='public.receive_dispatch_line_sourced_v3(uuid,numeric,numeric,uuid,jsonb,numeric,text,text,uuid,boolean)'::regprocedure$q$,'eq','true|search_path=public, pg_temp'),
(7,'phase 2 is SECURITY DEFINER with search_path pinned',
 $q$SELECT (prosecdef::text||'|'||COALESCE(array_to_string(proconfig,','),'<none>')) FROM pg_proc WHERE oid='public.receive_spot_fill_po_v3(text,jsonb,uuid,boolean)'::regprocedure$q$,'eq','true|search_path=public, pg_temp'),
(8,'⛔ spot_fill_received_pair EXISTS and is non-vacuous: status is NOT NULL so the predicate can never evaluate to NULL, which is the shape trap S-177 punished (a CHECK that evaluates NULL ACCEPTS the row)',
 $q$SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname='spot_fill_received_pair'$q$,'contains','received_at IS NOT NULL'),
(9,'spot_fill_v3.status is CHECK-constrained to exactly pending/received/void - Article 7 cancellation is a void status, never a DELETE',
 $q$SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname='spot_fill_status_enum'$q$,'contains','void'),
(10,'qty is constrained positive - a zero-qty spot fill is a silent qty-0 (LAW 5)',
 $q$SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname='spot_fill_qty_positive'$q$,'contains','qty > (0)'),
(11,'the dispatch FK exists, so a spot fill can never orphan from the line it filled',
 $q$SELECT count(*)::text FROM pg_constraint WHERE conname='spot_fill_v3_dispatch_id_fkey'$q$,'eq','1'),
(12,'⭐ expiry_date is NULLABLE by design - NULL-until-phase-2. ⛔ Never default it: 2099-12-31 is the P0.4 sentinel shape and would make spot goods immortal in FEFO.',
 $q$SELECT is_nullable FROM information_schema.columns WHERE table_name='spot_fill_v3' AND column_name='expiry_date'$q$,'eq','YES'),
(13,'⛔ receive_dispatch_line_sourced_v3 is in the enforce_canonical_dispatch_write allowlist. Without it the filled_quantity write would pass only on receive_dispatch_line''s LEAKED GUC - a guard satisfied under another writer''s identity (S-160 family).',
 $q$SELECT (prosrc LIKE '%receive_dispatch_line_sourced_v3%')::text FROM pg_proc WHERE proname='enforce_canonical_dispatch_write'$q$,'eq','true'),
(14,'⛔ the incumbent receive_dispatch_line is BYTE-FOR-BYTE UNCHANGED (md5 28195f57). The whole design rests on composing it, not editing it - Cody condition 1 is void the moment this moves.',
 $q$SELECT left(md5(prosrc),8) FROM pg_proc WHERE proname='receive_dispatch_line'$q$,'eq','28195f57'),

-- B. THE CONTROL: the old path still refuses the incident's exact call -------
(15,'⛔ THE CONTROL, AND THE REASON THIS FIXTURE MEANS ANYTHING. receive_dispatch_line(d, 9) on the SAME shape STILL RAISES. The 07-30 guard was correct and it survives untouched; the fix was to stop asking it about units that were never its business.',
 $q$SELECT (value->>'err') FROM golden.scratch WHERE fixture_id=26 AND key='control'$q$,'contains','cannot be debited'),
(16,'...and it refuses for the RIGHT REASON - an overfill the warehouse cannot cover, named as such',
 $q$SELECT (value->>'err') FROM golden.scratch WHERE fixture_id=26 AND key='control'$q$,'contains','Refusing to silently debit'),
(17,'the refused line is left UNRECEIVED - a guard that raises but half-commits is worse than no guard',
 $q$SELECT (value->>'line_untouched') FROM golden.scratch WHERE fixture_id=26 AND key='control'$q$,'eq','true'),
(18,'⭐ and the refusal moved NO warehouse stock at all',
 $q$SELECT (value->>'batch_untouched') FROM golden.scratch WHERE fixture_id=26 AND key='control'$q$,'eq','true'),

-- C. the happy path: the driver is no longer stranded ------------------------
(19,'the new path succeeds on the shape the old one refuses',
 $q$SELECT (value->>'ok') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','true'),
(20,'the line reads filled = 9, which is what the driver actually put in the machine',
 $q$SELECT (value->>'rd_filled') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','9'),
(21,'the split is recorded explicitly as 1 from the warehouse...',
 $q$SELECT (value->>'qty_from_wh') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','1'),
(22,'...and 8 spot-bought. ⭐ Neither is derived from the other - a single filled_quantity that exceeds plan is exactly the ambiguity that stranded the driver.',
 $q$SELECT (value->>'qty_spot') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','8'),
(23,'⛔ THE PHANTOM-MINT ASSERTION, PART 1. The warehouse batch delta is ZERO on this leg - and zero is the CORRECT number, not a vacuous one: receive_dispatch_line debits only the OVERFILL, and n equals the planned 1, so the planned unit had already left at pack time. Had the implementation passed n+m=9, overfill would be 8, the batch would be short and this leg would have RAISED like the control.',
 $q$SELECT (value->>'batch_delta') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','0'),
(24,'the 8 spot units are ON THE SHELF immediately - composition, not a promise',
 $q$SELECT (value->>'comp_total') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','8'),
(25,'⭐ ...and they sit in the NULL expiry bucket, because no receipt has been read yet. This is the bucket phase 2 moves them OUT of.',
 $q$SELECT (value->>'comp_null') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','8'),
(26,'⭐ the composition move is an EVENT of kind spot_buy_receive. Without it cron 44''s estimator would read the count rise as a venue_fill or flag it as an anomaly (the fixture-19 path).',
 $q$SELECT (value->>'ie_kind') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','spot_buy_receive'),
(27,'the event carries +8, matching the units that physically arrived',
 $q$SELECT (value->>'ie_delta') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','8'),
(28,'exactly one spot_fill row for a pod-level record',
 $q$SELECT (value->>'sf_n') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','1'),
(29,'...carrying all 8 units',
 $q$SELECT (value->>'sf_qty') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','8'),
(30,'⭐ sku_resolved is FALSE and the row sits on the line''s own product. The 07-30 driver said "8 zigi" and never enumerated flavours - ⛔ an invented flavour split is worse than an honest pod-level record.',
 $q$SELECT (value->>'sf_sku_res') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','false'),
(31,'the pod-level row is booked against the dispatch line''s own product',
 $q$SELECT (value->>'sf_is_line_prod') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','true'),
(32,'the spot fill is PENDING - physically on the shelf, financially open',
 $q$SELECT (value->>'sf_status') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','pending'),
(33,'⛔ ...with a NULL expiry until a receipt supplies one. spot_fill_received_pair makes it impossible to reach ''received'' while this is still NULL.',
 $q$SELECT (value->>'sf_expiry_null') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','true'),
(34,'⛔ S-145: a field_staff caller always MINTS, never attaches - add_purchase_order_lines is owner-only. That is the property stopping this fixture from receiving a REAL open Carrefour PO that procurement has open today.',
 $q$SELECT (value->>'po_path') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','minted'),
(35,'a PO line was raised for the 8 spot units - the money side is never dropped on the floor (LAW 5)',
 $q$SELECT (value->>'po_ordered') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','8'),
(36,'⭐ ...and it is UNRECEIVED. This is Cody''s recorded condition made visible: P4.4b creates the first stock in this system''s history that is on a shelf while financially unreceived. ⛔ Do not let a later leg "fix" that gap by back-dating a warehouse receipt - it closes on its own at phase 2.',
 $q$SELECT (value->>'po_unreceived') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','true'),
(37,'phase 1 says out loud that phase 2 is still owed',
 $q$SELECT (value->>'phase_2_pending') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','true'),
(38,'the phase-1 procurement event is written exactly once',
 $q$SELECT (value->>'pe_phase1') FROM golden.scratch WHERE fixture_id=26 AND key='happy'$q$,'eq','1'),

-- D. the exact-n leg: a warehouse delta that can actually move ---------------
(39,'⛔ THE PHANTOM-MINT ASSERTION, PART 2 - the one that can move. On a leg where n=2 EXCEEDS the planned 1, the warehouse is debited by exactly 1 (the n-side overfill) and never by 4 (n+m). This is the assertion that would go red if anyone ever "simplified" phase 1 to hand the incumbent the full filled quantity.',
 $q$SELECT (value->>'batch_delta') FROM golden.scratch WHERE fixture_id=26 AND key='split'$q$,'eq','-1'),
(40,'the incumbent itself reports an overfill of 1, computed from n alone',
 $q$SELECT (value->>'wh_overfill') FROM golden.scratch WHERE fixture_id=26 AND key='split'$q$,'eq','1'),
(41,'the line still reads the full 5 the driver put in',
 $q$SELECT (value->>'filled') FROM golden.scratch WHERE fixture_id=26 AND key='split'$q$,'eq','5'),

-- E. the enumerated-flavour path --------------------------------------------
(42,'a supplied breakdown produces one row per SKU...',
 $q$SELECT (value->>'rows') FROM golden.scratch WHERE fixture_id=26 AND key='bd'$q$,'eq','2'),
(43,'...across two distinct products...',
 $q$SELECT (value->>'products') FROM golden.scratch WHERE fixture_id=26 AND key='bd'$q$,'eq','2'),
(44,'...summing to exactly m, because the split must account for every spot unit',
 $q$SELECT (value->>'sum') FROM golden.scratch WHERE fixture_id=26 AND key='bd'$q$,'eq','4'),
(45,'...and every row is marked sku_resolved',
 $q$SELECT (value->>'all_resolved') FROM golden.scratch WHERE fixture_id=26 AND key='bd'$q$,'eq','true'),

-- F. phase 2, and the double-add that must never happen ---------------------
(46,'phase 2 receives the line',
 $q$SELECT (value->>'a_received') FROM golden.scratch WHERE fixture_id=26 AND key='p2'$q$,'eq','1'),
(47,'⛔ D-E, PINNED. Phase 2 creates ZERO warehouse_inventory rows. The incumbent receive_purchase_order inserts a batch at exactly this point; this function deliberately does not, because the goods are on a shelf and never entered a warehouse. ⛔ A later leg that "repairs" the missing batch resurrects the netting design Article 6 rejected.',
 $q$SELECT (value->>'wh_rows_created') FROM golden.scratch WHERE fixture_id=26 AND key='p2'$q$,'eq','0'),
(48,'⭐ ...asserted independently from the RPC''s own claim, so the payload cannot mark its own homework',
 $q$SELECT (value->>'a_wh_rows') FROM golden.scratch WHERE fixture_id=26 AND key='p2'$q$,'eq','0'),
(49,'the units MOVED OUT of the NULL expiry bucket...',
 $q$SELECT (value->'comp_a'->>'null_bucket') FROM golden.scratch WHERE fixture_id=26 AND key='p2'$q$,'eq','0'),
(50,'...and INTO the receipt''s expiry bucket, so FEFO and the expiry engine now see a real date',
 $q$SELECT (value->'comp_a'->>'exp_bucket') FROM golden.scratch WHERE fixture_id=26 AND key='p2'$q$,'eq','8'),
(51,'⛔ THE HIGHEST-RISK DEFECT IN THE UNIT, PINNED: the shelf total is UNCHANGED at 8. Phase 2 is a RE-BUCKET (-8 out, +8 in, net zero), never an add - phase 1 already put these units on the shelf.',
 $q$SELECT (value->'comp_a'->>'total') FROM golden.scratch WHERE fixture_id=26 AND key='p2'$q$,'eq','8'),
(52,'⛔ AND RUNNING PHASE 2 A SECOND TIME CHANGES COMPOSITION NOT AT ALL. This is the difference between the feature and a stock-inflation bug.',
 $q$SELECT (value->>'comp_identical') FROM golden.scratch WHERE fixture_id=26 AND key='p2'$q$,'eq','true'),
(53,'⭐ the re-run is SKIPPED, not RAISED - a retry after a partial failure is an ordinary operator action, not an error',
 $q$SELECT (value->>'b_skipped') FROM golden.scratch WHERE fixture_id=26 AND key='p2'$q$,'eq','1'),
(54,'...and it says why',
 $q$SELECT (value->>'b_skip_reason') FROM golden.scratch WHERE fixture_id=26 AND key='p2'$q$,'eq','already_received'),
(55,'the second run receives nothing',
 $q$SELECT (value->>'b_received') FROM golden.scratch WHERE fixture_id=26 AND key='p2'$q$,'eq','0'),
(56,'⛔ ...and writes NO second procurement event. A pure re-run stamps nothing and therefore logs nothing.',
 $q$SELECT (value->>'pe_received') FROM golden.scratch WHERE fixture_id=26 AND key='p2'$q$,'eq','1'),
(57,'the PO line is now received...',
 $q$SELECT (value->>'po_outcome') FROM golden.scratch WHERE fixture_id=26 AND key='p2'$q$,'eq','received'),
(58,'...for the 8 units actually bought, once and not twice',
 $q$SELECT (value->>'po_recv_qty') FROM golden.scratch WHERE fixture_id=26 AND key='p2'$q$,'eq','8'),
(59,'the spot fill closes as received',
 $q$SELECT (value->>'sf_status') FROM golden.scratch WHERE fixture_id=26 AND key='p2'$q$,'eq','received'),
(60,'⭐ ...carrying the receipt expiry, which is the whole point of phase 2 - the financial close is what gives the shelf a real date',
 $q$SELECT (value->>'sf_expiry') FROM golden.scratch WHERE fixture_id=26 AND key='p2'$q$,'not_null',''),

-- G. every refusal, proven to fire (S-126: a guard that never fires is not a guard)
(61,'spot units with no supplier named are REFUSED, with a message naming the missing field. ⛔ LAW 5 / Cody condition 5: it must never fall back to recording only n and dropping m on the floor - that loses 8 real units silently.',
 $q$SELECT (value->>'no_supplier') FROM golden.scratch WHERE fixture_id=26 AND key='refusals'$q$,'contains','p_spot_supplier_id is REQUIRED'),
(62,'an Inactive supplier is refused',
 $q$SELECT (value->>'sup_inactive') FROM golden.scratch WHERE fixture_id=26 AND key='refusals'$q$,'contains','Active required'),
(63,'a supplier_delivered supplier is refused - a counter purchase is walk_in by definition',
 $q$SELECT (value->>'sup_not_walkin') FROM golden.scratch WHERE fixture_id=26 AND key='refusals'$q$,'contains','walk_in by definition'),
(64,'n + m = 0 is refused rather than silently recorded as a zero fill (LAW 5)',
 $q$SELECT (value->>'nothing') FROM golden.scratch WHERE fixture_id=26 AND key='refusals'$q$,'contains','nothing to record'),
(65,'a negative quantity is refused',
 $q$SELECT (value->>'negative') FROM golden.scratch WHERE fixture_id=26 AND key='refusals'$q$,'contains','cannot be negative'),
(66,'⭐ a breakdown that does not sum to m is refused - a split that loses units is the same class of harm as no split at all',
 $q$SELECT (value->>'breakdown_mismatch') FROM golden.scratch WHERE fixture_id=26 AND key='refusals'$q$,'contains','account for every spot unit'),
(67,'a spot fill on a Remove leg is refused - those units came off a shelf, not from a counter',
 $q$SELECT (value->>'remove_leg') FROM golden.scratch WHERE fixture_id=26 AND key='refusals'$q$,'contains','only valid on a Refill/Add New/Add leg'),
(68,'⛔ S-177, PROVEN BY ATTEMPT AND NOT BY READING THE PREDICATE: forcing status=received with a NULL expiry is REFUSED by spot_fill_received_pair. This is the exact hole through which undated stock would otherwise reach a shelf.',
 $q$SELECT (value->>'received_null_expiry') FROM golden.scratch WHERE fixture_id=26 AND key='refusals'$q$,'contains','spot_fill_received_pair'),
(69,'⭐ phase 2 refuses field_staff. The driver who filled the machine cannot also close the money side - phase 1 is field_staff+, phase 2 is warehouse+, and the separation is deliberate.',
 $q$SELECT (value->>'p2_field_staff') FROM golden.scratch WHERE fixture_id=26 AND key='refusals'$q$,'contains','warehouse+ only'),
(70,'phase 2 refuses a receipt with no expiry, naming the field rather than leaking a bare CHECK failure (BUG-007/009)',
 $q$SELECT (value->>'p2_null_expiry') FROM golden.scratch WHERE fixture_id=26 AND key='refusals'$q$,'contains','expiry_date is required'),
(71,'⛔ P0.4: phase 2 refuses 2099-12-31 outright. It is the sentinel shape, and accepting it would make spot goods immortal in FEFO.',
 $q$SELECT (value->>'p2_sentinel') FROM golden.scratch WHERE fixture_id=26 AND key='refusals'$q$,'contains','sentinel'),

-- H. the dry run, and Article 4 ---------------------------------------------
(72,'a dry run reports committed=false rather than implying success',
 $q$SELECT (value->>'committed') FROM golden.scratch WHERE fixture_id=26 AND key='dry'$q$,'eq','false'),
(73,'⭐ S-133 is stated in the payload: a rolled-back dry run does NOT check DEFERRED constraints, so it must not be read as full validation',
 $q$SELECT (value->>'deferred') FROM golden.scratch WHERE fixture_id=26 AND key='dry'$q$,'eq','true'),
(74,'a dry run creates NO spot_fill rows',
 $q$SELECT (value->>'sf_rows') FROM golden.scratch WHERE fixture_id=26 AND key='dry'$q$,'eq','0'),
(75,'⛔ ...and does NOT receive the dispatch line. A dry run that consumed the line would strand the driver a second time.',
 $q$SELECT (value->>'rd_touched') FROM golden.scratch WHERE fixture_id=26 AND key='dry'$q$,'eq','false'),
(76,'⛔ Article 4 / Cody condition 3: app.via_rpc is RESTORED after the RPCs return. These GUCs leak across statements in this codebase (PRD-016B); a leaked via_rpc would make the next unrelated write look like an RPC.',
 $q$SELECT (value->>'via_rpc') FROM golden.scratch WHERE fixture_id=26 AND key='gucs'$q$,'eq',''),
(77,'⭐ app.rpc_name is restored to the CALLER''s value, not merely cleared - the harness set golden.fixture_26 before the calls and it is still that afterwards. record_inventory_event_v3 clobbers this GUC and does not restore it, so a blanket reset would look identical on an empty inbound value; the harness sets one precisely so this can tell the difference.',
 $q$SELECT (value->>'rpc_name') FROM golden.scratch WHERE fixture_id=26 AND key='gucs'$q$,'eq','golden.fixture_26'),
(78,'app.provenance_reason is restored too, so the next protected write names its own provenance',
 $q$SELECT (value->>'prov') FROM golden.scratch WHERE fixture_id=26 AND key='gucs'$q$,'eq',''),

-- I. residue: LAW 12 and S-124 ----------------------------------------------
(79,'⛔ ZERO refill_dispatching residue on the 2030 plan date (LAW 12 / S-124: fixture residue has landed on this exact protected table before)',
 $q$SELECT (value->>'rd') FROM golden.scratch WHERE fixture_id=26 AND key='residue'$q$,'eq','0'),
(80,'ZERO spot_fill_v3 residue',
 $q$SELECT (value->>'sf') FROM golden.scratch WHERE fixture_id=26 AND key='residue'$q$,'eq','0'),
(81,'⛔ ZERO purchase_orders residue - a surviving spot PO would sit in procurement''s board as a real unpaid obligation',
 $q$SELECT (value->>'po') FROM golden.scratch WHERE fixture_id=26 AND key='residue'$q$,'eq','0'),
(82,'ZERO procurement_events residue',
 $q$SELECT (value->>'pe') FROM golden.scratch WHERE fixture_id=26 AND key='residue'$q$,'eq','0'),
(83,'⛔ ZERO inventory_events residue - a surviving spot_buy_receive event would be read by cron 44''s estimator as real stock arriving on a real shelf',
 $q$SELECT (value->>'ie') FROM golden.scratch WHERE fixture_id=26 AND key='residue'$q$,'eq','0'),
(84,'⛔ ZERO shelf_composition residue on the target shelf - phantom units on a live shelf would be sized against by the next plan',
 $q$SELECT (value->>'sc') FROM golden.scratch WHERE fixture_id=26 AND key='residue'$q$,'eq','0'),
(85,'⭐ and the proof is independent of the scenario''s own bookkeeping: no FX26-marked dispatch row exists on the 2030 date right now, read live at assertion time',
 $q$SELECT count(*)::text FROM public.refill_dispatching WHERE dispatch_date=DATE '2030-08-04' AND comment LIKE 'FX26%'$q$,'eq','0'),
(86,'⭐ likewise no spot_fill row survives anywhere in the table from this fixture, read live',
 $q$SELECT count(*)::text FROM public.spot_fill_v3 WHERE note LIKE 'FX26%'$q$,'eq','0'),
(87,'⛔ ZERO warehouse_inventory residue. This fixture PLANTS a batch (the 2030 date makes every real batch expired to FEFO), so it is the one that could leave phantom warehouse stock behind - and phantom WH stock is pickable by the live FEFO binder within minutes.',
 $q$SELECT (value->>'wh') FROM golden.scratch WHERE fixture_id=26 AND key='residue'$q$,'eq','0'),
(88,'⭐ ...and again read LIVE at assertion time, independent of the scenario''s own bookkeeping',
 $q$SELECT count(*)::text FROM public.warehouse_inventory WHERE wh_location='FX26'$q$,'eq','0'),
(89,'⛔ ZERO bypass_violation_log rows minted. enforce_canonical_dispatch_write LOGS rather than blocks, so a plant that forgot app.via_trigger would quietly accumulate governance-table residue that no other assertion here would ever catch.',
 $q$SELECT (value->>'bvl') FROM golden.scratch WHERE fixture_id=26 AND key='residue'$q$,'eq','0')

) AS t(seq, descr, sql, op, expect);
