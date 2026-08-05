-- PRD-110 P4.2 — golden fixtures 16 and 17: planning pins are READ AS CONSTRAINTS.
--
-- LAW 1 (FIXTURE FIRST): both land BEFORE engine_add_pod_v3 knows what a pin is, so
-- their first run is RED by construction. Leg 79/80's rule: a fixture that is green
-- before the thing it tests was built has proved nothing.
--
-- Fixture 16 (BUILD SPEC "Driver: don't reduce Oreo"): the 2-tap driver channel ->
-- proposal -> CS approve -> protect_depth pin -> THE NEXT PLAN RESPECTS THE DEPTH,
-- with the provenance chain intact end to end. 55 proved the schema, 56 proved the
-- verbs; 16 is the first fixture that proves CONSUMPTION.
--
-- Fixture 17 (BUILD SPEC "Client: always Coke Zero"): an always_stock + min_facing
-- pin in PERPETUAL mode binds on CONSECUTIVE plan dates and is never consumed by
-- being used.
--
-- ============================ THREE THINGS THAT SHAPED THESE ============================
--
-- 1. ⛔ PERF IS A DESIGN CONSTRAINT HERE, NOT AN AFTERTHOUGHT. Measured this leg:
--    engine_add_pod_v3 costs ~33 s for ONE machine and ~38 s for SIX. The cost is
--    fleet-wide-CTE fixed cost (S-26), NOT per-machine, so scoping to one machine buys
--    nothing and the ~105 s gateway caps a fixture at THREE engine runs. Fixture 7
--    (3 runs) measured 103.5 s -- already at the edge. Both fixtures here take TWO runs.
--    That is why 17 proves plan dates D+0/D+1 and its runtime sibling (fixture 57,
--    next unit) proves D+2/D+3: 4 consecutive plans, split on runtime grounds exactly
--    as fixture 48 was split into 49.
--
-- 2. ⭐ THE 2030 PLAN DATE ZEROES THE WHOLE BASELINE, AND THAT IS A GIFT. Every line on
--    a 2030 date clamps to expiry_ceiling (earliest_expiry - 2030-xx-xx < 0), so the
--    unpinned baseline is qty 0 on every shelf. Non-vacuity is therefore not an
--    assumption to be argued -- 0 -> N is directly observable, and seq 5 asserts the
--    baseline really is 0 before any assertion below leans on it. (Cousin of S-119.)
--
-- 3. ⭐ A01 AND A03 ARE BOTH "Coca Cola Zero" ON THE SAME MACHINE -- the same
--    pod_product_id on two shelves. That is free and precise fan-out detection: a
--    shelf-scoped pin that resolves through product_mapping must move A01 and leave
--    A03 at zero. A pin CTE that joins on pod alone passes every other assertion in
--    this file and fails that one.
--
-- ⛔ NEITHER FIXTURE WRITES A LIVE ROW. Everything runs inside a probe subtransaction
--    ending in a deliberate RAISE; plpgsql variables survive the rollback (the leg-80
--    technique), so the observations are captured first and written to golden.scratch
--    after the handler. S-117 rerunnability is therefore structural, not bolted on.

SET LOCAL statement_timeout = '180s';

DELETE FROM golden.assertions WHERE fixture_id IN (16, 17);
DELETE FROM golden.fixtures   WHERE fixture_id IN (16, 17);

