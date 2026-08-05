-- PRD-110 · S-245 (NEW, leg 132) — S5 WAS A ONE-SHOT. ITS OWN RESIDUE DEFEATS TWO OF ITS OWN
-- PRECONDITIONS ON THE SECOND RUN. Measured, not reasoned, while re-running S5 to prove D-46.
--
-- BREAK 1 — seq 7 (`FEFO prefers Y`). The plant hard-codes Y's expiry as the constant 2031-01-31.
--   The previous run's Y is STILL Active, still carries 1 unit, is still fenced to the same
--   machine and still carries expiry 2031-01-31. It therefore TIES the fresh Y on the primary
--   sort key AND on the `warehouse_stock DESC` tie-break, and the winner is whichever row the
--   planner happens to emit first. Observed live: `fefo_first` came back as
--   `S5-20260804053504-Y` (the leg-125 residue), not the fresh plant. A tie broken by luck is
--   not a precondition.
--
-- BREAK 3 — the plant cannot even RE-PLANT. `prevent_duplicate_unstarted_dispatch` refuses a
--   second UNSTARTED row on the same (machine, shelf, product, action, date) key. Leg 125's rows
--   were packed, so they never blocked; an ABORTED setup leaves unstarted rows, and they block
--   outright with P0001. Retire them the canonical way — skip_dispatch_line — never DELETE.
--
-- BREAK 2 — seq 26 (`no child dispatch rows minted`). It counts EVERY dispatch row on the
--   suite's date + machine other than the two the run planted, and asserts 0. The previous run's
--   two rows are permanent (2030-11-05 is a consumed synthetic date), so the count is 2 before
--   the suite even starts. The assertion was measuring residue, not child rows.
--
-- ⛔ NEITHER BREAK IS A D-46 REGRESSION and neither was visible at leg 125 — a suite that has
--    only ever run once cannot fail this way. The banked S5 green from leg 125 stands; what it
--    did not prove is that it could be re-run, and STEP 7's S7 doctrine (identical results across
--    rounds) is worthless for any suite that is single-shot by construction.
--
-- THE FIX — the leg-114/115 idiom: the plant SELF-SUPPLIES its precondition instead of asserting
-- a constant and hoping.
--   (1) Y's expiry is DERIVED as one day before the earliest currently-pickable batch of the same
--       product at the same warehouse. Strictly earlier than every competitor ⇒ no tie is
--       possible ⇒ FEFO must choose it. Monotonic: each run's Y lands one day earlier than the
--       last, so this stays true for every future run without further edits.
--   (2) The plant BANKS the pre-existing child-row count (`pre_children`) and seq 26 asserts the
--       count is UNCHANGED rather than zero. That is the property the tripwire was always after —
--       "this run minted no child rows" — stated so that prior runs cannot forge it either way.
--
-- Two guards make the derivation refuse rather than silently produce a useless plant: Y must be
-- strictly before X (or FEFO would prefer X and wave 2 tests nothing), and Y must still be in the
-- future (or the batch is not pickable at all and the plant is vacuous).
--
-- Article 12: forward-only CREATE OR REPLACE on two golden-harness functions.
-- Article 1/6: the plant still only ever INSERTs a NEW Active batch (the named harness exemption,
-- Cody leg 125). It never UPDATEs `status` and it does not touch any pre-existing row.

