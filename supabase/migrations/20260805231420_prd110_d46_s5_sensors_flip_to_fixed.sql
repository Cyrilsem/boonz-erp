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
    (25,'D-46: binder reported it bound NOTHING — it skipped the packed line','eq','0', COALESCE(w2_bind_bound::text,'<null>')),
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
