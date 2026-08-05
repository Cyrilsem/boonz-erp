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
-- BREAK 4 — seq 25's `bound = 0` is an AGGREGATE and any other bindable row on the suite's date
--   + machine contaminates it. Measured live: the two rows retired by BREAK 3's fix are skipped
--   but NOT cancelled, and bind_dispatch_fefo's `targets` filters `cancelled` but neither
--   `skipped` nor `include` — so the binder bound them and reported bound=2 while correctly
--   REFUSING the racing line. The D-46 property held; the instrument was wrong. seq 25 now
--   asserts the binder bound exactly the rows it was ENTITLED to bind (banked at plant time by
--   replaying the binder's own target+pick logic), so the racing line's exclusion is stated
--   exactly rather than inferred from a global zero.
--   ⏸️ That the binder binds skipped / include=false lines at all is parked as S-246 — it moves
--      no stock, so it is not a conservation break, and fixing it is not D-46's scope (LAW 10).
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
                                   AND dispatch_id NOT IN (v_l_bind, v_l_pack)),
      -- ⭐ S-245 (break 4): how many NON-RACING rows on this date+machine the binder is entitled
      -- to bind. This replays bind_dispatch_fefo's OWN targets+picks logic rather than guessing,
      -- so seq 25 can assert `bound == bindable_others` exactly. In a clean environment it is 0;
      -- with residue present it is the residue count, and the racing line is still excluded.
      'bindable_others',       (SELECT count(*) FROM (
                                  SELECT ( SELECT p.wh_inventory_id
                                             FROM public.v_wh_pickable p
                                            WHERE p.boonz_product_id = rd.boonz_product_id
                                              AND p.warehouse_id = COALESCE(rd.from_warehouse_id, c_wh)
                                              AND (p.reserved_for_machine_id IS NULL
                                                   OR p.reserved_for_machine_id = rd.machine_id)
                                              AND COALESCE(p.warehouse_stock,0) > 0
                                            ORDER BY p.expiration_date ASC NULLS LAST, p.warehouse_stock DESC
                                            LIMIT 1 ) AS pick
                                    FROM public.refill_dispatching rd
                                   WHERE rd.dispatch_date = c_date
                                     AND rd.machine_id    = c_machine
                                     AND rd.action IN ('Refill','Add','Add New')
                                     AND rd.from_wh_inventory_id IS NULL
                                     AND COALESCE(rd.item_added,false) = false
                                     AND COALESCE(rd.returned,false)   = false
                                     AND COALESCE(rd.cancelled,false)  = false
                                     AND COALESCE(rd.packed,false)     = false
                                     AND COALESCE(rd.is_m2m,false)     = false
                                     AND rd.dispatch_id NOT IN (v_l_bind, v_l_pack)
                                ) q WHERE q.pick IS NOT NULL)
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


-- PRD-110 · S-245 half 2 — seq 26 re-baselined to the banked pre_children.
-- Ships in the SAME migration as the setup change: the bank key and the assertion that reads it
-- must land together or the suite errors on a missing key.

-- PRD-110 · D-46 EXECUTE, half 2 — flip S5's three S-237 sensors from PINNING the defect to
-- ASSERTING the fix. This is the proof that 20260805231203 landed: the sensors were green
-- against the broken binder and are now green only against the fixed one.
--
-- S-103 obeyed: `expect` AND `description` are re-baselined TOGETHER. Never weakened to not_null.
--
-- WHAT CHANGES (three rows of a VALUES table, and two metric keys):
--   seq 23  Y  -> X   the packed line must still point at the batch pack debited
--   seq 24  ne X -> eq X   bound batch == debited batch; the conservation exposure is closed
--   seq 25  gte 1 -> eq 0  the binder must report it bound NOTHING
-- Everything else in this function is byte-identical: seq 1-22 and 26-29, the scoring CTE, the
-- banking INSERT shape, the return shape.
--
-- ⛔ seq 17 (the S-234 witness, bind blocked >= 1500 ms) is DELIBERATELY UNCHANGED and still
--    binds. The fixed binder still reaches the row, still blocks on the pack side's lock, and
--    only THEN fails the EvalPlanQual recheck and skips. If that wait ever disappears, the two
--    sides never raced and seq 23/24/25 would be green vacuously.
--
-- Article 12: forward-only CREATE OR REPLACE on a golden-harness measurement function.
-- Not a protected entity, no protected-entity write, no metric re-derivation.

