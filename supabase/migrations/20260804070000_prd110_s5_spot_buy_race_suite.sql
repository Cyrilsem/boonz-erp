-- PRD-110 STEP 7 · S5 — spot-buy race: no double debit, and the S-237 re-bind sensor.
--
-- DESIGN AUTHORITY: docs/prds/PRD-110-STEP7-STRESS-DESIGN.md §S5, "DESIGN CORRECTED, leg 123",
-- which supersedes the original three bullets. Read live (leg 123 + leg 124), not from spec:
--
--   * receive_spot_fill_po_v3 NEVER touches warehouse_inventory (D-E, stated in its own body).
--     Racing the two spot RPCs against each other asserts NOTHING (the S-132 sin).
--   * The only warehouse DEBIT on the pack path is pack_dispatch_line, and the real race axis is
--     bind_dispatch_fefo vs pack_dispatch_line. create_spot_purchase_v3 credits a fresh batch and
--     then calls the binder at step 6, which is how a spot buy lands mid-pack in production.
--   * pack_dispatch_line is CLEAN (FOR UPDATE on the dispatch row BEFORE the packed test; relative
--     delta debit under FOR UPDATE on the batch). WAVE 1 asserts that POSITIVELY.
--   * bind_dispatch_fefo is NOT (S-237): its packed=false / from_wh_inventory_id IS NULL predicates
--     live in the `targets` CTE while the final UPDATE joins on dispatch_id alone, so the
--     EvalPlanQual recheck after a lock wait re-evaluates only the UPDATE's own quals.
--     WAVE 2 races it for real and PINS the current behaviour as a sensor.
--
-- D-46 ROUTING (leg 124, recorded — CS decision still open): S5 PINS the defect as a sensor
-- (the fixture-9 / D-45 idiom) rather than fixing the binder first. Rationale: the binder fix is a
-- one-line change to a live writer on the write path of EVERY dispatch and is explicitly parked as
-- its own unit with its own Cody pass; folding it in here would violate that parking and LAW 10.
-- Assertions 23 and 24 are SENSORS: green TODAY, EXPECTED to red the day the binder is fixed, and
-- updating them is the proof the fix landed.
--
-- LAW 4 (shadow, don't switch): no live writer is modified. This migration adds one harness table
-- and four golden-schema functions. Nothing outside `golden` is created, altered or dropped.
-- LAW 12: the plant lives on reserved synthetic date 2030-11-05, on WH1-2002-0000-W0 — Inactive,
-- include_in_refill=false, and verified absent from v_machine_priority and machines_to_visit, so
-- no live priority or visit clock can see it.
--
-- PLANT RULES OBSERVED: S-189 (provenance_reason='snapshot' — the only honest non-quarantining
-- choice that also needs no fake source_event_id) · S-188 (one shelf per leg: A01 and A02, and two
-- DIFFERENT products, so wave 2's binder cannot see wave 1's line) · S-197 (a probe plant sets
-- app.via_trigger, never app.via_rpc) · S-235 (S5 CANNOT be a rollback probe — the pack contender
-- MUST commit for the bind contender to unblock — so every count is BANKED and compared with
-- STRICT equality) · S-227 (verdicts are built as a VALUES table, never by `text[] || text`).
--
-- The planted batch is fenced from the live fleet by reserved_for_machine_id = the test machine:
-- both bind_dispatch_fefo and pack_dispatch_line honour `reserved_for_machine_id IS NULL OR = machine_id`.

-- ---------------------------------------------------------------- leg result log
-- Each contender runs in its OWN connection and transaction, so it cannot return through the
-- driver's call stack into the verifier. Each leg records its own payload here instead.
CREATE TABLE IF NOT EXISTS golden._s5_leg_log (
  leg_log_id  bigserial PRIMARY KEY,
  run_tag     text        NOT NULL,
  leg         text        NOT NULL,
  payload     jsonb       NOT NULL,
  ts          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_s5_leg_log_run_tag ON golden._s5_leg_log (run_tag);

-- ---------------------------------------------------------------- setup / plant
CREATE OR REPLACE FUNCTION golden.stress_s5_setup_v1(p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, golden, pg_temp
AS $fn$
DECLARE
  c_machine   uuid := 'a6c02486-5d95-42ca-9adc-bc755c3019d3';  -- WH1-2002-0000-W0, Inactive
  c_mname     text := 'WH1-2002-0000-W0';
  c_date      date := '2030-11-05';
  c_shelf_a   uuid := '94c292a6-7259-4107-b548-9df03a6be70c';  -- A01, wave 2 (bind race)
  c_shelf_b   uuid := 'bc7028b9-0bc8-4b1b-bdd4-d7c1e302ddc5';  -- A02, wave 1 (pack vs pack)
  c_prod_p    uuid := '84910b35-a37b-42ab-90f1-0d75bdb6d937';  -- wave 2 product
  c_prod_q    uuid := '67d6061e-55be-4e1f-8668-07f96a8d63a2';  -- wave 1 product
  c_wh        uuid := public.wh_central_id()::uuid;
  v_tag       text := 'S5-' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDDHH24MISS');
  v_min       int  := extract(minute FROM now() AT TIME ZONE 'UTC')::int;
  v_x uuid; v_y uuid; v_z uuid;
  v_l_bind uuid; v_l_pack uuid;
BEGIN
  -- S-223: cron 44 rewrites shelf_composition at :40 and an external suite spans minutes across
  -- several transactions. Refuse to start inside the window rather than race the cron.
  IF v_min BETWEEN 36 AND 48 THEN
    RAISE EXCEPTION 'stress_s5_setup_v1: refusing to start at :% UTC (cron-44 window :36-:48, S-223)', v_min;
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
  VALUES (c_prod_p, c_wh, CURRENT_DATE, 6, 0, '2031-06-30', 'Active', 'snapshot', c_machine, v_tag||'-X', 'S5')
  RETURNING wh_inventory_id INTO v_x;

  INSERT INTO public.warehouse_inventory
    (boonz_product_id, warehouse_id, snapshot_date, warehouse_stock, consumer_stock,
     expiration_date, status, provenance_reason, reserved_for_machine_id, batch_id, wh_location)
  VALUES (c_prod_p, c_wh, CURRENT_DATE, 1, 0, '2031-01-31', 'Active', 'snapshot', c_machine, v_tag||'-Y', 'S5')
  RETURNING wh_inventory_id INTO v_y;

  INSERT INTO public.warehouse_inventory
    (boonz_product_id, warehouse_id, snapshot_date, warehouse_stock, consumer_stock,
     expiration_date, status, provenance_reason, reserved_for_machine_id, batch_id, wh_location)
  VALUES (c_prod_q, c_wh, CURRENT_DATE, 5, 0, '2031-12-31', 'Active', 'snapshot', c_machine, v_tag||'-Z', 'S5')
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
    -- S-235: bank everything. Strict equality later, never `>=`.
    'bank', jsonb_build_object(
      'x_wh', 6, 'x_cs', 0, 'y_wh', 1, 'y_cs', 0, 'z_wh', 5, 'z_cs', 0,
      'live_pod_refills',      (SELECT count(*) FROM public.pod_refills),
      'live_pod_refill_plan',  (SELECT count(*) FROM public.pod_refill_plan),
      'live_rpo',              (SELECT count(*) FROM public.refill_plan_output),
      'disp_total',            (SELECT count(*) FROM public.refill_dispatching)
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
$fn$;

-- ---------------------------------------------------------------- contender: PACK
-- Holds the row lock for p_hold_s AFTER the pack so the bind contender is guaranteed to queue
-- behind it. The hold is what makes the lock wait — and therefore the race — observable.
CREATE OR REPLACE FUNCTION golden.stress_s5_pack_leg_v1(
  p_run_tag text, p_leg text, p_dispatch_id uuid, p_wh_inventory_id uuid,
  p_qty numeric, p_barrier_epoch double precision, p_hold_s numeric DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, golden, pg_temp
AS $fn$
DECLARE
  v_barrier timestamptz := to_timestamp(p_barrier_epoch);
  v_t0 timestamptz; v_t1 timestamptz; v_res jsonb; v_out jsonb;
BEGIN
  PERFORM pg_sleep(GREATEST(0, EXTRACT(EPOCH FROM (v_barrier - clock_timestamp()))));
  v_t0 := clock_timestamp();
  BEGIN
    v_res := public.pack_dispatch_line(
               p_dispatch_id,
               jsonb_build_array(jsonb_build_object('wh_inventory_id', p_wh_inventory_id, 'qty', p_qty)),
               NULL);
    v_t1 := clock_timestamp();
    v_out := jsonb_build_object('ok', true, 'status', v_res->>'status', 'result', v_res,
                                'entered_at', v_t0, 'returned_at', v_t1,
                                'wait_ms', round(EXTRACT(EPOCH FROM (v_t1 - v_t0))*1000));
  EXCEPTION WHEN OTHERS THEN
    v_t1 := clock_timestamp();
    v_out := jsonb_build_object('ok', false, 'status', 'error', 'sqlstate', SQLSTATE, 'sqlerrm', SQLERRM,
                                'entered_at', v_t0, 'returned_at', v_t1,
                                'wait_ms', round(EXTRACT(EPOCH FROM (v_t1 - v_t0))*1000));
  END;
  INSERT INTO golden._s5_leg_log(run_tag, leg, payload) VALUES (p_run_tag, p_leg, v_out);
  IF p_hold_s > 0 THEN PERFORM pg_sleep(p_hold_s); END IF;
  RETURN v_out;
END;
$fn$;

-- ---------------------------------------------------------------- contender: BIND
-- The whole experiment. Enters AFTER the pack contender (offset barrier, not a common one) so its
-- statement snapshot still sees packed=false, then blocks on the pack contender's row lock.
-- ⛔ THE WITNESS IS wait_ms. No wait means the two never contended and the suite must FAIL rather
-- than pass on a race that did not happen (S-234).
CREATE OR REPLACE FUNCTION golden.stress_s5_bind_leg_v1(
  p_run_tag text, p_leg text, p_plan_date date, p_machine_name text, p_barrier_epoch double precision)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, golden, pg_temp
AS $fn$
DECLARE
  v_barrier timestamptz := to_timestamp(p_barrier_epoch);
  v_t0 timestamptz; v_t1 timestamptz; v_res jsonb; v_out jsonb;
BEGIN
  PERFORM pg_sleep(GREATEST(0, EXTRACT(EPOCH FROM (v_barrier - clock_timestamp()))));
  v_t0 := clock_timestamp();
  BEGIN
    v_res := public.bind_dispatch_fefo(p_plan_date, ARRAY[p_machine_name], NULL);
    v_t1 := clock_timestamp();
    v_out := jsonb_build_object('ok', true, 'bound', (v_res->>'bound')::int, 'result', v_res,
                                'entered_at', v_t0, 'returned_at', v_t1,
                                'wait_ms', round(EXTRACT(EPOCH FROM (v_t1 - v_t0))*1000));
  EXCEPTION WHEN OTHERS THEN
    v_t1 := clock_timestamp();
    v_out := jsonb_build_object('ok', false, 'sqlstate', SQLSTATE, 'sqlerrm', SQLERRM,
                                'entered_at', v_t0, 'returned_at', v_t1,
                                'wait_ms', round(EXTRACT(EPOCH FROM (v_t1 - v_t0))*1000));
  END;
  INSERT INTO golden._s5_leg_log(run_tag, leg, payload) VALUES (p_run_tag, p_leg, v_out);
  RETURN v_out;
END;
$fn$;

-- ---------------------------------------------------------------- verify
CREATE OR REPLACE FUNCTION golden.stress_s5_verify_v1(
  p_setup jsonb, p_record boolean DEFAULT true, p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, golden, pg_temp
AS $fn$
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
    -- ---- SENSORS (D-46 routing, leg 124): these PIN the S-237 defect as it stands TODAY.
    -- ⛔ They are EXPECTED to go RED the day bind_dispatch_fefo gets its two predicates back.
    -- Updating them from Y to X is the proof that the parked binder fix landed.
    (23,'S-237 SENSOR: packed line was RE-BOUND to Y by the binder (expected RED once fixed)','eq', v_y::text, COALESCE(b_from::text,'<null>')),
    (24,'S-237 SENSOR: bound batch != the batch actually debited (X) — the conservation exposure','ne', v_x::text, COALESCE(b_from::text,'<null>')),
    (25,'S-237 SENSOR: binder reported it bound a line it should have skipped','gte','1', COALESCE(w2_bind_bound::text,'<null>')),
    -- ---- ADR §8 obligation-3 tripwire: absolute live counts, not scoped to plan_date
    (26,'tripwire: no child dispatch rows minted (one pick per line)','eq','0', COALESCE(v_children::text,'<null>')),
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
              's237_reproduced', (b_from = v_y)),
            v_detail, 'external',
            COALESCE(p_note, 'S5 spot-buy race — pack_dispatch_line clean, S-237 pinned as sensor'))
    RETURNING stress_run_id INTO v_id;
  END IF;

  RETURN jsonb_build_object('suite','S5','stress_run_id',v_id,'n_pass',v_pass,'n_fail',v_fail,
                            'passed',(v_fail=0),'run_tag',v_tag,'detail',v_detail);
END;
$fn$;

REVOKE ALL ON FUNCTION golden.stress_s5_setup_v1(text)                                                   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION golden.stress_s5_pack_leg_v1(text,text,uuid,uuid,numeric,double precision,numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION golden.stress_s5_bind_leg_v1(text,text,date,text,double precision)                 FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION golden.stress_s5_verify_v1(jsonb,boolean,text)                                     FROM PUBLIC, anon, authenticated;
