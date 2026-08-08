-- PRD-110 · D-33 · FIXTURE FIRST (LAW 1)
--
-- CS ruled D-33 on 2026-08-01: "stitch consumes composed runs BY DEFAULT, coupling
-- pinned by a dedicated fixture". It was never executed. This is that fixture, and it
-- is authored to be RED against the engine as it stands.
--
-- THE DEFECT, stated exactly:
--   compose_plan_with_edits_v3 auto-picks its base with `engine_tag <> 'compose_v3'`
--   and a comment explaining why composing over a composition is forbidden.
--   stitch_v3 auto-picks its source with NO tag preference at all -- just
--   ORDER BY produced_at DESC, run_id DESC. The two halves of one seam were built
--   with opposite levels of care.
--
-- ⭐ AND IT IS WORSE THAN A PREFERENCE BUG. Fixture 51 section (2) already wrote the
--   diagnosis down and worked around it instead of fixing it: "Everything in this
--   scenario runs in ONE transaction, so R1 and any run composed from it share
--   produced_at = now(); the implicit (produced_at DESC, run_id DESC) pick therefore
--   lands on R1, i.e. on the UNEDITED plan. That is the coin flip, forced to its wrong
--   face." Same produced_at => the tiebreak is a RANDOM v4 uuid. The default source
--   pick is NON-DETERMINISTIC, and when it loses, every human edit vanishes silently.
--
-- ⛔ BLAST RADIUS SURVEYED BEFORE AUTHORING: fixtures 44, 46 and 47 are the only
--   fixtures that call stitch_v3 and ALL THREE pass an explicit source run. The one
--   in-DB caller, run_pipeline_v3, also passes explicitly (and RAISEs if stitch
--   reports a different source). No cron calls it. The DEFAULT path -- the one a human
--   invokes by hand -- is the ONLY path nobody ever pinned.
--
-- LAW 12: four synthetic 2030 plan_dates, all previously unused by any fixture.
-- LAW 4:  shadow tables only; live tripwires asserted as same-run deltas.
--
-- ⛔ IDEMPOTENCE UNDER RE-FIRE: pod_refills_shadow is append-only (ADR-shadow §5.1,
--   S-316) so this fixture CANNOT delete its own residue. It does not need to: each
--   fire inserts at now(), which is strictly later than every earlier fire's rows, so
--   "latest by produced_at" always resolves to THIS fire. The within-fire tie between
--   the base and its composition is exactly the coin flip under test.

BEGIN;