CREATE OR REPLACE FUNCTION golden.stress_s5_setup_v1(p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'golden', 'pg_temp'
AS $function$
DECLARE
  c_machine   uuid := 'a6c02486-5d95-42ca-9adc-bc755c3019d3';  -- WH1-2002-0000-W0, Inactive
  c_mname     text := 'WH1-2002-0000-W0';
  c_date      date := '2030-11-05';
  c_shelf_a   uuid := '94c292a6-7259-4107-b548-9df03a6be70c';  -- A01, wave 2 (bind race)
  c_shelf_b   uuid := 'bc7028b9-0bc8-4b1b-bdd4-d7c1e302ddc5';  -- A02, wave 1 (pack vs pack)
  c_prod_p    uuid := '84910b35-a37b-42ab-90f1-0d75bdb6d937';  -- wave 2 product
  c_prod_q    uuid := '67d6061e-55be-4e1f-8668-07f96a8d63a2';  -- wave 1 product
  c_wh        uuid := public.wh_central_id()::uuid;
  c_exp_x     date := '2031-06-30';                            -- X: the batch pack picks
  c_exp_z     date := '2031-12-31';                            -- Z: wave-1 product
  v_exp_y     date;                                            -- S-245: DERIVED, never constant
  v_tag       text := 'S5-' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDDHH24MISS');
  v_min       int  := extract(minute FROM now() AT TIME ZONE 'UTC')::int;
  v_x uuid; v_y uuid; v_z uuid;
  v_l_bind uuid; v_l_pack uuid;
  v_stale uuid; v_retired int := 0;
BEGIN
  -- S-223: cron 44 rewrites shelf_composition at :40 and an external suite spans minutes across
  -- several transactions. Refuse to start inside the window rather than race the cron.
  IF v_min BETWEEN 36 AND 48 THEN
    RAISE EXCEPTION 'stress_s5_setup_v1: refusing to start at :% UTC (cron-44 window :36-:48, S-223)', v_min;
  END IF;

  -- ---- S-245 (break 3): RETIRE ANY ABANDONED PLANT ROW BEFORE PLANTING.
  -- An aborted or abandoned setup leaves UNSTARTED rows on this suite's own key, and
  -- prevent_duplicate_unstarted_dispatch then refuses the next plant outright (P0001). Skipping
  -- is the honest semantic — an abandoned plant row will never be executed — and skip_dispatch_line
  -- is its canonical writer (Article 1). ⛔ NEVER DELETE: these are refill_dispatching rows.
  FOR v_stale IN
    SELECT rd.dispatch_id FROM public.refill_dispatching rd
     WHERE rd.machine_id = c_machine
       AND rd.dispatch_date = c_date
       AND rd.shelf_id IN (c_shelf_a, c_shelf_b)
       AND rd.action = 'Refill'
       AND rd.include = true
       AND COALESCE(rd.filled_quantity,0) = 0
       AND COALESCE(rd.packed,false)      = false
       AND COALESCE(rd.item_added,false)  = false
       AND COALESCE(rd.returned,false)    = false
       AND COALESCE(rd.skipped,false)     = false
       AND COALESCE(rd.cancelled,false)   = false
  LOOP
    PERFORM public.skip_dispatch_line(
      v_stale,
      'S5 harness: retiring an abandoned plant row from an aborted or previous run (PRD-110 S-245)');
    v_retired := v_retired + 1;
  END LOOP;

  -- ⛔ S-197: skip_dispatch_line leaves app.via_rpc='true' and an ALLOWLISTED app.rpc_name in the
  -- GUC, which would satisfy the canonical-writer gate for the REST of this transaction and give
  -- the plant below a free pass it must not have. Clear both before planting anything.
  PERFORM set_config('app.via_rpc','', true);
  PERFORM set_config('app.rpc_name','', true);

  -- ---- S-245: SELF-SUPPLY THE FEFO PRECONDITION.
  -- Y must be strictly the earliest pickable batch of c_prod_p at c_wh, or seq 7 is decided by a
  -- planner tie-break against this suite's own residue. One day before the current earliest
  -- competitor is strictly earlier than all of them, by construction.
  SELECT COALESCE(min(p.expiration_date), c_exp_x - 150) - 1
    INTO v_exp_y
  FROM public.v_wh_pickable p
  WHERE p.boonz_product_id = c_prod_p
    AND p.warehouse_id     = c_wh
    AND (p.reserved_for_machine_id IS NULL OR p.reserved_for_machine_id = c_machine)
    AND COALESCE(p.warehouse_stock,0) > 0;

  IF v_exp_y >= c_exp_x THEN
    RAISE EXCEPTION 'stress_s5_setup_v1: derived Y expiry % is not strictly before X (%) — wave 2 would test nothing', v_exp_y, c_exp_x;
  END IF;
  IF v_exp_y <= CURRENT_DATE THEN
    RAISE EXCEPTION 'stress_s5_setup_v1: derived Y expiry % is not in the future — the batch would not be pickable and the plant would be vacuous', v_exp_y;
  END IF;

  -- ---- warehouse plant. S-189: provenance_reason='snapshot' or the batch is quarantined
  -- (GENERATED column) and therefore invisible to v_wh_pickable, which fails with the SAME
  -- "short by N" message as having no stock at all.
  -- Y carries the EARLIEST expiry so FEFO prefers it: that is what makes wave 2's re-bind
  -- land on a batch that pack never picked from.
  --
  -- ARTICLE 6 (Cody, leg 124): this only ever INSERTs a NEW Active batch. It never UPDATEs
  -- `status` on an existing row — that is the transition Article 6 reserves to the warehouse
  -- manager. Same shape and same justification as create_spot_purchase_v3 and fixtures 9 / 26.
  --
  -- ⛔ The GUCs are load-bearing, not decoration: trg_set_wh_provenance derives provenance from
  -- app.provenance_reason and can override a bare column literal, and trg_detect_silent_warehouse_write
  -- flags a plant that arrives with neither GUC set. Fixtures 9 and 26 both set and clear both.
  --
  -- ⭐ Sized to NEED, not convenience: this plant PERSISTS (S5 cannot be a rollback probe), so
  -- every unit sits in real warehouse_inventory totals for good. X and Z are one unit above what
  -- their pack consumes, which also keeps tg_propose_inactivate_on_zero_stock from firing and
  -- minting proposal rows as an uncounted side effect.
  PERFORM set_config('app.via_trigger','true', true);
  PERFORM set_config('app.provenance_reason','snapshot', true);

  INSERT INTO public.warehouse_inventory
    (boonz_product_id, warehouse_id, snapshot_date, warehouse_stock, consumer_stock,
     expiration_date, status, provenance_reason, reserved_for_machine_id, batch_id, wh_location)
  VALUES (c_prod_p, c_wh, CURRENT_DATE, 6, 0, c_exp_x, 'Active', 'snapshot', c_machine, v_tag||'-X', 'S5')
  RETURNING wh_inventory_id INTO v_x;

  INSERT INTO public.warehouse_inventory
    (boonz_product_id, warehouse_id, snapshot_date, warehouse_stock, consumer_stock,
     expiration_date, status, provenance_reason, reserved_for_machine_id, batch_id, wh_location)
  VALUES (c_prod_p, c_wh, CURRENT_DATE, 1, 0, v_exp_y, 'Active', 'snapshot', c_machine, v_tag||'-Y', 'S5')
  RETURNING wh_inventory_id INTO v_y;

  INSERT INTO public.warehouse_inventory
    (boonz_product_id, warehouse_id, snapshot_date, warehouse_stock, consumer_stock,
     expiration_date, status, provenance_reason, reserved_for_machine_id, batch_id, wh_location)
  VALUES (c_prod_q, c_wh, CURRENT_DATE, 5, 0, c_exp_z, 'Active', 'snapshot', c_machine, v_tag||'-Z', 'S5')
  RETURNING wh_inventory_id INTO v_z;

  PERFORM set_config('app.provenance_reason','', true);

  -- ---- dispatch plant. S-197: via_trigger only, never via_rpc (an allowlisted rpc_name left in
  -- the GUC would satisfy the canonical-writer gate for the REST of the transaction).

  INSERT INTO public.refill_dispatching
    (machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity,
     include, packed, picked_up, dispatched, returned, item_added, cancelled, is_m2m, from_warehouse_id)
  VALUES (c_machine, c_shelf_a, c_prod_p, c_date, 'Refill', 5,
          true, false, false, false, false, false, false, false, c_wh)
  RETURNING dispatch_id INTO v_l_bind;

  INSERT INTO public.refill_dispatching
    (machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity,
     include, packed, picked_up, dispatched, returned, item_added, cancelled, is_m2m, from_warehouse_id)
  VALUES (c_machine, c_shelf_b, c_prod_q, c_date, 'Refill', 4,
          true, false, false, false, false, false, false, false, c_wh)
  RETURNING dispatch_id INTO v_l_pack;

  -- Clear it the moment the plant ends, per the standing plant rule.
  PERFORM set_config('app.via_trigger','', true);

  RETURN jsonb_build_object(
    'run_tag',      v_tag,
    'note',         p_note,
    'machine_id',   c_machine,
    'machine_name', c_mname,
    'plan_date',    c_date,
    'l_bind',       v_l_bind,
    'l_pack',       v_l_pack,
    'qty_bind',     5,
    'qty_pack',     4,
    'batch_x',      v_x,
    'batch_y',      v_y,
    'batch_z',      v_z,
    'exp_y',        v_exp_y,
    'retired_stale_plant_rows', v_retired,
    -- S-235: bank everything. Strict equality later, never `>=`.
    'bank', jsonb_build_object(
      'x_wh', 6, 'x_cs', 0, 'y_wh', 1, 'y_cs', 0, 'z_wh', 5, 'z_cs', 0,
      'live_pod_refills',      (SELECT count(*) FROM public.pod_refills),
      'live_pod_refill_plan',  (SELECT count(*) FROM public.pod_refill_plan),
      'live_rpo',              (SELECT count(*) FROM public.refill_plan_output),
      'disp_total',            (SELECT count(*) FROM public.refill_dispatching),
      -- ⭐ S-245: the residue this run INHERITED. seq 26 asserts this number is unchanged at the
      -- end, i.e. THIS run minted no child rows. Asserting a bare 0 measured prior runs instead.
      'pre_children',          (SELECT count(*) FROM public.refill_dispatching
                                 WHERE dispatch_date = c_date AND machine_id = c_machine
                                   AND dispatch_id NOT IN (v_l_bind, v_l_pack))
    ),
    'setup_ok', jsonb_build_object(
      'bind_unpacked',  (SELECT NOT COALESCE(packed,false) FROM public.refill_dispatching WHERE dispatch_id=v_l_bind),
      'pack_unpacked',  (SELECT NOT COALESCE(packed,false) FROM public.refill_dispatching WHERE dispatch_id=v_l_pack),
      'bind_unbound',   (SELECT from_wh_inventory_id IS NULL FROM public.refill_dispatching WHERE dispatch_id=v_l_bind),
      'batches_pickable', (SELECT count(*) FROM public.v_wh_pickable WHERE wh_inventory_id IN (v_x,v_y,v_z)),
      'batches_fenced',   (SELECT count(*) FROM public.warehouse_inventory
                            WHERE wh_inventory_id IN (v_x,v_y,v_z) AND reserved_for_machine_id = c_machine),
      'batches_snapshot', (SELECT count(*) FROM public.warehouse_inventory
                            WHERE wh_inventory_id IN (v_x,v_y,v_z) AND provenance_reason='snapshot'
                              AND NOT COALESCE(quarantined,false)),
      'fefo_first',       (SELECT p.wh_inventory_id FROM public.v_wh_pickable p
                            WHERE p.boonz_product_id=c_prod_p AND p.warehouse_id=c_wh
                              AND (p.reserved_for_machine_id IS NULL OR p.reserved_for_machine_id=c_machine)
                              AND COALESCE(p.warehouse_stock,0) > 0
                            ORDER BY p.expiration_date ASC NULLS LAST, p.warehouse_stock DESC LIMIT 1)
    )
  );
END;
$function$;