-- ⛔ Header preserved EXACTLY as live (re-read from pg_proc, not from memory): SECURITY DEFINER and
--    SET search_path are NOT inherited by CREATE OR REPLACE — omitting them silently downgrades the
--    function to INVOKER with a default search_path.
CREATE OR REPLACE FUNCTION golden.stress_s5_verify_v1(p_setup jsonb, p_record boolean DEFAULT true, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'golden', 'pg_temp'
AS $function$
DECLARE
  v_tag    text := p_setup->>'run_tag';
  v_lbind  uuid := (p_setup->>'l_bind')::uuid;
  v_lpack  uuid := (p_setup->>'l_pack')::uuid;
  v_x      uuid := (p_setup->>'batch_x')::uuid;
  v_y      uuid := (p_setup->>'batch_y')::uuid;
  v_z      uuid := (p_setup->>'batch_z')::uuid;
  v_qb     numeric := (p_setup->>'qty_bind')::numeric;
  v_qp     numeric := (p_setup->>'qty_pack')::numeric;
  v_bank   jsonb := p_setup->'bank';
  v_su     jsonb := p_setup->'setup_ok';
  v_start  timestamptz := clock_timestamp();

  -- measured batch state
  x_wh numeric; x_cs numeric; y_wh numeric; y_cs numeric; z_wh numeric; z_cs numeric;
  -- measured dispatch state
  b_packed boolean; b_from uuid; b_filled numeric;
  p_packed boolean; p_from uuid; p_filled numeric;
  -- measured leg state
  w1_packed int; w1_err int; w1_errmsg text;
  w2_pack_status text; w2_bind_wait numeric; w2_bind_bound int; w2_pack_wait numeric;
  v_children int;
  -- live tripwire
  l_pr bigint; l_prp bigint; l_rpo bigint;
  v_pass int; v_fail int; v_detail jsonb; v_id uuid;
BEGIN
  SELECT warehouse_stock, consumer_stock INTO x_wh, x_cs FROM public.warehouse_inventory WHERE wh_inventory_id=v_x;
  SELECT warehouse_stock, consumer_stock INTO y_wh, y_cs FROM public.warehouse_inventory WHERE wh_inventory_id=v_y;
  SELECT warehouse_stock, consumer_stock INTO z_wh, z_cs FROM public.warehouse_inventory WHERE wh_inventory_id=v_z;

  SELECT COALESCE(packed,false), from_wh_inventory_id, COALESCE(filled_quantity,0)
    INTO b_packed, b_from, b_filled FROM public.refill_dispatching WHERE dispatch_id=v_lbind;
  SELECT COALESCE(packed,false), from_wh_inventory_id, COALESCE(filled_quantity,0)
    INTO p_packed, p_from, p_filled FROM public.refill_dispatching WHERE dispatch_id=v_lpack;

  SELECT count(*) FILTER (WHERE payload->>'status'='packed'),
         count(*) FILTER (WHERE (payload->>'ok')::boolean = false),
         max(payload->>'sqlerrm')
    INTO w1_packed, w1_err, w1_errmsg
  FROM golden._s5_leg_log WHERE run_tag=v_tag AND leg LIKE 'w1_pack%';

  SELECT payload->>'status', (payload->>'wait_ms')::numeric INTO w2_pack_status, w2_pack_wait
  FROM golden._s5_leg_log WHERE run_tag=v_tag AND leg='w2_pack' ORDER BY leg_log_id DESC LIMIT 1;

  SELECT (payload->>'wait_ms')::numeric, (payload->>'bound')::int INTO w2_bind_wait, w2_bind_bound
  FROM golden._s5_leg_log WHERE run_tag=v_tag AND leg='w2_bind' ORDER BY leg_log_id DESC LIMIT 1;

  -- pack_dispatch_line mints a CHILD dispatch row per extra pick. One pick each => zero children.
  SELECT count(*) INTO v_children FROM public.refill_dispatching
   WHERE dispatch_date=(p_setup->>'plan_date')::date
     AND machine_id=(p_setup->>'machine_id')::uuid
     AND dispatch_id NOT IN (v_lbind, v_lpack);

  SELECT count(*) INTO l_pr  FROM public.pod_refills;
  SELECT count(*) INTO l_prp FROM public.pod_refill_plan;
  SELECT count(*) INTO l_rpo FROM public.refill_plan_output;

  -- S-227: the verdict is a VALUES table. Never `v_fails := v_fails || '...'` on a text[].
  -- ⛔ COALESCE sits on the FAIL side, never the pass side.
  WITH a(seq, description, expect_op, expect, actual) AS (VALUES
    -- ---- setup integrity (non-vacuity: prove the plant is real before trusting any race)
    ( 1,'setup: bind line planted unpacked','eq','true',   COALESCE((v_su->>'bind_unpacked'),'<null>')),
    ( 2,'setup: pack line planted unpacked','eq','true',   COALESCE((v_su->>'pack_unpacked'),'<null>')),
    ( 3,'setup: bind line planted unbound','eq','true',    COALESCE((v_su->>'bind_unbound'),'<null>')),
    ( 4,'setup: all 3 batches pickable (S-189 not quarantined)','eq','3', COALESCE((v_su->>'batches_pickable'),'<null>')),
    ( 5,'setup: all 3 batches fenced to the test machine','eq','3',      COALESCE((v_su->>'batches_fenced'),'<null>')),
    ( 6,'setup: all 3 batches provenance=snapshot, unquarantined','eq','3', COALESCE((v_su->>'batches_snapshot'),'<null>')),
    ( 7,'setup: FEFO prefers Y (the batch pack never picks)','eq', v_y::text, COALESCE((v_su->>'fefo_first'),'<null>')),
    -- ---- WAVE 1 · pack_dispatch_line is clean, asserted POSITIVELY
    ( 8,'W1 pack-vs-pack: exactly one leg packed','eq','1',            COALESCE(w1_packed::text,'<null>')),
    ( 9,'W1 pack-vs-pack: exactly one leg refused','eq','1',           COALESCE(w1_err::text,'<null>')),
    (10,'W1 the refusal is "Already packed" (not a deadlock/serialisation)','contains','Already packed', COALESCE(w1_errmsg,'<null>')),
    (11,'W1 NO DOUBLE DEBIT: batch Z debited exactly once','eq', ((v_bank->>'z_wh')::numeric - v_qp)::text, COALESCE(z_wh::text,'<null>')),
    (12,'W1 batch Z consumer_stock credited exactly once','eq', ((v_bank->>'z_cs')::numeric + v_qp)::text,  COALESCE(z_cs::text,'<null>')),
    (13,'W1 batch Z conservation: wh+consumer unchanged','eq', ((v_bank->>'z_wh')::numeric + (v_bank->>'z_cs')::numeric)::text, COALESCE((z_wh+z_cs)::text,'<null>')),
    (14,'W1 pack line is packed','eq','true',                          COALESCE(p_packed::text,'<null>')),
    (15,'W1 pack line filled_quantity = planned','eq', v_qp::text,     COALESCE(p_filled::text,'<null>')),
    (16,'W1 pack line bound to the batch it was picked from (Z)','eq', v_z::text, COALESCE(p_from::text,'<null>')),
    -- ---- WAVE 2 · the offset race against bind_dispatch_fefo
    (17,'W2 WITNESS: bind blocked >=1500ms on the pack row lock (S-234: no wait = no race)','gte','1500', COALESCE(w2_bind_wait::text,'<null>')),
    (18,'W2 pack contender committed its pack','eq','packed',          COALESCE(w2_pack_status,'<null>')),
    (19,'W2 NO DOUBLE DEBIT: batch X debited exactly once','eq', ((v_bank->>'x_wh')::numeric - v_qb)::text, COALESCE(x_wh::text,'<null>')),
    (20,'W2 batch Y NEVER debited — the binder moves no stock','eq', (v_bank->>'y_wh'), COALESCE(y_wh::text,'<null>')),
    (21,'W2 batch X conservation: wh+consumer unchanged','eq', ((v_bank->>'x_wh')::numeric + (v_bank->>'x_cs')::numeric)::text, COALESCE((x_wh+x_cs)::text,'<null>')),
    (22,'W2 bind line is packed','eq','true',                          COALESCE(b_packed::text,'<null>')),
    -- ---- D-46 EXECUTED (leg 132). These three WERE the S-237 sensors pinning the defect
    -- (23 expected Y, 24 expected ne X, 25 expected bound>=1). CS ruled FIX THE BINDER NOW;
    -- migration 20260805231203 re-stated the two predicates inside the UPDATE's own WHERE, so the
    -- EvalPlanQual recheck now rejects the row. Flipping these from the defect to the property IS
    -- the proof the fix landed (S-103: expect AND description re-baselined together).
    -- ⛔ They must NEVER be weakened back to `not_null` — a green here is the whole point of S5.
    (23,'D-46: packed line NOT re-bound — still points at X, the batch pack actually debited','eq', v_x::text, COALESCE(b_from::text,'<null>')),
    (24,'D-46: bound batch == the batch actually debited (X) — conservation exposure CLOSED','eq', v_x::text, COALESCE(b_from::text,'<null>')),
    -- ⭐ S-245 break 4: was `eq '0'`. A global zero is contaminated by ANY other bindable row on
    -- this date+machine (the binder filters `cancelled` but not `skipped`/`include` — S-246).
    -- `bindable_others` is banked at plant time by replaying the binder's own targets+picks, so
    -- this now says exactly what D-46 requires: the binder bound what it was entitled to bind,
    -- and the packed racing line was NOT among it.
    (25,'D-46: binder bound only the rows it was entitled to — the packed racing line excluded','eq', (v_bank->>'bindable_others'), COALESCE(w2_bind_bound::text,'<null>')),
    -- ---- ADR §8 obligation-3 tripwire: absolute live counts, not scoped to plan_date
    -- ⭐ S-245: was `eq '0'`. On any run after the first, the PREVIOUS run's two permanent rows
    -- are already there, so a bare 0 measured residue rather than this run's behaviour. The
    -- property was always "THIS run minted no child rows" — state it that way.
    (26,'tripwire: no NEW child dispatch rows minted this run (prior-run residue banked, not assumed absent)','eq', (v_bank->>'pre_children'), COALESCE(v_children::text,'<null>')),
    (27,'tripwire: live pod_refills count unmoved','eq', (v_bank->>'live_pod_refills'),     COALESCE(l_pr::text,'<null>')),
    (28,'tripwire: live pod_refill_plan count unmoved','eq', (v_bank->>'live_pod_refill_plan'), COALESCE(l_prp::text,'<null>')),
    (29,'tripwire: live refill_plan_output count unmoved','eq', (v_bank->>'live_rpo'),      COALESCE(l_rpo::text,'<null>'))
  ),
  scored AS (
    SELECT a.*, golden.compare(a.actual, a.expect_op, a.expect) AS passed FROM a
  )
  SELECT count(*) FILTER (WHERE passed), count(*) FILTER (WHERE NOT passed),
         jsonb_agg(jsonb_build_object('seq',seq,'description',description,'expect_op',expect_op,
                                      'expect',expect,'actual',actual,'passed',passed) ORDER BY seq)
    INTO v_pass, v_fail, v_detail
  FROM scored;

  IF p_record THEN
    INSERT INTO golden.stress_runs
      (suite, started_at, finished_at, duration_ms, passed, n_pass, n_fail, metric, detail, driver, note)
    VALUES ('S5', v_start, clock_timestamp(),
            GREATEST(1, round(EXTRACT(EPOCH FROM (clock_timestamp() - v_start))*1000))::int,
            (v_fail = 0), v_pass, v_fail,
            jsonb_build_object(
              'run_tag', v_tag,
              'bind_lock_wait_ms', w2_bind_wait,
              'bind_reported_bound', w2_bind_bound,
              'w1_packed', w1_packed, 'w1_refused', w1_err,
              'x_debit', (v_bank->>'x_wh')::numeric - x_wh,
              'y_debit', (v_bank->>'y_wh')::numeric - y_wh,
              'z_debit', (v_bank->>'z_wh')::numeric - z_wh,
              'bind_line_bound_to', b_from,
              -- kept as a raw measurement, not an expectation: true would mean D-46 regressed
              's237_rebound_to_y', (b_from = v_y),
              'd46_fix_holds', (b_from = v_x AND COALESCE(w2_bind_bound,-1) = 0)),
            v_detail, 'external',
            COALESCE(p_note, 'S5 spot-buy race — pack_dispatch_line clean, S-237 FIXED (D-46) and asserted'))
    RETURNING stress_run_id INTO v_id;
  END IF;

  RETURN jsonb_build_object('suite','S5','stress_run_id',v_id,'n_pass',v_pass,'n_fail',v_fail,
                            'passed',(v_fail=0),'run_tag',v_tag,'detail',v_detail);
END;
$function$;