DELETE FROM golden.assertions WHERE fixture_id = 76;
DELETE FROM golden.fixtures   WHERE fixture_id = 76;

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, enabled, baseline_status, scenario_sql)
VALUES (
  76,
  'D-33: stitch_v3''s DEFAULT source is the COMPOSED plan, not a coin flip between the composition and its own base',
  'D-33 (CS 2026-08-01, answered YES, never executed). Diagnosed in fixture 51 section (2) and worked around rather than fixed.',
  'P3',
  DATE '2030-03-11',
  true,
  -- ⛔ golden.fixtures.baseline_status is CHECK-constrained to
  --    {failing_expected, passing, unknown}. 'red_before_fix' is not a member and the
  --    INSERT aborts whole. LAW 1's "red first" state is spelled 'failing_expected'.
  'failing_expected',
$SCEN$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- ---------------------------------------------------------------------------
-- (0) LIVE-BOARD BEFORE-CAPTURE (S-166). Same-run delta, never an absolute.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'tripwires_before', jsonb_build_object(
  'machines_to_visit',    (SELECT count(*) FROM public.machines_to_visit),
  'live_rpo_on_date',     (SELECT count(*) FROM public.refill_plan_output WHERE plan_date = {{plan_date}}),
  'pod_refills_on_date',  (SELECT count(*) FROM public.pod_refills        WHERE plan_date = {{plan_date}}));

-- ---------------------------------------------------------------------------
-- (1) STRUCTURAL PROBES. The signature must NOT drift: D-33 changes a body, not
--     an interface. pronargdefaults is asserted because an added default would
--     make stitch_v3(date) resolve to a different function without any error.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb := '{}'::jsonb; n int;
BEGIN
  v := v || jsonb_build_object('stitch',
    COALESCE(to_regprocedure('public.stitch_v3(date,uuid)')::text, 'no_stitch'));
  v := v || jsonb_build_object('compose',
    COALESCE(to_regprocedure('public.compose_plan_with_edits_v3(date,uuid)')::text, 'no_compose'));
  v := v || jsonb_build_object('editor',
    COALESCE(to_regprocedure('public.record_plan_edit_v3(date,uuid,uuid,text,integer,text,text)')::text, 'no_editor'));
  v := v || jsonb_build_object('edits_view',
    COALESCE(to_regclass('public.v_plan_edits_active_v3')::text, 'no_view'));

  SELECT count(*) INTO n FROM pg_proc WHERE proname = 'stitch_v3';
  v := v || jsonb_build_object('n_signatures', n);
  SELECT COALESCE(max(pronargdefaults), -1) INTO n FROM pg_proc WHERE proname = 'stitch_v3';
  v := v || jsonb_build_object('n_defaults', n);

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (76, 'struct', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (2) THE BASE RUN R1 on the primary date, minted with a run_id that sorts
--     ABOVE every random v4 uuid. This is fixture 51's own device, used here to
--     force the coin flip to its WRONG face deterministically instead of
--     steering around it.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'r1',
  to_jsonb(('ffffffff-ffff-4fff-bfff-' || substr(replace(gen_random_uuid()::text,'-',''),1,12))::uuid);

INSERT INTO public.pod_refills_shadow
  (run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id, qty,
   availability_basis, wh_available_pod)
SELECT ((SELECT value FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key='r1') #>> '{}')::uuid,
       'engine_add_pod_v3', {{plan_date}},
       '9db7a821-d312-43b0-8e83-9642abfbfb0b'::uuid, a.sid, a.pid, a.qty, 'boonz_wh', 0
FROM (VALUES
  ('b6454a65-f4da-4c07-8570-b8791f687ee2'::uuid,'31186e1c-b61b-4d13-b520-052fb86725a3'::uuid, 6),
  ('8539b03e-4628-4e26-bffe-6aa33c282b7a'::uuid,'fad6df6d-ac14-487a-be17-4210fb2d3c70'::uuid, 3),
  ('8ae4c5f3-cde6-4210-859b-a7aff71895a2'::uuid,'36f381fe-9e42-4d2f-920a-7c5192d56c43'::uuid, 5)
) AS a(sid,pid,qty);

-- ---------------------------------------------------------------------------
-- (3) A HARD HUMAN EDIT through the P3.6 writer, then COMPOSE it.
--     E shelf 6 -> 11. If the default pick is wrong, this 11 is what disappears.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb := '{}'::jsonb; r jsonb; r1 uuid;
BEGIN
  SELECT ((value #>> '{}')::uuid) INTO r1 FROM golden.scratch WHERE fixture_id=76 AND key='r1';

  BEGIN
    EXECUTE $x$ SELECT public.record_plan_edit_v3(DATE '2030-03-11',
       'b6454a65-f4da-4c07-8570-b8791f687ee2'::uuid,'31186e1c-b61b-4d13-b520-052fb86725a3'::uuid,
       'set_qty', 11, 'hard', 'D-33 fixture: CS holds this pod at 11 through the default stitch path') $x$
      INTO r;
    v := v || jsonb_build_object('edit', COALESCE(r->>'status','ok'));
  EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('edit', 'THREW: ' || SQLERRM);
  END;

  BEGIN
    EXECUTE $x$ SELECT public.compose_plan_with_edits_v3(DATE '2030-03-11', $1) $x$ INTO r USING r1;
    v := v || jsonb_build_object('compose', COALESCE(r->>'status','?'),
                                 'c1',      r->>'run_id',
                                 'applied', COALESCE(r->>'edits_applied','?'));
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (76, 'c1', to_jsonb(r->>'run_id'));
  EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('compose', 'THREW: ' || SQLERRM);
  END;

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (76, 'setup', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (4) ⭐⭐ PROBE A -- THE DEFECT ITSELF. stitch_v3 with NO source on a date whose
--     newest-by-tiebreak run is the raw base. It MUST consume the composition.
--     `needed` reads qty_needed, which is literally the source line's qty and is
--     therefore independent of live warehouse stock -- 11 means the edit rode
--     through, 6 means it was silently dropped.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb := '{}'::jsonb; r jsonb; c1 uuid; r1 uuid; n int;
BEGIN
  SELECT ((value #>> '{}')::uuid) INTO r1 FROM golden.scratch WHERE fixture_id=76 AND key='r1';
  SELECT ((value #>> '{}')::uuid) INTO c1 FROM golden.scratch WHERE fixture_id=76 AND key='c1';

  BEGIN
    EXECUTE $x$ SELECT public.stitch_v3(DATE '2030-03-11') $x$ INTO r;
    v := v || jsonb_build_object(
           'status',           COALESCE(r->>'status','?'),
           'consumed',         CASE WHEN (r->>'source_run_id')::uuid = c1 THEN 'COMPOSED'
                                    WHEN (r->>'source_run_id')::uuid = r1 THEN 'RAW_BASE'
                                    ELSE 'OTHER' END,
           'source_selection', COALESCE(r->>'source_selection','ABSENT'));

    -- qty_needed rides the LINE, so a split across FEFO legs repeats it on every leg;
    -- take the max rather than the sum so the assertion measures the EDIT and not the
    -- number of batches that happened to be in the warehouse today.
    EXECUTE $x$ SELECT COALESCE(MAX(qty_needed),-1)::int FROM public.refill_plan_output_shadow
                 WHERE run_id = $1
                   AND shelf_id = 'b6454a65-f4da-4c07-8570-b8791f687ee2'::uuid $x$
      INTO n USING (r->>'run_id')::uuid;
    v := v || jsonb_build_object('edited_shelf_qty_needed', n);
  EXCEPTION WHEN OTHERS THEN
    v := v || jsonb_build_object('status','THREW: ' || SQLERRM,
                                 'consumed','THREW','source_selection','THREW',
                                 'edited_shelf_qty_needed', -2);
  END;

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (76, 'probe_a', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (5) PROBE B -- STALE COMPOSITION. A base produced AFTER the last composition.
--     Neither answer is right: the base has lost the edits, the composition has
--     planned against stale demand. The engine must REFUSE and name both runs --
--     the same stance run_pipeline_v3 already takes on a composed-empty plan
--     ("Stop, and say so") rather than falling back to its base.
-- ---------------------------------------------------------------------------
INSERT INTO public.pod_refills_shadow
  (run_id, engine_tag, plan_date, produced_at, machine_id, shelf_id, pod_product_id, qty,
   availability_basis, wh_available_pod)
SELECT gen_random_uuid(), 'engine_add_pod_v3', {{plan_date}}, now() + interval '1 second',
       '9db7a821-d312-43b0-8e83-9642abfbfb0b'::uuid,
       'b6454a65-f4da-4c07-8570-b8791f687ee2'::uuid,
       '31186e1c-b61b-4d13-b520-052fb86725a3'::uuid, 6, 'boonz_wh', 0;

DO $do$
DECLARE v jsonb := '{}'::jsonb; r jsonb;
BEGIN
  BEGIN
    EXECUTE $x$ SELECT public.stitch_v3(DATE '2030-03-11') $x$ INTO r;
    v := v || jsonb_build_object('outcome','ACCEPTED','status',COALESCE(r->>'status','?'));
  EXCEPTION WHEN OTHERS THEN
    v := v || jsonb_build_object('outcome','REFUSED',
           'names_the_cause', (SQLERRM LIKE '%stale_composition%')::text);
  END;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (76, 'probe_b', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (6) PROBE C -- UNCOMPOSED EDITS on a second date. Active edits exist and
--     nothing has composed them. Consuming the base would drop them silently,
--     which is LAW 5 in the EDIT dimension. Refuse and say how many.
-- ---------------------------------------------------------------------------
INSERT INTO public.pod_refills_shadow
  (run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id, qty,
   availability_basis, wh_available_pod)
SELECT gen_random_uuid(), 'engine_add_pod_v3', DATE '2030-03-12',
       '9db7a821-d312-43b0-8e83-9642abfbfb0b'::uuid,
       '8539b03e-4628-4e26-bffe-6aa33c282b7a'::uuid,
       'fad6df6d-ac14-487a-be17-4210fb2d3c70'::uuid, 4, 'boonz_wh', 0;

DO $do$
DECLARE v jsonb := '{}'::jsonb; r jsonb; n int;
BEGIN
  BEGIN
    EXECUTE $x$ SELECT public.record_plan_edit_v3(DATE '2030-03-12',
       '8539b03e-4628-4e26-bffe-6aa33c282b7a'::uuid,'fad6df6d-ac14-487a-be17-4210fb2d3c70'::uuid,
       'set_qty', 9, 'hard', 'D-33 fixture: an edit nobody composed must never be stitched past') $x$
      INTO r;
    v := v || jsonb_build_object('edit', COALESCE(r->>'status','ok'));
  EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('edit','THREW: ' || SQLERRM);
  END;

  SELECT count(*) INTO n FROM public.v_plan_edits_active_v3 WHERE plan_date = DATE '2030-03-12';
  v := v || jsonb_build_object('active_edits', n);

  SELECT count(*) INTO n FROM public.pod_refills_shadow
   WHERE plan_date = DATE '2030-03-12' AND engine_tag = 'compose_v3';
  v := v || jsonb_build_object('compose_runs_on_date', n);

  BEGIN
    EXECUTE $x$ SELECT public.stitch_v3(DATE '2030-03-12') $x$ INTO r;
    v := v || jsonb_build_object('outcome','ACCEPTED','status',COALESCE(r->>'status','?'));
  EXCEPTION WHEN OTHERS THEN
    v := v || jsonb_build_object('outcome','REFUSED',
           'names_the_cause', (SQLERRM LIKE '%uncomposed_edits%')::text);
  END;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (76, 'probe_c', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (7) PROBE D -- THE HAPPY PATH SURVIVES. A date with a base, no compose run and
--     no edits has nothing to lose. Refusing here would break every by-hand
--     stitch on an unedited date, so it must still run -- and it must NAME the
--     fallback rather than pretend it consumed a plan.
-- ---------------------------------------------------------------------------
INSERT INTO public.pod_refills_shadow
  (run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id, qty,
   availability_basis, wh_available_pod)
SELECT gen_random_uuid(), 'engine_add_pod_v3', DATE '2030-03-13',
       '9db7a821-d312-43b0-8e83-9642abfbfb0b'::uuid,
       '8ae4c5f3-cde6-4210-859b-a7aff71895a2'::uuid,
       '36f381fe-9e42-4d2f-920a-7c5192d56c43'::uuid, 5, 'boonz_wh', 0;

DO $do$
DECLARE v jsonb := '{}'::jsonb; r jsonb; n int;
BEGIN
  SELECT count(*) INTO n FROM public.v_plan_edits_active_v3 WHERE plan_date = DATE '2030-03-13';
  v := v || jsonb_build_object('active_edits', n);
  BEGIN
    EXECUTE $x$ SELECT public.stitch_v3(DATE '2030-03-13') $x$ INTO r;
    v := v || jsonb_build_object('status', COALESCE(r->>'status','?'),
                                 'source_selection', COALESCE(r->>'source_selection','ABSENT'));
  EXCEPTION WHEN OTHERS THEN
    v := v || jsonb_build_object('status','THREW: ' || SQLERRM,'source_selection','THREW');
  END;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (76, 'probe_d', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (8) PROBE E -- THE EXPLICIT PATH IS BYTE-UNTOUCHED. D-33 changes only the
--     NULL branch. Passing the raw base explicitly must still consume the raw
--     base: the caller is allowed to mean what they said. (This is also what
--     keeps fixtures 44/46/47 and run_pipeline_v3 green.)
--     PROBE F -- an empty date still RETURNS no_source_run; it does not RAISE.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb := '{}'::jsonb; r jsonb; r1 uuid;
BEGIN
  SELECT ((value #>> '{}')::uuid) INTO r1 FROM golden.scratch WHERE fixture_id=76 AND key='r1';
  BEGIN
    EXECUTE $x$ SELECT public.stitch_v3(DATE '2030-03-11', $1) $x$ INTO r USING r1;
    v := v || jsonb_build_object('explicit_status', COALESCE(r->>'status','?'),
             'explicit_consumed_what_was_asked', ((r->>'source_run_id')::uuid = r1)::text,
             'explicit_selection', COALESCE(r->>'source_selection','ABSENT'));
  EXCEPTION WHEN OTHERS THEN
    v := v || jsonb_build_object('explicit_status','THREW: ' || SQLERRM,
             'explicit_consumed_what_was_asked','THREW','explicit_selection','THREW');
  END;

  BEGIN
    EXECUTE $x$ SELECT public.stitch_v3(DATE '2030-03-14') $x$ INTO r;
    v := v || jsonb_build_object('empty_date_status', COALESCE(r->>'status','?'));
  EXCEPTION WHEN OTHERS THEN
    v := v || jsonb_build_object('empty_date_status','THREW: ' || SQLERRM);
  END;

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (76, 'probe_ef', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (9) LIVE-TABLE TRIPWIRES. LAW 4: nothing above may move a live row.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'tripwires_after', jsonb_build_object(
  'machines_to_visit',    (SELECT count(*) FROM public.machines_to_visit),
  'live_rpo_on_date',     (SELECT count(*) FROM public.refill_plan_output WHERE plan_date = {{plan_date}}),
  'pod_refills_on_date',  (SELECT count(*) FROM public.pod_refills        WHERE plan_date = {{plan_date}}));
$SCEN$
);

-- ---------------------------------------------------------------------------
-- ASSERTIONS
-- ---------------------------------------------------------------------------
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
-- structure --------------------------------------------------------------
(76, 1, 'stitch_v3(date,uuid) exists',
 $q$SELECT value->>'stitch' FROM golden.scratch WHERE fixture_id=76 AND key='struct'$q$,
 'eq', 'stitch_v3(date,uuid)', true, 'P3'),
(76, 2, 'compose_plan_with_edits_v3(date,uuid) exists',
 $q$SELECT value->>'compose' FROM golden.scratch WHERE fixture_id=76 AND key='struct'$q$,
 'eq', 'compose_plan_with_edits_v3(date,uuid)', true, 'P3'),
(76, 3, 'the P3.6 edit writer exists',
 $q$SELECT value->>'editor' FROM golden.scratch WHERE fixture_id=76 AND key='struct'$q$,
 'eq', 'record_plan_edit_v3(date,uuid,uuid,text,integer,text,text)', true, 'P3'),
(76, 4, 'v_plan_edits_active_v3 exists (the object the refusal reads)',
 $q$SELECT value->>'edits_view' FROM golden.scratch WHERE fixture_id=76 AND key='struct'$q$,
 'eq', 'v_plan_edits_active_v3', true, 'P3'),
(76, 5, 'EXACTLY ONE stitch_v3 signature - D-33 changes a body, never an interface',
 $q$SELECT value->>'n_signatures' FROM golden.scratch WHERE fixture_id=76 AND key='struct'$q$,
 'eq', '1', true, 'P3'),
(76, 6, 'pronargdefaults still 1 - an added default would silently re-resolve stitch_v3(date)',
 $q$SELECT value->>'n_defaults' FROM golden.scratch WHERE fixture_id=76 AND key='struct'$q$,
 'eq', '1', true, 'P3'),

-- setup landed -----------------------------------------------------------
(76,10, 'the hard edit was recorded',
 $q$SELECT value->>'edit' FROM golden.scratch WHERE fixture_id=76 AND key='setup'$q$,
 'eq', 'ok', true, 'P3'),
(76,11, 'the composition ran',
 $q$SELECT value->>'compose' FROM golden.scratch WHERE fixture_id=76 AND key='setup'$q$,
 'eq', 'ok', true, 'P3'),
(76,12, 'the composition applied exactly the one edit',
 $q$SELECT value->>'applied' FROM golden.scratch WHERE fixture_id=76 AND key='setup'$q$,
 'eq', '1', true, 'P3'),

-- ⭐⭐ PROBE A -- the defect ---------------------------------------------
(76,20, 'the default stitch succeeded',
 $q$SELECT value->>'status' FROM golden.scratch WHERE fixture_id=76 AND key='probe_a'$q$,
 'eq', 'ok', true, 'P3'),
(76,21, '⭐⭐ D-33: the default source pick is the COMPOSED run, not the raw base it was composed from',
 $q$SELECT value->>'consumed' FROM golden.scratch WHERE fixture_id=76 AND key='probe_a'$q$,
 'eq', 'COMPOSED', true, 'P3'),
(76,22, '⭐ the receipt NAMES how the source was chosen instead of leaving it to be inferred',
 $q$SELECT value->>'source_selection' FROM golden.scratch WHERE fixture_id=76 AND key='probe_a'$q$,
 'eq', 'composed_latest', true, 'P3'),
(76,23, '⭐⭐ the human edit survived the default path: the stitched line carries 11, not the base 6',
 $q$SELECT value->>'edited_shelf_qty_needed' FROM golden.scratch WHERE fixture_id=76 AND key='probe_a'$q$,
 'eq', '11', true, 'P3'),

-- PROBE B -- stale composition -------------------------------------------
(76,30, 'a base produced AFTER the last composition is REFUSED, not silently preferred',
 $q$SELECT value->>'outcome' FROM golden.scratch WHERE fixture_id=76 AND key='probe_b'$q$,
 'eq', 'REFUSED', true, 'P3'),
(76,31, 'and the refusal names its own cause (stale_composition), not a generic error',
 $q$SELECT value->>'names_the_cause' FROM golden.scratch WHERE fixture_id=76 AND key='probe_b'$q$,
 'eq', 'true', true, 'P3'),

-- PROBE C -- uncomposed edits ---------------------------------------------
(76,40, 'the second date really does carry an active edit (the premise, not assumed)',
 $q$SELECT value->>'active_edits' FROM golden.scratch WHERE fixture_id=76 AND key='probe_c'$q$,
 'gte', '1', true, 'P3'),
(76,41, 'and it really does carry NO composition (the other half of the premise)',
 $q$SELECT value->>'compose_runs_on_date' FROM golden.scratch WHERE fixture_id=76 AND key='probe_c'$q$,
 'eq', '0', true, 'P3'),
(76,42, '⭐ LAW 5 in the EDIT dimension: an uncomposed active edit is REFUSED, never stitched past',
 $q$SELECT value->>'outcome' FROM golden.scratch WHERE fixture_id=76 AND key='probe_c'$q$,
 'eq', 'REFUSED', true, 'P3'),
(76,43, 'and that refusal names its own cause too (uncomposed_edits)',
 $q$SELECT value->>'names_the_cause' FROM golden.scratch WHERE fixture_id=76 AND key='probe_c'$q$,
 'eq', 'true', true, 'P3'),

-- PROBE D -- the happy path survives --------------------------------------
(76,50, 'the third date genuinely has no edits (premise)',
 $q$SELECT value->>'active_edits' FROM golden.scratch WHERE fixture_id=76 AND key='probe_d'$q$,
 'eq', '0', true, 'P3'),
(76,51, '⛔ a date with no edits and no composition still stitches - the fix is not a blanket refusal',
 $q$SELECT value->>'status' FROM golden.scratch WHERE fixture_id=76 AND key='probe_d'$q$,
 'eq', 'ok', true, 'P3'),
(76,52, 'and it says so out loud rather than implying it consumed a plan',
 $q$SELECT value->>'source_selection' FROM golden.scratch WHERE fixture_id=76 AND key='probe_d'$q$,
 'eq', 'uncomposed_fallback', true, 'P3'),

-- PROBE E/F -- the explicit path and the empty date ------------------------
(76,60, 'the EXPLICIT path still succeeds',
 $q$SELECT value->>'explicit_status' FROM golden.scratch WHERE fixture_id=76 AND key='probe_ef'$q$,
 'eq', 'ok', true, 'P3'),
(76,61, '⭐ an explicitly-passed RAW BASE is still consumed: the caller is allowed to mean what they said',
 $q$SELECT value->>'explicit_consumed_what_was_asked' FROM golden.scratch WHERE fixture_id=76 AND key='probe_ef'$q$,
 'eq', 'true', true, 'P3'),
(76,62, 'and the explicit path is labelled as such',
 $q$SELECT value->>'explicit_selection' FROM golden.scratch WHERE fixture_id=76 AND key='probe_ef'$q$,
 'eq', 'explicit', true, 'P3'),
(76,63, '⛔ an empty date still RETURNS no_source_run - the new refusals did not swallow it',
 $q$SELECT value->>'empty_date_status' FROM golden.scratch WHERE fixture_id=76 AND key='probe_ef'$q$,
 'eq', 'no_source_run', true, 'P3'),

-- LAW 4 tripwires, as same-run deltas -------------------------------------
(76,70, 'LAW 4: machines_to_visit unchanged across the whole scenario',
 $q$SELECT ((SELECT value->>'machines_to_visit' FROM golden.scratch WHERE fixture_id=76 AND key='tripwires_after')
         = (SELECT value->>'machines_to_visit' FROM golden.scratch WHERE fixture_id=76 AND key='tripwires_before'))::text$q$,
 'eq', 'true', true, 'P3'),
(76,71, 'LAW 4: no live refill_plan_output row on the fixture date',
 $q$SELECT value->>'live_rpo_on_date' FROM golden.scratch WHERE fixture_id=76 AND key='tripwires_after'$q$,
 'eq', '0', true, 'P3'),
(76,72, 'LAW 4: no live pod_refills row on the fixture date',
 $q$SELECT value->>'pod_refills_on_date' FROM golden.scratch WHERE fixture_id=76 AND key='tripwires_after'$q$,
 'eq', '0', true, 'P3');

COMMIT;