-- =====================================================================================
-- FIXTURE 16
-- =====================================================================================
INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, baseline_status, enabled, notes, scenario_sql)
VALUES (
  16,
  'A driver 2-tap becomes a protect_depth pin and THE NEXT PLAN RESPECTS IT: the chain feedback -> proposal -> approve -> pin -> engine quantity is unbroken, the pin is surgical to its own shelf, and it raises DEMAND without ever conjuring warehouse stock (P4.2 L0 constraint read)',
  'PRD-110 BUILD SPEC fixture 16 — CS example "driver says do not reduce Oreo"',
  'P4',
  DATE '2030-01-01' + 16,
  'failing_expected',
  true,
  'Two engine runs (~67 s). Anchors on VML-1003-0400-O1: A10 Chocolate Bar is the pinned target (headroom 9, WH 155), A07 is the zero-availability probe, A15 is the untouched control.',
$fixture$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
DO $fx16$
DECLARE
  v_pd      date := {{plan_date}};
  m         uuid;
  sh_t      uuid;   -- A10, the pinned target
  sh_c      uuid;   -- A15, the control
  sh_z      uuid;   -- A07, zero availability
  pod_t     uuid; pod_z uuid;
  bp_t      uuid; bp_z uuid;
  v_res     jsonb;
  v_run_a   uuid; v_run_b uuid;
  v_a       jsonb; v_b jsonb;
  v_runs_ok integer := 0;
  v_err     text := '';
  v_lines_a integer := 0;
  v_nonzero_a integer := -1;
  v_stock_t integer; v_max_t integer;
  v_pin_val integer;
  v_qa_t integer := -1; v_qb_t integer := -1;
  v_qa_c integer := -1; v_qb_c integer := -1;
  v_qa_z integer := -1; v_qb_z integer := -1;
  v_depth_b integer := -1;
  v_clamp_b text := 'none'; v_clamp_z text := 'none';
  v_pinfloor_b integer := -1; v_pincount_b integer := -1;
  v_need_z integer := -1;
  v_moved   integer := -1;
  v_defaults_mm integer := -1;
  v_overshoot integer := -1;
  v_fb      uuid; v_prop uuid; v_pin uuid;
  v_prop_fb integer := -1; v_pin_fb integer := -1;
  v_pin_match integer := -1; v_pin_prop integer := -1;
  v_fb_state text := 'none'; v_drv_recs integer := -1;
  v_reads_view integer := -1; v_reads_base integer := -1;
  v_prp_before bigint; v_prp_after bigint;
  v_res_mtv bigint; v_res_sh bigint; v_live_pr bigint;
  v_res_pins bigint; v_res_fb bigint;
BEGIN
  SELECT count(*) INTO v_prp_before FROM public.pod_refill_plan;

  -- ======================= probe block: EVERYTHING below is rolled back =======================
  BEGIN
    SELECT machine_id INTO m FROM public.machines WHERE official_name = 'VML-1003-0400-O1';

    SELECT s.shelf_id, s.pod_product_id, COALESCE(s.current_stock,0), COALESCE(s.max_stock,0)
      INTO sh_t, pod_t, v_stock_t, v_max_t
      FROM public.v_shelf_state s WHERE s.machine_id = m AND s.shelf_code = 'A10';
    SELECT s.shelf_id INTO sh_c FROM public.v_shelf_state s WHERE s.machine_id = m AND s.shelf_code = 'A15';
    SELECT s.shelf_id, s.pod_product_id INTO sh_z, pod_z
      FROM public.v_shelf_state s WHERE s.machine_id = m AND s.shelf_code = 'A07';

    -- ⛔ The pinned SKU must resolve to EXACTLY ONE pod. A boonz product mapped to two
    --    pods would fan the pin out to shelves nobody complained about, and every other
    --    assertion here would still pass.
    SELECT pm.boonz_product_id INTO bp_t
      FROM public.product_mapping pm
     WHERE pm.pod_product_id = pod_t AND pm.status = 'Active'
       AND (pm.machine_id IS NULL OR pm.machine_id = m)
       AND (SELECT count(DISTINCT p2.pod_product_id) FROM public.product_mapping p2
             WHERE p2.boonz_product_id = pm.boonz_product_id AND p2.status = 'Active'
               AND (p2.machine_id IS NULL OR p2.machine_id = m)) = 1
     ORDER BY pm.boonz_product_id LIMIT 1;

    SELECT pm.boonz_product_id INTO bp_z
      FROM public.product_mapping pm
     WHERE pm.pod_product_id = pod_z AND pm.status = 'Active'
       AND (pm.machine_id IS NULL OR pm.machine_id = m)
     ORDER BY pm.boonz_product_id LIMIT 1;

    IF m IS NULL OR sh_t IS NULL OR sh_c IS NULL OR sh_z IS NULL OR bp_t IS NULL OR bp_z IS NULL THEN
      RAISE EXCEPTION 'FX16 setup: anchors incomplete (m=% t=% c=% z=% bp_t=% bp_z=%) - the fixture would assert over nothing',
        m, sh_t, sh_c, sh_z, bp_t, bp_z;
    END IF;

    -- depth the driver is protecting: 4 above where the shelf sits today, inside capacity
    v_pin_val := LEAST(v_stock_t + 4, v_max_t);
    IF v_pin_val <= v_stock_t THEN
      RAISE EXCEPTION 'FX16 setup: no headroom on the target shelf (stock=% max=%) - a depth pin could not bite',
        v_stock_t, v_max_t;
    END IF;

    DELETE FROM public.machines_to_visit WHERE plan_date = v_pd;
    INSERT INTO public.machines_to_visit
     (plan_date, machine_id, official_name, status, add_source, is_included, service_track,
      picked_reasons, active_intent_count, is_ramping, priority_score, picked_at, picked_by,
      venue_group, location_type, confirmed_at, confirmed_by)
    SELECT v_pd, machine_id, official_name, 'picked', 'operator', true, 'main',
           ARRAY['golden_fixture_16']::text[], 0, false, 100, now(),
           '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid, venue_group, location_type,
           now(), 'golden_fixture_16'
      FROM public.machines WHERE machine_id = m;

    -- ---- RUN A: the plan BEFORE anybody complained ----
    BEGIN
      SELECT public.engine_add_pod_v3(v_pd, 14) INTO v_res;
      v_run_a := (v_res->>'run_id')::uuid; v_runs_ok := v_runs_ok + 1;
    EXCEPTION WHEN OTHERS THEN v_err := v_err || ' A:' || SQLERRM; END;

    SELECT jsonb_object_agg(s.shelf_id::text, jsonb_build_object('q', s.qty, 'c', s.clamp_reason))
      INTO v_a FROM public.pod_refills_shadow s WHERE s.run_id = v_run_a;
    v_a := COALESCE(v_a, '{}'::jsonb);
    SELECT count(*), count(*) FILTER (WHERE (e.value->>'q')::int <> 0)
      INTO v_lines_a, v_nonzero_a FROM jsonb_each(v_a) e;

    v_qa_t := COALESCE((v_a->sh_t::text->>'q')::int, -1);
    v_qa_c := COALESCE((v_a->sh_c::text->>'q')::int, -1);
    v_qa_z := COALESCE((v_a->sh_z::text->>'q')::int, -1);

    -- ---- the two-tap, and everything it descends into ----
    v_fb := (public.submit_feedback_v3('driver', m, 'dont_reduce',
               'FX16 driver two-tap: stop reducing this line, it empties before I come back',
               sh_t, bp_t) ->> 'feedback_id')::uuid;
    SELECT count(*) INTO v_drv_recs FROM public.driver_recommendations dr
     WHERE dr.machine_id = m AND dr.notes LIKE 'FX16%';

    v_prop := (public.propose_pin_from_feedback_v3(ARRAY[v_fb], v_pd, 'protect_depth',
                 'FX16 driver asked us to stop cutting the depth on this shelf',
                 v_pin_val, 'perpetual', NULL) ->> 'proposal_id')::uuid;
    SELECT fl.status INTO v_fb_state FROM public.feedback_ledger_v3 fl WHERE fl.feedback_id = v_fb;

    v_pin := (public.approve_feedback_proposal_v3(v_prop, 'approve',
                 'FX16 CS approves the depth protection') ->> 'pin_id')::uuid;

    -- a SECOND pin, on the shelf the warehouse cannot serve at all
    DECLARE v_fb_z uuid; v_prop_z uuid;
    BEGIN
      v_fb_z := (public.submit_feedback_v3('cs', m, 'always_stock',
                   'FX16 CS wants this line always present even while the warehouse is dry',
                   sh_z, bp_z) ->> 'feedback_id')::uuid;
      v_prop_z := (public.propose_pin_from_feedback_v3(ARRAY[v_fb_z], v_pd, 'always_stock',
                     'FX16 standing presence instruction on a dry shelf',
                     NULL, 'perpetual', NULL) ->> 'proposal_id')::uuid;
      PERFORM public.approve_feedback_proposal_v3(v_prop_z, 'approve', 'FX16 CS approves presence');
    END;

    -- ---- provenance, measured off the rows themselves ----
    SELECT count(*) INTO v_prop_fb FROM public.feedback_proposals_v3 fp
     WHERE fp.proposal_id = v_prop AND v_fb = ANY (fp.feedback_ids);
    SELECT count(*) INTO v_pin_fb FROM public.planning_pins_v3 pp
     WHERE pp.pin_id = v_pin AND v_fb = ANY (pp.feedback_ids);
    SELECT count(*) INTO v_pin_prop FROM public.planning_pins_v3 pp
     WHERE pp.pin_id = v_pin AND pp.proposal_id = v_prop;
    SELECT count(*) INTO v_pin_match FROM public.planning_pins_v3 pp
     WHERE pp.pin_id = v_pin AND pp.machine_id = m AND pp.shelf_id = sh_t
       AND pp.boonz_product_id = bp_t AND pp.kind = 'protect_depth'
       AND pp.value = v_pin_val AND pp.mode = 'perpetual' AND pp.expires_at IS NULL;

    -- ---- RUN B: the NEXT plan ----
    BEGIN
      SELECT public.engine_add_pod_v3(v_pd, 14) INTO v_res;
      v_run_b := (v_res->>'run_id')::uuid; v_runs_ok := v_runs_ok + 1;
    EXCEPTION WHEN OTHERS THEN v_err := v_err || ' B:' || SQLERRM; END;

    SELECT jsonb_object_agg(s.shelf_id::text, jsonb_build_object(
             'q', s.qty, 'c', s.clamp_reason,
             'pf', COALESCE(s.reasoning->>'pin_floor_units','ABSENT'),
             'pc', COALESCE(s.reasoning->>'pin_count','ABSENT'),
             'nr', (s.reasoning->>'need_raw'),
             'cs', (s.reasoning->>'raw_current_stock')))
      INTO v_b FROM public.pod_refills_shadow s WHERE s.run_id = v_run_b;
    v_b := COALESCE(v_b, '{}'::jsonb);

    v_qb_t := COALESCE((v_b->sh_t::text->>'q')::int, -1);
    v_qb_c := COALESCE((v_b->sh_c::text->>'q')::int, -1);
    v_qb_z := COALESCE((v_b->sh_z::text->>'q')::int, -1);
    v_depth_b := COALESCE((v_b->sh_t::text->>'cs')::int, 0) + GREATEST(v_qb_t, 0);
    v_clamp_b := COALESCE(v_b->sh_t::text->>'c', 'MISSING');
    v_clamp_z := COALESCE(v_b->sh_z::text->>'c', 'MISSING');
    v_pinfloor_b := COALESCE(NULLIF(v_b->sh_t::text->>'pf','ABSENT')::int, -1);
    v_pincount_b := COALESCE(NULLIF(v_b->sh_t::text->>'pc','ABSENT')::int, -1);
    v_need_z := COALESCE(NULLIF(v_b->sh_z::text->>'nr','ABSENT')::int, -1);

    -- how many shelves moved at all between the two plans (must be exactly the one pinned)
    SELECT count(*) INTO v_moved FROM jsonb_each(v_b) e
     WHERE (e.value->>'q')::int IS DISTINCT FROM (v_a->e.key->>'q')::int;

    -- LAW 5: an UNPINNED line must record its emptiness EXPLICITLY, never by omission
    SELECT count(*) INTO v_defaults_mm FROM jsonb_each(v_b) e
     WHERE e.value->>'pc' = 'ABSENT' OR e.value->>'pf' = 'ABSENT';

    -- capacity is still king: no line may exceed its own headroom
    SELECT count(*) INTO v_overshoot FROM public.pod_refills_shadow s
     WHERE s.run_id = v_run_b AND s.qty > GREATEST(COALESCE(s.max_stock,0) - COALESCE(s.current_stock,0), 0);

    -- ⭐ the engine must read the CANONICAL view. The base table keeps revoked and expired
    --    pins forever; fixture 55 already proves the view hides them, so reading the view
    --    is what makes that proof reach the engine.
    SELECT count(*) INTO v_reads_view FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname='public' AND p.proname='engine_add_pod_v3' AND p.prosrc LIKE '%v_planning_pins_active_v3%';
    SELECT count(*) INTO v_reads_base FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname='public' AND p.proname='engine_add_pod_v3'
       AND p.prosrc ~ '(FROM|JOIN)\s+(public\.)?planning_pins_v3';

    RAISE EXCEPTION 'fx16_rollback' USING ERRCODE = '22023';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;   -- probe rows discarded; the measurements above survive in PL/pgSQL variables
  END;
  -- ======================= end probe block =======================

  SELECT count(*) INTO v_prp_after FROM public.pod_refill_plan;
  SELECT count(*) INTO v_res_mtv  FROM public.machines_to_visit WHERE plan_date = v_pd;
  SELECT count(*) INTO v_res_sh   FROM public.pod_refills_shadow WHERE plan_date = v_pd;
  SELECT count(*) INTO v_live_pr  FROM public.pod_refills WHERE plan_date = v_pd;
  SELECT count(*) INTO v_res_pins FROM public.planning_pins_v3 pp
    WHERE pp.pin_id IN (SELECT pin_id FROM public.planning_pins_v3 WHERE created_at > now() - interval '1 hour'
                          AND revoke_reason IS NULL AND pin_id = v_pin);
  SELECT count(*) INTO v_res_fb   FROM public.feedback_ledger_v3 WHERE note LIKE 'FX16%';

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES ({{fixture_id}}, 'obs', jsonb_build_object(
    'runs_ok',      v_runs_ok,
    'engine_err',   COALESCE(NULLIF(v_err,''),'none'),
    'lines_a',      v_lines_a,
    'nonzero_a',    v_nonzero_a,
    'pin_val',      v_pin_val,
    'stock_t',      v_stock_t,
    'max_t',        v_max_t,
    'qa_t',         v_qa_t,
    'qb_t',         v_qb_t,
    'depth_b',      v_depth_b,
    'clamp_b',      v_clamp_b,
    'pinfloor_b',   v_pinfloor_b,
    'pincount_b',   v_pincount_b,
    'qa_c',         v_qa_c,
    'qb_c',         v_qb_c,
    'qa_z',         v_qa_z,
    'qb_z',         v_qb_z,
    'clamp_z',      v_clamp_z,
    'need_z',       v_need_z,
    'moved',        v_moved,
    'defaults_mm',  v_defaults_mm,
    'overshoot',    v_overshoot,
    'prop_fb',      v_prop_fb,
    'pin_fb',       v_pin_fb,
    'pin_prop',     v_pin_prop,
    'pin_match',    v_pin_match,
    'fb_state',     COALESCE(v_fb_state,'none'),
    'drv_recs',     v_drv_recs,
    'reads_view',   v_reads_view,
    'reads_base',   v_reads_base,
    'residue_mtv',  v_res_mtv,
    'residue_sh',   v_res_sh,
    'residue_pins', v_res_pins,
    'residue_fb',   v_res_fb,
    'live_pr',      v_live_pr,
    'prp_delta',    v_prp_after - v_prp_before));
END $fx16$;
$fixture$);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required) VALUES
(16, 1,'HARNESS: both engine passes ran without error (A unpinned, B pinned)',
 $$SELECT value->>'runs_ok' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','2','P4'),
(16, 2,'HARNESS: neither engine pass raised',
 $$SELECT value->>'engine_err' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','none','P4'),
(16, 3,'NON-VACUITY: the unpinned baseline produced plan lines at all',
 $$SELECT value->>'lines_a' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'gt','0','P4'),
(16, 4,'PREMISE: the pinned target had real headroom, so a depth pin is capable of biting',
 $$SELECT (value->>'pin_val')::int - (value->>'stock_t')::int FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'gt','0','P4'),
(16, 5,'PREMISE (the whole baseline): on a 2030 plan date the expiry ceiling zeroes every line, so the pinned target starts at exactly 0 - every "the pin raised it" assertion below is measured against a real zero, not an assumed one',
 $$SELECT value->>'qa_t' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','0','P4'),
(16, 6,'CORE: the next plan RESPECTS THE PROTECTED DEPTH - resulting depth (stock on shelf + planned units) reaches the pinned value',
 $$SELECT (value->>'depth_b')::int - (value->>'pin_val')::int FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'gte','0','P4'),
(16, 7,'CORE: and it got there by PLANNING UNITS - the pinned line is no longer zero',
 $$SELECT value->>'qb_t' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'gt','0','P4'),
(16, 8,'The pin is what set the number: the line names pin_floor as the binding clamp',
 $$SELECT value->>'clamp_b' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','pin_floor','P4'),
(16, 9,'The planned quantity equals exactly the gap between the shelf and the protected depth - a pin is a FLOOR, not a licence to fill the shelf',
 $$SELECT (value->>'qb_t')::int - ((value->>'pin_val')::int - (value->>'stock_t')::int) FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','0','P4'),
(16,10,'The line carries the pin floor it was sized by (provenance, LAW 5)',
 $$SELECT (value->>'pinfloor_b')::int - ((value->>'pin_val')::int - (value->>'stock_t')::int) FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','0','P4'),
(16,11,'The line records that exactly ONE pin bound it',
 $$SELECT value->>'pincount_b' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','1','P4'),
(16,12,'SURGICAL: the control shelf, unpinned, is untouched by the pin',
 $$SELECT value->>'qb_c' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','0','P4'),
(16,13,'SURGICAL (the strong form): across the WHOLE machine exactly ONE shelf quantity moved between the two plans - a pin that fans out through product_mapping or pod identity fails HERE and nowhere else',
 $$SELECT value->>'moved' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','1','P4'),
(16,14,'A PIN RAISES DEMAND, IT NEVER CONJURES STOCK: on the shelf the warehouse cannot serve, the always_stock pin lifted the requirement...',
 $$SELECT value->>'need_z' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'gt','0','P4'),
(16,15,'...and the plan still shipped zero units, because availability is measured downstream of the pin',
 $$SELECT value->>'qb_z' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','0','P4'),
(16,16,'...and that zero is NAMED, not silent (LAW 5): the line says the warehouse blocked it, not that nothing was wanted',
 $$SELECT value->>'clamp_z' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','blocked_no_wh','P4'),
(16,17,'CAPACITY IS STILL KING: no line in the pinned plan exceeds its own physical headroom',
 $$SELECT value->>'overshoot' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','0','P4'),
(16,18,'LAW 5: every unpinned line records pin_count and pin_floor_units EXPLICITLY - silence about pins is never left ambiguous by omission',
 $$SELECT value->>'defaults_mm' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','0','P4'),
(16,19,'PROVENANCE: the driver two-tap really went through driver_propose_adjustment (the channel wraps, it does not restate)',
 $$SELECT value->>'drv_recs' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'gt','0','P4'),
(16,20,'PROVENANCE: the proposal cites the driver feedback row',
 $$SELECT value->>'prop_fb' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','1','P4'),
(16,21,'PROVENANCE: the minted pin still carries that same feedback id',
 $$SELECT value->>'pin_fb' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','1','P4'),
(16,22,'PROVENANCE: and it points back at the proposal that authorised it - the chain is a chain, not three unlinked rows',
 $$SELECT value->>'pin_prop' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','1','P4'),
(16,23,'PROVENANCE: the pin aims at exactly the machine, shelf and product the driver named, with the kind, value and perpetual mode CS approved',
 $$SELECT value->>'pin_match' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','1','P4'),
(16,24,'EVIDENCE IS SPENT ON CITATION: the feedback row left the open queue when it was cited',
 $$SELECT value->>'fb_state' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'ne','open','P4'),
(16,25,'THE ENGINE READS THE CANONICAL VIEW: v_planning_pins_active_v3, which hides revoked and expired pins (fixture 55 proves the predicate; this proves the engine is behind it)',
 $$SELECT value->>'reads_view' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','1','P4'),
(16,26,'AND NEVER THE BASE TABLE: a FROM/JOIN on planning_pins_v3 would honour pins CS has already revoked',
 $$SELECT value->>'reads_base' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','0','P4'),
(16,27,'RESIDUE: the fixture wrote no machines_to_visit row that outlived it',
 $$SELECT value->>'residue_mtv' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','0','P4'),
(16,28,'RESIDUE: no shadow plan rows survive the rollback',
 $$SELECT value->>'residue_sh' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','0','P4'),
(16,29,'RESIDUE: no pin, and no feedback row, outlived the probe (S-117 rerunnability is structural here)',
 $$SELECT (value->>'residue_pins')::int + (value->>'residue_fb')::int FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','0','P4'),
(16,30,'ADR-shadow-plan-tables: the live plan table was not touched at all',
 $$SELECT value->>'prp_delta' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','0','P4'),
(16,31,'LAW 4 (SHADOW, DO NOT SWITCH): the live pod_refills table gained nothing on this plan date',
 $$SELECT value->>'live_pr' FROM golden.scratch WHERE fixture_id=16 AND key='obs'$$,'eq','0','P4');

-- =====================================================================================
-- FIXTURE 17
-- =====================================================================================
INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, baseline_status, enabled, notes, scenario_sql)
VALUES (
  17,
  'A PERPETUAL always_stock + min_facing pin binds on CONSECUTIVE plan dates and is never consumed by being used: the client''s "always Coke Zero" survives planning, is visible with its mode, and moves the shelf it names without touching the identical pod on the shelf next to it (P4.2 L0 constraint read)',
  'PRD-110 BUILD SPEC fixture 17 — CS example "client wants Coke Zero always available"',
  'P4',
  DATE '2030-01-01' + 17,
  'failing_expected',
  true,
  'Two engine runs (~67 s) covering plan dates D+0 and D+1; fixture 57 covers D+2 and D+3 to complete the four consecutive plans (runtime split, precedent fixture 48 -> 49). A01 and A03 are BOTH Coca Cola Zero on VML-1003-0400-O1, which is what makes the fan-out guard at seq 12/13 real.',
$fixture$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
DO $fx17$
DECLARE
  v_pd0     date := {{plan_date}};
  v_pd1     date := {{plan_date}} + 1;
  m         uuid;
  sh_p      uuid;   -- A01 Coca Cola Zero, pinned
  sh_tw     uuid;   -- A03 Coca Cola Zero, the IDENTICAL pod, unpinned
  pod_p     uuid; bp_p uuid;
  v_res     jsonb;
  v_run0    uuid; v_run1 uuid;
  v_runs_ok integer := 0;
  v_err     text := '';
  v_same_pod integer := -1;
  v_stock_p integer; v_max_p integer;
  v_facing  integer;
  v_q0 integer := -1; v_q1 integer := -1;
  v_tw0 integer := -1; v_tw1 integer := -1;
  v_c0 text := 'none'; v_c1 text := 'none';
  v_cov0 integer := -1; v_flr0 integer := -1; v_pf0 integer := -1;
  v_pc0 integer := -1; v_pc1 integer := -1;
  v_lines0 integer := 0;
  v_mode text := 'none'; v_boxed text := 'none'; v_days text := 'SET';
  v_active_after0 integer := -1; v_active_after1 integer := -1;
  v_revoked integer := -1; v_expired integer := -1;
  v_kinds integer := -1;
  v_prp_before bigint; v_prp_after bigint;
  v_res_mtv bigint; v_res_sh bigint; v_res_pins bigint; v_live_pr bigint;
BEGIN
  SELECT count(*) INTO v_prp_before FROM public.pod_refill_plan;

  -- ======================= probe block: EVERYTHING below is rolled back =======================
  BEGIN
    SELECT machine_id INTO m FROM public.machines WHERE official_name = 'VML-1003-0400-O1';

    SELECT s.shelf_id, s.pod_product_id, COALESCE(s.current_stock,0), COALESCE(s.max_stock,0)
      INTO sh_p, pod_p, v_stock_p, v_max_p
      FROM public.v_shelf_state s WHERE s.machine_id = m AND s.shelf_code = 'A01';
    SELECT s.shelf_id INTO sh_tw
      FROM public.v_shelf_state s WHERE s.machine_id = m AND s.shelf_code = 'A03';

    -- the twin must really be the SAME pod, or seq 12/13 prove nothing
    SELECT count(*) INTO v_same_pod FROM public.v_shelf_state s
     WHERE s.shelf_id = sh_tw AND s.pod_product_id = pod_p;

    SELECT pm.boonz_product_id INTO bp_p
      FROM public.product_mapping pm
     WHERE pm.pod_product_id = pod_p AND pm.status = 'Active'
       AND (pm.machine_id IS NULL OR pm.machine_id = m)
     ORDER BY pm.boonz_product_id LIMIT 1;

    IF m IS NULL OR sh_p IS NULL OR sh_tw IS NULL OR bp_p IS NULL OR v_same_pod <> 1 THEN
      RAISE EXCEPTION 'FX17 setup: anchors incomplete (m=% p=% twin=% bp=% same_pod=%) - the fixture would assert over nothing',
        m, sh_p, sh_tw, bp_p, v_same_pod;
    END IF;

    v_facing := LEAST(3, GREATEST(v_max_p - v_stock_p, 0));
    IF v_facing < 1 THEN
      RAISE EXCEPTION 'FX17 setup: no headroom on A01 (stock=% max=%) - a facing pin could not bite', v_stock_p, v_max_p;
    END IF;

    -- ---- the client instruction, both halves, PERPETUAL ----
    DECLARE fb_a uuid; fb_f uuid; pr_a uuid; pr_f uuid;
    BEGIN
      fb_a := (public.submit_feedback_v3('client', m, 'always_stock',
                 'FX17 client asked that this line is always available on this shelf',
                 sh_p, bp_p) ->> 'feedback_id')::uuid;
      fb_f := (public.submit_feedback_v3('client', m, 'more_facings',
                 'FX17 client also wants a minimum presence, not a single unit',
                 sh_p, bp_p) ->> 'feedback_id')::uuid;
      pr_a := (public.propose_pin_from_feedback_v3(ARRAY[fb_a], v_pd0, 'always_stock',
                 'FX17 standing client instruction, no end date', NULL, 'perpetual', NULL) ->> 'proposal_id')::uuid;
      pr_f := (public.propose_pin_from_feedback_v3(ARRAY[fb_f], v_pd0, 'min_facing',
                 'FX17 minimum facing to go with it', v_facing, 'perpetual', NULL) ->> 'proposal_id')::uuid;
      PERFORM public.approve_feedback_proposal_v3(pr_a, 'approve', 'FX17 CS approves always-stock');
      PERFORM public.approve_feedback_proposal_v3(pr_f, 'approve', 'FX17 CS approves the facing floor');
    END;

    -- both kinds live simultaneously on one target (one per KIND, not one per target)
    SELECT count(*) INTO v_kinds FROM public.v_planning_pins_active_v3 pp
     WHERE pp.machine_id = m AND pp.shelf_id = sh_p AND pp.boonz_product_id = bp_p
       AND pp.kind IN ('always_stock','min_facing');

    SELECT pp.mode, (pp.is_time_boxed)::text, COALESCE(pp.days_remaining::text,'NULL')
      INTO v_mode, v_boxed, v_days
      FROM public.v_planning_pins_active_v3 pp
     WHERE pp.machine_id = m AND pp.shelf_id = sh_p AND pp.boonz_product_id = bp_p
       AND pp.kind = 'always_stock';

    DELETE FROM public.machines_to_visit WHERE plan_date IN (v_pd0, v_pd1);
    INSERT INTO public.machines_to_visit
     (plan_date, machine_id, official_name, status, add_source, is_included, service_track,
      picked_reasons, active_intent_count, is_ramping, priority_score, picked_at, picked_by,
      venue_group, location_type, confirmed_at, confirmed_by)
    SELECT d.pd, mm.machine_id, mm.official_name, 'picked', 'operator', true, 'main',
           ARRAY['golden_fixture_17']::text[], 0, false, 100, now(),
           '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid, mm.venue_group, mm.location_type,
           now(), 'golden_fixture_17'
      FROM public.machines mm CROSS JOIN (VALUES (v_pd0),(v_pd1)) AS d(pd)
     WHERE mm.machine_id = m;

    -- ---- PLAN 1 ----
    BEGIN
      SELECT public.engine_add_pod_v3(v_pd0, 14) INTO v_res;
      v_run0 := (v_res->>'run_id')::uuid; v_runs_ok := v_runs_ok + 1;
    EXCEPTION WHEN OTHERS THEN v_err := v_err || ' P0:' || SQLERRM; END;

    SELECT count(*) INTO v_lines0 FROM public.pod_refills_shadow WHERE run_id = v_run0;
    SELECT s.qty, s.clamp_reason, (s.reasoning->>'cover_units')::int, (s.reasoning->>'floor_units')::int,
           COALESCE((s.reasoning->>'pin_floor_units')::int,-1), COALESCE((s.reasoning->>'pin_count')::int,-1)
      INTO v_q0, v_c0, v_cov0, v_flr0, v_pf0, v_pc0
      FROM public.pod_refills_shadow s WHERE s.run_id = v_run0 AND s.shelf_id = sh_p;
    SELECT s.qty INTO v_tw0 FROM public.pod_refills_shadow s WHERE s.run_id = v_run0 AND s.shelf_id = sh_tw;

    -- being USED must not consume the pin
    SELECT count(*) INTO v_active_after0 FROM public.v_planning_pins_active_v3 pp
     WHERE pp.machine_id = m AND pp.shelf_id = sh_p AND pp.kind IN ('always_stock','min_facing');

    -- ---- PLAN 2, the NEXT day ----
    BEGIN
      SELECT public.engine_add_pod_v3(v_pd1, 14) INTO v_res;
      v_run1 := (v_res->>'run_id')::uuid; v_runs_ok := v_runs_ok + 1;
    EXCEPTION WHEN OTHERS THEN v_err := v_err || ' P1:' || SQLERRM; END;

    SELECT s.qty, s.clamp_reason, COALESCE((s.reasoning->>'pin_count')::int,-1)
      INTO v_q1, v_c1, v_pc1
      FROM public.pod_refills_shadow s WHERE s.run_id = v_run1 AND s.shelf_id = sh_p;
    SELECT s.qty INTO v_tw1 FROM public.pod_refills_shadow s WHERE s.run_id = v_run1 AND s.shelf_id = sh_tw;

    SELECT count(*) INTO v_active_after1 FROM public.v_planning_pins_active_v3 pp
     WHERE pp.machine_id = m AND pp.shelf_id = sh_p AND pp.kind IN ('always_stock','min_facing');
    SELECT count(*) INTO v_revoked FROM public.planning_pins_v3 pp
     WHERE pp.machine_id = m AND pp.shelf_id = sh_p AND pp.revoked_at IS NOT NULL;
    SELECT count(*) INTO v_expired FROM public.planning_pins_v3 pp
     WHERE pp.machine_id = m AND pp.shelf_id = sh_p AND pp.expires_at IS NOT NULL;

    RAISE EXCEPTION 'fx17_rollback' USING ERRCODE = '22023';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;
  -- ======================= end probe block =======================

  SELECT count(*) INTO v_prp_after FROM public.pod_refill_plan;
  SELECT count(*) INTO v_res_mtv  FROM public.machines_to_visit WHERE plan_date IN (v_pd0, v_pd1);
  SELECT count(*) INTO v_res_sh   FROM public.pod_refills_shadow WHERE plan_date IN (v_pd0, v_pd1);
  SELECT count(*) INTO v_live_pr  FROM public.pod_refills WHERE plan_date IN (v_pd0, v_pd1);
  SELECT count(*) INTO v_res_pins FROM public.feedback_ledger_v3 WHERE note LIKE 'FX17%';

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES ({{fixture_id}}, 'obs', jsonb_build_object(
    'runs_ok',     v_runs_ok,
    'engine_err',  COALESCE(NULLIF(v_err,''),'none'),
    'lines0',      v_lines0,
    'same_pod',    v_same_pod,
    'facing',      v_facing,
    'stock_p',     v_stock_p,
    'max_p',       v_max_p,
    'q0',          v_q0,
    'q1',          v_q1,
    'tw0',         v_tw0,
    'tw1',         v_tw1,
    'c0',          COALESCE(v_c0,'none'),
    'c1',          COALESCE(v_c1,'none'),
    'cov0',        v_cov0,
    'flr0',        v_flr0,
    'pf0',         v_pf0,
    'pc0',         v_pc0,
    'pc1',         v_pc1,
    'kinds',       v_kinds,
    'mode',        COALESCE(v_mode,'none'),
    'boxed',       COALESCE(v_boxed,'none'),
    'days',        COALESCE(v_days,'NULL'),
    'active0',     v_active_after0,
    'active1',     v_active_after1,
    'revoked',     v_revoked,
    'expired',     v_expired,
    'residue_mtv', v_res_mtv,
    'residue_sh',  v_res_sh,
    'residue_fb',  v_res_pins,
    'live_pr',     v_live_pr,
    'prp_delta',   v_prp_after - v_prp_before));
END $fx17$;
$fixture$);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required) VALUES
(17, 1,'HARNESS: both consecutive plan dates were planned without error',
 $$SELECT value->>'runs_ok' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','2','P4'),
(17, 2,'HARNESS: neither engine pass raised',
 $$SELECT value->>'engine_err' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','none','P4'),
(17, 3,'NON-VACUITY: the first plan produced lines at all',
 $$SELECT value->>'lines0' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'gt','0','P4'),
(17, 4,'PREMISE: the twin shelf really does carry the IDENTICAL pod, which is what makes the fan-out guard below meaningful',
 $$SELECT value->>'same_pod' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','1','P4'),
(17, 5,'BOTH KINDS COEXIST on one target: the uniqueness slot is per KIND, so a presence instruction and a depth instruction are not rivals',
 $$SELECT value->>'kinds' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','2','P4'),
(17, 6,'PIN IS VISIBLE WITH ITS MODE: perpetual',
 $$SELECT value->>'mode' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','perpetual','P4'),
(17, 7,'...and is not time-boxed',
 $$SELECT value->>'boxed' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','false','P4'),
(17, 8,'...so it reports no countdown, rather than a misleading zero',
 $$SELECT value->>'days' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','NULL','P4'),
(17, 9,'CORE, PLAN 1: the pinned line is present with at least the minimum facing',
 $$SELECT (value->>'q0')::int - (value->>'facing')::int FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'gte','0','P4'),
(17,10,'CORE, PLAN 2 (the NEXT consecutive date): still present, still at least the minimum facing - a perpetual pin does not fade after one use',
 $$SELECT (value->>'q1')::int - (value->>'facing')::int FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'gte','0','P4'),
(17,11,'THE PIN, NOT DEMAND, IS WHAT PUT IT THERE: velocity and the standing min-facing floor both wanted LESS than the pin does, and the line names pin_floor as its clamp - without this the two assertions above could be satisfied by ordinary demand and would prove nothing',
 $$SELECT value->>'c0' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','pin_floor','P4'),
(17,12,'FAN-OUT GUARD: the twin shelf carrying the IDENTICAL pod is untouched on plan 1 - a pin resolves to the shelf it names, not to every shelf sharing its pod',
 $$SELECT value->>'tw0' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','0','P4'),
(17,13,'FAN-OUT GUARD: and untouched again on plan 2',
 $$SELECT value->>'tw1' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','0','P4'),
(17,14,'The pin floor the engine applied is exactly the facing the client asked for',
 $$SELECT (value->>'pf0')::int - (value->>'facing')::int FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','0','P4'),
(17,15,'Both pins are recorded as binding the line, not just the louder one',
 $$SELECT value->>'pc0' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','2','P4'),
(17,16,'...and the same two on the second plan',
 $$SELECT value->>'pc1' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','2','P4'),
(17,17,'NOT CONSUMED BY USE: both pins are still active after the first planning',
 $$SELECT value->>'active0' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','2','P4'),
(17,18,'NOT CONSUMED BY USE: and still active after the second - planning reads a pin, it never spends one',
 $$SELECT value->>'active1' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','2','P4'),
(17,19,'PERPETUAL MEANS PERPETUAL: nothing revoked either pin as a side effect of planning',
 $$SELECT value->>'revoked' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','0','P4'),
(17,20,'...and neither acquired an expiry it was never given',
 $$SELECT value->>'expired' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','0','P4'),
(17,21,'RESIDUE: no machines_to_visit row outlived the probe',
 $$SELECT value->>'residue_mtv' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','0','P4'),
(17,22,'RESIDUE: no shadow plan rows survive on either plan date',
 $$SELECT value->>'residue_sh' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','0','P4'),
(17,23,'RESIDUE: no feedback row outlived the probe (S-117)',
 $$SELECT value->>'residue_fb' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','0','P4'),
(17,24,'ADR-shadow-plan-tables: the live plan table was not touched',
 $$SELECT value->>'prp_delta' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','0','P4'),
(17,25,'LAW 4: the live pod_refills table gained nothing on either plan date',
 $$SELECT value->>'live_pr' FROM golden.scratch WHERE fixture_id=17 AND key='obs'$$,'eq','0','P4');
