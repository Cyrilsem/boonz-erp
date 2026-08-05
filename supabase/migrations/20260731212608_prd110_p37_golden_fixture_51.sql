-- PRD-110 P3.7 — golden fixture 51: ONE PIPELINE (WS-E3)
-- LAW 1: this fixture lands BEFORE pipeline_runs_v3, run_pipeline_v3 and
-- approve_pipeline_run_v3 exist. Every probe of a not-yet-existing object is
-- guarded (to_regclass / to_regprocedure) and lands in golden.scratch; the
-- assertions read ONLY scratch.
--
-- ⛔ S-107 lesson from leg 70: a sentinel that reads 'absent' when the object is
--    missing can pass VACUOUSLY. Every guarded probe here returns the distinct
--    sentinel 'no_pipeline', which no real value can equal, so an assertion can
--    only go green on real pipeline output.

DELETE FROM golden.assertions WHERE fixture_id = 51;
DELETE FROM golden.fixtures  WHERE fixture_id = 51;

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql)
VALUES (
51,
'ONE PIPELINE: the plan that gets stitched is the plan the human approved. engine -> compose -> stitch runs as one receipted unit that passes run ids EXPLICITLY, a human edit survives all the way into the stitched output, and exactly one pipeline run per plan_date can ever be approved (P3.7)',
'PRD-110 BUILD-SPEC P3.7 / WS-E3 + the coupling P3.6 shipped IMPLICIT (leg 70 pointer). stitch_v3 called with a NULL source picks the latest shadow run for the date by (produced_at DESC, run_id DESC). pod_refills_shadow.produced_at DEFAULTs to now(), which is the TRANSACTION timestamp -- so when a base run and its composed run are written in ONE transaction (which is exactly what a pipeline is) their produced_at values TIE, and the pick collapses onto uuid ordering of run_id. The human overlay therefore reaches the stitched plan or is discarded by a coin flip. This fixture makes the coin flip land the WRONG way on purpose (the base run is minted with a run_id that sorts above every random v4 uuid) and proves the pipeline is unaffected because it never relies on the implicit pick.',
'P3',
DATE '2030-02-21',
$scen$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- ---------------------------------------------------------------------------
-- (0) ANCHORS. Four real boonz_wh shelves on one Active machine
--     (HUAWEI-2003-0000-B1), the same proven anchor set as fixture 50 on a
--     DIFFERENT plan_date. E carries a hard edit, D a hard drop, U is the
--     untouched control, A is a shelf the engine never planned.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'anchors', jsonb_build_object(
  'machine', '9db7a821-d312-43b0-8e83-9642abfbfb0b',
  'E_shelf', 'b6454a65-f4da-4c07-8570-b8791f687ee2', 'E_pod', '31186e1c-b61b-4d13-b520-052fb86725a3',
  'D_shelf', '8539b03e-4628-4e26-bffe-6aa33c282b7a', 'D_pod', 'fad6df6d-ac14-487a-be17-4210fb2d3c70',
  'U_shelf', '8ae4c5f3-cde6-4210-859b-a7aff71895a2', 'U_pod', '36f381fe-9e42-4d2f-920a-7c5192d56c43',
  'A_shelf', '13e2f91f-8d0e-4a82-af03-058763887ce4', 'A_pod', '417a7836-e82e-4050-bbfc-8a7892d9ddcb');

-- ---------------------------------------------------------------------------
-- (1) STRUCTURAL PROBES. All guarded; all land in scratch.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb := '{}'::jsonb; n int; t text;
BEGIN
  v := v || jsonb_build_object('tbl',  COALESCE(to_regclass('public.pipeline_runs_v3')::text, 'no_pipeline'));
  v := v || jsonb_build_object('view', COALESCE(to_regclass('public.v_pipeline_runs_v3')::text, 'no_pipeline'));
  v := v || jsonb_build_object('runner',
    COALESCE(to_regprocedure('public.run_pipeline_v3(date,integer,uuid,boolean,text)')::text, 'no_pipeline'));
  v := v || jsonb_build_object('approver',
    COALESCE(to_regprocedure('public.approve_pipeline_run_v3(uuid,text)')::text, 'no_pipeline'));

  IF to_regclass('public.pipeline_runs_v3') IS NOT NULL THEN
    SELECT count(*) INTO n FROM information_schema.columns
     WHERE table_schema='public' AND table_name='pipeline_runs_v3'
       AND column_name IN ('pipeline_run_id','plan_date','base_run_id','composed_run_id',
                           'planned_run_id','stitch_run_id','status');
    v := v || jsonb_build_object('id_cols', n);
    SELECT count(*) INTO n FROM information_schema.columns
     WHERE table_schema='public' AND table_name='pipeline_runs_v3'
       AND column_name IN ('approved_at','approved_by','approve_reason');
    v := v || jsonb_build_object('approval_cols', n);
    SELECT count(*) INTO n FROM information_schema.role_table_grants
     WHERE table_schema='public' AND table_name='pipeline_runs_v3' AND grantee='anon';
    v := v || jsonb_build_object('anon_grants', n);
    -- one approved run per date must be STRUCTURAL, not writer discipline
    SELECT string_agg(indexdef, ' | ' ORDER BY indexname) INTO t
      FROM pg_indexes WHERE schemaname='public' AND tablename='pipeline_runs_v3';
    v := v || jsonb_build_object('indexes', COALESCE(t,'none'));
  END IF;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (51, 'struct', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (2) BASE RUN R1 -- minted with a run_id that sorts ABOVE every random v4
--     uuid. Everything in this scenario runs in ONE transaction, so R1 and any
--     run composed from it share produced_at = now(); the implicit
--     (produced_at DESC, run_id DESC) pick therefore lands on R1, i.e. on the
--     UNEDITED plan. That is the coin flip, forced to its wrong face.
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
-- (3) THE THREE EDITS, through the P3.6 writer (which already exists).
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb := '{}'::jsonb; r jsonb;
BEGIN
  IF to_regprocedure('public.record_plan_edit_v3(date,uuid,uuid,text,integer,text,text)') IS NOT NULL THEN
    EXECUTE $x$ SELECT public.record_plan_edit_v3(DATE '2030-02-21',
       'b6454a65-f4da-4c07-8570-b8791f687ee2'::uuid,'31186e1c-b61b-4d13-b520-052fb86725a3'::uuid,
       'set_qty', 11, 'hard', 'CS holds Mountain Dew at 11 through the whole pipeline') $x$ INTO r;
    v := v || jsonb_build_object('E', r);
    EXECUTE $x$ SELECT public.record_plan_edit_v3(DATE '2030-02-21',
       '8539b03e-4628-4e26-bffe-6aa33c282b7a'::uuid,'fad6df6d-ac14-487a-be17-4210fb2d3c70'::uuid,
       'drop', NULL, 'hard', 'SF Pancake delisted; it must not reach the stitched plan') $x$ INTO r;
    v := v || jsonb_build_object('D', r);
    EXECUTE $x$ SELECT public.record_plan_edit_v3(DATE '2030-02-21',
       '13e2f91f-8d0e-4a82-af03-058763887ce4'::uuid,'417a7836-e82e-4050-bbfc-8a7892d9ddcb'::uuid,
       'add', 7, 'soft', 'Be-kind Bar empty on the floor, engine missed it entirely') $x$ INTO r;
    v := v || jsonb_build_object('A', r);
  END IF;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (51, 'edits', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (4) PIPELINE RUN 1. The base is SUPPLIED (a golden fixture may not run the
--     live engine against a synthetic date), so the pipeline skips step 1 and
--     starts at compose. Everything downstream is the real thing.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb; rows jsonb; n int; t text;
BEGIN
  IF to_regprocedure('public.run_pipeline_v3(date,integer,uuid,boolean,text)') IS NOT NULL THEN
    BEGIN
      EXECUTE $x$ SELECT public.run_pipeline_v3(DATE '2030-02-21', 14,
        ((SELECT value FROM golden.scratch WHERE fixture_id = 51 AND key='r1') #>> '{}')::uuid,
        false, 'golden fixture 51 run 1') $x$ INTO v;
    EXCEPTION WHEN OTHERS THEN
      -- ⛔ S-106: a scenario that THROWS reads exactly like an engine that was
      --    never built. Capture the error as data instead.
      v := jsonb_build_object('status', 'THREW: ' || SQLERRM, 'sqlstate', SQLSTATE);
    END;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (51, 'p1', v);

    -- the stitched plan, at line grain, keyed on the shelf the human edited
    EXECUTE $x$ SELECT COALESCE(jsonb_object_agg(shelf_id::text, q), '{}'::jsonb) FROM (
        SELECT shelf_id, SUM(qty)::int AS q FROM public.refill_plan_output_shadow
         WHERE run_id = $1 GROUP BY shelf_id) z $x$
      INTO rows USING (v#>>'{stitch,run_id}')::uuid;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (51, 'p1_stitched', rows);

    -- and the composed plan it was supposed to consume
    EXECUTE $x$ SELECT COALESCE(jsonb_object_agg(shelf_id::text, qty), '{}'::jsonb)
                 FROM public.pod_refills_shadow WHERE run_id = $1 $x$
      INTO rows USING (v->>'planned_run_id')::uuid;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (51, 'p1_composed', rows);

    -- the receipt must be PERSISTED, not merely returned
    EXECUTE $x$ SELECT jsonb_build_object(
        'rows', (SELECT count(*) FROM public.pipeline_runs_v3
                   WHERE plan_date = DATE '2030-02-21' AND created_at = now()),
        'status', (SELECT status FROM public.pipeline_runs_v3 WHERE pipeline_run_id = $1),
        'planned', (SELECT planned_run_id::text FROM public.pipeline_runs_v3 WHERE pipeline_run_id = $1),
        'stitch',  (SELECT stitch_run_id::text  FROM public.pipeline_runs_v3 WHERE pipeline_run_id = $1),
        'approved',(SELECT (approved_at IS NULL)::text FROM public.pipeline_runs_v3 WHERE pipeline_run_id = $1)) $x$
      INTO rows USING (v->>'pipeline_run_id')::uuid;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (51, 'p1_persisted', rows);
  ELSE
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (51, 'p1', '"no_pipeline"'::jsonb);
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (51, 'p1_stitched', '"no_pipeline"'::jsonb);
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (51, 'p1_composed', '"no_pipeline"'::jsonb);
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (51, 'p1_persisted', '"no_pipeline"'::jsonb);
  END IF;
END
$do$;

-- ---------------------------------------------------------------------------
-- (5) THE COIN FLIP, MEASURED. What would a NULL-source stitch have picked?
--     Measured AFTER the compose exists, over the rows written in THIS
--     transaction only.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb := '{}'::jsonb; pick uuid; tag text; n int; composed uuid;
BEGIN
  SELECT s.run_id, s.engine_tag INTO pick, tag
    FROM public.pod_refills_shadow s
   WHERE s.plan_date = DATE '2030-02-21'
   ORDER BY s.produced_at DESC, s.run_id DESC LIMIT 1;
  v := v || jsonb_build_object('implicit_tag', COALESCE(tag,'none'));

  SELECT count(DISTINCT s.produced_at) INTO n
    FROM public.pod_refills_shadow s
   WHERE s.plan_date = DATE '2030-02-21' AND s.produced_at = now();
  v := v || jsonb_build_object('tied_produced_at_rows_in_this_tx',
        (SELECT count(*) FROM public.pod_refills_shadow s
          WHERE s.plan_date = DATE '2030-02-21' AND s.produced_at = now()));
  v := v || jsonb_build_object('distinct_produced_at_in_this_tx', n);

  SELECT (value->>'planned_run_id')::uuid INTO composed
    FROM golden.scratch WHERE fixture_id = 51 AND key = 'p1';
  v := v || jsonb_build_object('implicit_equals_planned',
        CASE WHEN composed IS NULL THEN 'no_pipeline'
             ELSE (pick = composed)::text END);
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (51, 'coinflip', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (6) BASE RUN R2 -- the engine re-run. E moves 6 -> 9. The hard edit must
--     still reach the STITCHED output at 11, not at the engine's new 9.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'r2', to_jsonb(gen_random_uuid());

INSERT INTO public.pod_refills_shadow
  (run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id, qty,
   availability_basis, wh_available_pod)
SELECT ((SELECT value FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key='r2') #>> '{}')::uuid,
       'engine_add_pod_v3', {{plan_date}},
       '9db7a821-d312-43b0-8e83-9642abfbfb0b'::uuid, a.sid, a.pid, a.qty, 'boonz_wh', 0
FROM (VALUES
  ('b6454a65-f4da-4c07-8570-b8791f687ee2'::uuid,'31186e1c-b61b-4d13-b520-052fb86725a3'::uuid, 9),
  ('8539b03e-4628-4e26-bffe-6aa33c282b7a'::uuid,'fad6df6d-ac14-487a-be17-4210fb2d3c70'::uuid, 3),
  ('8ae4c5f3-cde6-4210-859b-a7aff71895a2'::uuid,'36f381fe-9e42-4d2f-920a-7c5192d56c43'::uuid, 5)
) AS a(sid,pid,qty);

-- ---------------------------------------------------------------------------
-- (7) PIPELINE RUN 2 over the moved base.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb; rows jsonb;
BEGIN
  IF to_regprocedure('public.run_pipeline_v3(date,integer,uuid,boolean,text)') IS NOT NULL THEN
    BEGIN
      EXECUTE $x$ SELECT public.run_pipeline_v3(DATE '2030-02-21', 14,
        ((SELECT value FROM golden.scratch WHERE fixture_id = 51 AND key='r2') #>> '{}')::uuid,
        false, 'golden fixture 51 run 2') $x$ INTO v;
    EXCEPTION WHEN OTHERS THEN
      v := jsonb_build_object('status', 'THREW: ' || SQLERRM, 'sqlstate', SQLSTATE);
    END;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (51, 'p2', v);

    EXECUTE $x$ SELECT COALESCE(jsonb_object_agg(shelf_id::text, q), '{}'::jsonb) FROM (
        SELECT shelf_id, SUM(qty)::int AS q FROM public.refill_plan_output_shadow
         WHERE run_id = $1 GROUP BY shelf_id) z $x$
      INTO rows USING (v#>>'{stitch,run_id}')::uuid;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (51, 'p2_stitched', rows);

    -- the pipeline must never rewrite its own input base run
    EXECUTE $x$ SELECT COALESCE(jsonb_object_agg(shelf_id::text, qty), '{}'::jsonb)
                 FROM public.pod_refills_shadow WHERE run_id =
      ((SELECT value FROM golden.scratch WHERE fixture_id = 51 AND key='r2') #>> '{}')::uuid $x$ INTO rows;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (51, 'r2_after', rows);
  ELSE
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (51, 'p2', '"no_pipeline"'::jsonb);
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (51, 'p2_stitched', '"no_pipeline"'::jsonb);
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (51, 'r2_after', '"no_pipeline"'::jsonb);
  END IF;
END
$do$;

-- ---------------------------------------------------------------------------
-- (8) SINGLE APPROVE VOCABULARY. One approved pipeline run per plan_date, and
--     approval is the only thing on the receipt that may ever move.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb := '{}'::jsonb; r jsonb; n int; p2 uuid; p1 uuid;
BEGIN
  IF to_regprocedure('public.approve_pipeline_run_v3(uuid,text)') IS NOT NULL THEN
    SELECT (value->>'pipeline_run_id')::uuid INTO p1 FROM golden.scratch WHERE fixture_id=51 AND key='p1';
    SELECT (value->>'pipeline_run_id')::uuid INTO p2 FROM golden.scratch WHERE fixture_id=51 AND key='p2';

    BEGIN
      EXECUTE $x$ SELECT public.approve_pipeline_run_v3($1, 'CS approves the composed plan for 2030-02-21') $x$
        INTO r USING p2;
      v := v || jsonb_build_object('approve', r->>'status');
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('approve', 'THREW: ' || SQLERRM);
    END;

    BEGIN
      EXECUTE $x$ SELECT public.approve_pipeline_run_v3($1, 'CS approves the same run a second time') $x$
        INTO r USING p2;
      v := v || jsonb_build_object('double_approve', 'ACCEPTED');
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('double_approve', 'REFUSED');
    END;

    -- approving a DIFFERENT run for the same date is legal, but it must RETIRE
    -- the standing approval rather than leave two plans approved for one night.
    BEGIN
      EXECUTE $x$ SELECT public.approve_pipeline_run_v3($1, 'CS switches the approval back to the earlier run') $x$
        INTO r USING p1;
      v := v || jsonb_build_object('switch', r->>'status')
             || jsonb_build_object('switch_superseded', COALESCE(r->>'superseded_approval_of','none'));
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('switch', 'THREW: ' || SQLERRM);
    END;

    BEGIN
      EXECUTE $x$ SELECT public.approve_pipeline_run_v3($1, 'thin') $x$ INTO r USING p2;
      v := v || jsonb_build_object('thin_reason', 'ACCEPTED');
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('thin_reason', 'REFUSED');
    END;

    BEGIN
      EXECUTE $x$ SELECT public.approve_pipeline_run_v3(gen_random_uuid(),
        'CS approves a pipeline run that does not exist') $x$ INTO r;
      v := v || jsonb_build_object('unknown_run', 'ACCEPTED');
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('unknown_run', 'REFUSED');
    END;

    EXECUTE $x$ SELECT count(*)::int FROM public.pipeline_runs_v3
               WHERE plan_date = DATE '2030-02-21'
                 AND approved_at IS NOT NULL AND approval_superseded_at IS NULL $x$ INTO n;
    v := v || jsonb_build_object('standing_approvals_on_date', n);

    EXECUTE $x$ SELECT count(*)::int FROM public.pipeline_runs_v3
               WHERE plan_date = DATE '2030-02-21' AND created_at = now()
                 AND approved_at IS NOT NULL $x$ INTO n;
    v := v || jsonb_build_object('ever_approved_in_this_tx', n);
  ELSE
    v := v || jsonb_build_object('approve','no_pipeline','double_approve','no_pipeline',
                                 'switch','no_pipeline','switch_superseded','no_pipeline',
                                 'thin_reason','no_pipeline','unknown_run','no_pipeline',
                                 'standing_approvals_on_date','no_pipeline',
                                 'ever_approved_in_this_tx','no_pipeline');
  END IF;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (51, 'approve', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (9) APPEND-ONLY GUARDS on the receipt ledger. S-108: a row-level trigger
--     never sees a TRUNCATE, and GRANT ALL TO service_role carries it.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb := '{}'::jsonb;
BEGIN
  IF to_regclass('public.pipeline_runs_v3') IS NOT NULL THEN
    BEGIN
      EXECUTE $x$ DELETE FROM public.pipeline_runs_v3 WHERE plan_date = DATE '2030-02-21' $x$;
      v := v || jsonb_build_object('delete','ALLOWED');
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('delete','REFUSED');
    END;
    BEGIN
      EXECUTE $x$ UPDATE public.pipeline_runs_v3 SET plan_date = DATE '2030-02-22'
                   WHERE plan_date = DATE '2030-02-21' $x$;
      v := v || jsonb_build_object('update_core','ALLOWED');
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('update_core','REFUSED');
    END;
    BEGIN
      EXECUTE $x$ UPDATE public.pipeline_runs_v3 SET approved_at = NULL, approved_by = NULL,
                     approve_reason = NULL
                   WHERE plan_date = DATE '2030-02-21' AND approved_at IS NOT NULL $x$;
      v := v || jsonb_build_object('unapprove','ALLOWED');
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('unapprove','REFUSED');
    END;
    BEGIN
      EXECUTE $x$ TRUNCATE public.pipeline_runs_v3 $x$;
      v := v || jsonb_build_object('truncate','ALLOWED');
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('truncate','REFUSED');
    END;
  ELSE
    v := v || jsonb_build_object('delete','no_pipeline','update_core','no_pipeline',
                                 'unapprove','no_pipeline','truncate','no_pipeline');
  END IF;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (51, 'guards', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (10) LIVE-TABLE TRIPWIRES. LAW 4 / LAW 11: a pipeline that ends in an
--      approval must still move nothing live.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'tripwires', jsonb_build_object(
  'live_rpo_on_date',   (SELECT count(*) FROM public.refill_plan_output WHERE plan_date = {{plan_date}}),
  'machines_to_visit',  (SELECT count(*) FROM public.machines_to_visit),
  'pod_refills_on_date',(SELECT count(*) FROM public.pod_refills WHERE plan_date = {{plan_date}}));
$scen$
);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required) VALUES

-- ============================ STRUCTURE ==================================
(51, 1, 'pipeline_runs_v3 exists',
 $c$SELECT value->>'tbl' FROM golden.scratch WHERE fixture_id=51 AND key='struct'$c$, 'eq', 'pipeline_runs_v3', 'P3'),
(51, 2, 'the seven run-identity columns are all present',
 $c$SELECT (value->>'id_cols') FROM golden.scratch WHERE fixture_id=51 AND key='struct'$c$, 'eq', '7', 'P3'),
(51, 3, 'the three approval columns are present',
 $c$SELECT (value->>'approval_cols') FROM golden.scratch WHERE fixture_id=51 AND key='struct'$c$, 'eq', '3', 'P3'),
(51, 4, 'anon holds no grant on the receipt ledger (S-88: the GRANT is the write guard)',
 $c$SELECT (value->>'anon_grants') FROM golden.scratch WHERE fixture_id=51 AND key='struct'$c$, 'eq', '0', 'P3'),
(51, 5, 'ONE APPROVED RUN PER DATE IS STRUCTURAL: a partial unique index enforces it, not writer discipline',
 $c$SELECT value->>'indexes' FROM golden.scratch WHERE fixture_id=51 AND key='struct'$c$, 'contains', 'approval_superseded_at IS NULL', 'P3'),
(51, 6, 'v_pipeline_runs_v3 exists',
 $c$SELECT value->>'view' FROM golden.scratch WHERE fixture_id=51 AND key='struct'$c$, 'eq', 'v_pipeline_runs_v3', 'P3'),
(51, 7, 'run_pipeline_v3 exists at the specified signature',
 $c$SELECT value->>'runner' FROM golden.scratch WHERE fixture_id=51 AND key='struct'$c$, 'contains', 'run_pipeline_v3', 'P3'),
(51, 8, 'approve_pipeline_run_v3 exists at the specified signature',
 $c$SELECT value->>'approver' FROM golden.scratch WHERE fixture_id=51 AND key='struct'$c$, 'contains', 'approve_pipeline_run_v3', 'P3'),

-- ============================ THE PIPELINE ===============================
(51, 9, 'the pipeline ran to completion',
 $c$SELECT value->>'status' FROM golden.scratch WHERE fixture_id=51 AND key='p1'$c$, 'eq', 'ok', 'P3'),
(51, 10, 'the base was the SUPPLIED run, and the pipeline says which it used rather than leaving it to be inferred',
 $c$SELECT value->>'base_source' FROM golden.scratch WHERE fixture_id=51 AND key='p1'$c$, 'eq', 'supplied', 'P3'),
(51, 11, 'the pipeline composed the base rather than skipping straight to stitch',
 $c$SELECT COALESCE((SELECT value#>>'{compose,status}' FROM golden.scratch WHERE fixture_id=51 AND key='p1'),'no_pipeline')$c$, 'eq', 'ok', 'P3'),
(51, 12, 'THE PIN: the run stitch was given is the COMPOSED run, passed explicitly',
 $c$SELECT COALESCE((SELECT ((value->>'planned_run_id') = (value#>>'{compose,run_id}'))::text
   FROM golden.scratch WHERE fixture_id=51 AND key='p1'),'no_pipeline')$c$, 'eq', 'true', 'P3'),
(51, 13, '...and stitch CONFIRMS it consumed exactly that run, from its own return value',
 $c$SELECT COALESCE((SELECT ((value#>>'{stitch,source_run_id}') = (value->>'planned_run_id'))::text
   FROM golden.scratch WHERE fixture_id=51 AND key='p1'),'no_pipeline')$c$, 'eq', 'true', 'P3'),
(51, 14, 'the planned run is a compose_v3 run, never the raw engine run',
 $c$SELECT COALESCE((SELECT value#>>'{compose,engine_tag}' FROM golden.scratch WHERE fixture_id=51 AND key='p1'),'no_pipeline')$c$, 'eq', 'compose_v3', 'P3'),
(51, 15, 'all three edits were considered by the pipeline',
 $c$SELECT COALESCE((SELECT value#>>'{compose,edits_considered}' FROM golden.scratch WHERE fixture_id=51 AND key='p1'),'no_pipeline')$c$, 'eq', '3', 'P3'),
(51, 16, 'all three applied on the first pass -- none yielded, none lost',
 $c$SELECT COALESCE((SELECT value#>>'{compose,edits_applied}' FROM golden.scratch WHERE fixture_id=51 AND key='p1'),'no_pipeline')$c$, 'eq', '3', 'P3'),

-- =============== THE COMPOSED PLAN IS WHAT REACHED STITCH ================
(51, 17, 'composed E: the hard edit 11 replaced the engine 6',
 $c$SELECT COALESCE((SELECT value->>'b6454a65-f4da-4c07-8570-b8791f687ee2' FROM golden.scratch WHERE fixture_id=51 AND key='p1_composed'),'no_pipeline')$c$, 'eq', '11', 'P3'),
(51, 18, 'composed A: the human-introduced line exists at 7',
 $c$SELECT COALESCE((SELECT value->>'13e2f91f-8d0e-4a82-af03-058763887ce4' FROM golden.scratch WHERE fixture_id=51 AND key='p1_composed'),'no_pipeline')$c$, 'eq', '7', 'P3'),
(51, 19, 'composed D: the dropped shelf is gone',
 $c$SELECT CASE WHEN (SELECT value FROM golden.scratch WHERE fixture_id=51 AND key='p1_composed') = '"no_pipeline"'::jsonb
   THEN 'no_pipeline' ELSE COALESCE((SELECT value->>'8539b03e-4628-4e26-bffe-6aa33c282b7a'
   FROM golden.scratch WHERE fixture_id=51 AND key='p1_composed'),'dropped') END$c$, 'eq', 'dropped', 'P3'),
(51, 20, 'stitch was fed the composed 23 units (11+5+7), NOT the engine base 14',
 $c$SELECT COALESCE((SELECT value#>>'{stitch,units_in}' FROM golden.scratch WHERE fixture_id=51 AND key='p1'),'no_pipeline')$c$, 'eq', '23', 'P3'),
(51, 21, 'THE HUMAN NUMBER REACHED THE STITCHED PLAN: shelf E carries 11 units end to end',
 $c$SELECT COALESCE((SELECT value->>'b6454a65-f4da-4c07-8570-b8791f687ee2' FROM golden.scratch WHERE fixture_id=51 AND key='p1_stitched'),'no_pipeline')$c$, 'eq', '11', 'P3'),
(51, 22, 'the human-introduced line reached the stitched plan at 7',
 $c$SELECT COALESCE((SELECT value->>'13e2f91f-8d0e-4a82-af03-058763887ce4' FROM golden.scratch WHERE fixture_id=51 AND key='p1_stitched'),'no_pipeline')$c$, 'eq', '7', 'P3'),
(51, 23, 'the untouched control reached the stitched plan unchanged at 5',
 $c$SELECT COALESCE((SELECT value->>'8ae4c5f3-cde6-4210-859b-a7aff71895a2' FROM golden.scratch WHERE fixture_id=51 AND key='p1_stitched'),'no_pipeline')$c$, 'eq', '5', 'P3'),
(51, 24, 'THE DROP HELD ALL THE WAY DOWN: the delisted shelf appears nowhere in the stitched plan',
 $c$SELECT CASE WHEN (SELECT value FROM golden.scratch WHERE fixture_id=51 AND key='p1_stitched') = '"no_pipeline"'::jsonb
   THEN 'no_pipeline' ELSE COALESCE((SELECT value->>'8539b03e-4628-4e26-bffe-6aa33c282b7a'
   FROM golden.scratch WHERE fixture_id=51 AND key='p1_stitched'),'dropped') END$c$, 'eq', 'dropped', 'P3'),
(51, 25, 'LAW 5 holds through the seam: stitch placed + blocked = fed in, nothing silently vanished',
 $c$SELECT COALESCE((SELECT (((value#>>'{stitch,units_placed}')::int + (value#>>'{stitch,units_blocked}')::int)
   = (value#>>'{stitch,units_in}')::int)::text FROM golden.scratch WHERE fixture_id=51 AND key='p1'),'no_pipeline')$c$, 'eq', 'true', 'P3'),

-- ===================== THE COIN FLIP, MEASURED ==========================
(51, 26, 'PREMISE: base and composed runs written in one transaction share ONE produced_at -- the tie is real',
 $c$SELECT (value->>'distinct_produced_at_in_this_tx') FROM golden.scratch WHERE fixture_id=51 AND key='coinflip'$c$, 'eq', '1', 'P3'),
(51, 27, 'PREMISE: more than one run is tied on that produced_at, so the pick falls to run_id ordering alone',
 $c$SELECT ((SELECT (value->>'tied_produced_at_rows_in_this_tx')::int FROM golden.scratch WHERE fixture_id=51 AND key='coinflip') > 3)::text$c$, 'eq', 'true', 'P3'),
(51, 28, 'THE DEFECT, SHOWN: an implicit NULL-source stitch would have picked the RAW ENGINE run here',
 $c$SELECT value->>'implicit_tag' FROM golden.scratch WHERE fixture_id=51 AND key='coinflip'$c$, 'eq', 'engine_add_pod_v3', 'P3'),
(51, 29, '...i.e. it would NOT have been the run the pipeline planned -- every human edit discarded, silently',
 $c$SELECT value->>'implicit_equals_planned' FROM golden.scratch WHERE fixture_id=51 AND key='coinflip'$c$, 'eq', 'false', 'P3'),

-- ============ SURVIVAL THROUGH A SECOND FULL PIPELINE PASS ==============
(51, 30, 'the second pipeline pass ran to completion',
 $c$SELECT value->>'status' FROM golden.scratch WHERE fixture_id=51 AND key='p2'$c$, 'eq', 'ok', 'P3'),
(51, 31, 'PREMISE: the re-run genuinely moved E from 6 to 9 in the base',
 $c$SELECT COALESCE((SELECT value->>'b6454a65-f4da-4c07-8570-b8791f687ee2' FROM golden.scratch WHERE fixture_id=51 AND key='r2_after'),'no_pipeline')$c$, 'eq', '9', 'P3'),
(51, 32, 'THE HARD EDIT SURVIVED A FULL PIPELINE RE-RUN: shelf E is still 11 in the stitched plan, not the engine''s new 9',
 $c$SELECT COALESCE((SELECT value->>'b6454a65-f4da-4c07-8570-b8791f687ee2' FROM golden.scratch WHERE fixture_id=51 AND key='p2_stitched'),'no_pipeline')$c$, 'eq', '11', 'P3'),
(51, 33, 'the drop survived the re-run too -- still nowhere in the stitched plan',
 $c$SELECT CASE WHEN (SELECT value FROM golden.scratch WHERE fixture_id=51 AND key='p2_stitched') = '"no_pipeline"'::jsonb
   THEN 'no_pipeline' ELSE COALESCE((SELECT value->>'8539b03e-4628-4e26-bffe-6aa33c282b7a'
   FROM golden.scratch WHERE fixture_id=51 AND key='p2_stitched'),'dropped') END$c$, 'eq', 'dropped', 'P3'),
(51, 34, 'the second pass produced a DISTINCT pipeline run -- the ledger is append-only, not a slot',
 $c$SELECT COALESCE((SELECT ((SELECT value->>'pipeline_run_id' FROM golden.scratch WHERE fixture_id=51 AND key='p1')
   IS DISTINCT FROM (SELECT value->>'pipeline_run_id' FROM golden.scratch WHERE fixture_id=51 AND key='p2'))::text),'no_pipeline')$c$, 'eq', 'true', 'P3'),
(51, 35, 'the pipeline never rewrote its own input base run',
 $c$SELECT COALESCE((SELECT value->>'8ae4c5f3-cde6-4210-859b-a7aff71895a2' FROM golden.scratch WHERE fixture_id=51 AND key='r2_after'),'no_pipeline')$c$, 'eq', '5', 'P3'),

-- ========================= THE RECEIPT PERSISTS =========================
(51, 36, 'two pipeline runs are on record for the date, not just returned to the caller',
 $c$SELECT COALESCE((SELECT value->>'rows' FROM golden.scratch WHERE fixture_id=51 AND key='p1_persisted'),'no_pipeline')$c$, 'eq', '2', 'P3'),
(51, 37, 'the persisted receipt carries the same planned run the return value named',
 $c$SELECT COALESCE((SELECT ((value->>'planned') = (SELECT s.value->>'planned_run_id' FROM golden.scratch s
   WHERE s.fixture_id=51 AND s.key='p1'))::text FROM golden.scratch WHERE fixture_id=51 AND key='p1_persisted'),'no_pipeline')$c$, 'eq', 'true', 'P3'),
(51, 38, 'a pipeline run is born UNAPPROVED -- running is not approving',
 $c$SELECT COALESCE((SELECT value->>'approved' FROM golden.scratch WHERE fixture_id=51 AND key='p1_persisted'),'no_pipeline')$c$, 'eq', 'true', 'P3'),

-- ===================== SINGLE APPROVE VOCABULARY ========================
(51, 39, 'the second run was approved',
 $c$SELECT value->>'approve' FROM golden.scratch WHERE fixture_id=51 AND key='approve'$c$, 'eq', 'ok', 'P3'),
(51, 40, 'approving the SAME run twice is REFUSED -- an approval is not a button to press again',
 $c$SELECT value->>'double_approve' FROM golden.scratch WHERE fixture_id=51 AND key='approve'$c$, 'eq', 'REFUSED', 'P3'),
(51, 41, 'approving a DIFFERENT run for the same date is allowed, because a late edit must be approvable',
 $c$SELECT value->>'switch' FROM golden.scratch WHERE fixture_id=51 AND key='approve'$c$, 'eq', 'ok', 'P3'),
(51, 42, '...but it RETIRES the standing approval by name -- never silently, never two plans for one night',
 $c$SELECT value->>'switch_superseded' FROM golden.scratch WHERE fixture_id=51 AND key='approve'$c$, 'ne', 'none', 'P3'),
(51, 43, 'SINGLE APPROVE: exactly ONE standing approval exists for the plan_date',
 $c$SELECT (value->>'standing_approvals_on_date') FROM golden.scratch WHERE fixture_id=51 AND key='approve'$c$, 'eq', '1', 'P3'),
(51, 44, '...even though TWO runs of this date carry an approval event -- the retired one is history, not a rival',
 $c$SELECT (value->>'ever_approved_in_this_tx') FROM golden.scratch WHERE fixture_id=51 AND key='approve'$c$, 'eq', '2', 'P3'),
(51, 52, 'a reason under 10 characters is REFUSED (the house note-length rule)',
 $c$SELECT value->>'thin_reason' FROM golden.scratch WHERE fixture_id=51 AND key='approve'$c$, 'eq', 'REFUSED', 'P3'),
(51, 53, 'approving a pipeline run that does not exist is REFUSED, not silently ignored',
 $c$SELECT value->>'unknown_run' FROM golden.scratch WHERE fixture_id=51 AND key='approve'$c$, 'eq', 'REFUSED', 'P3'),

-- ============================ APPEND-ONLY ===============================
(51, 45, 'DELETE on the receipt ledger is REFUSED',
 $c$SELECT value->>'delete' FROM golden.scratch WHERE fixture_id=51 AND key='guards'$c$, 'eq', 'REFUSED', 'P3'),
(51, 46, 'rewriting a recorded plan_date is REFUSED',
 $c$SELECT value->>'update_core' FROM golden.scratch WHERE fixture_id=51 AND key='guards'$c$, 'eq', 'REFUSED', 'P3'),
(51, 47, 'un-approving by direct UPDATE is REFUSED -- an approval is an event, not a toggle',
 $c$SELECT value->>'unapprove' FROM golden.scratch WHERE fixture_id=51 AND key='guards'$c$, 'eq', 'REFUSED', 'P3'),
(51, 48, 'S-108: TRUNCATE is REFUSED too -- the one operation a row-level trigger never sees',
 $c$SELECT value->>'truncate' FROM golden.scratch WHERE fixture_id=51 AND key='guards'$c$, 'eq', 'REFUSED', 'P3'),

-- ============================ TRIPWIRES =================================
(51, 49, 'LAW 4: no live refill_plan_output row exists on the fixture date, approval notwithstanding',
 $c$SELECT (value->>'live_rpo_on_date') FROM golden.scratch WHERE fixture_id=51 AND key='tripwires'$c$, 'eq', '0', 'P3'),
(51, 50, 'LAW 4: no live pod_refills row exists on the fixture date either',
 $c$SELECT (value->>'pod_refills_on_date') FROM golden.scratch WHERE fixture_id=51 AND key='tripwires'$c$, 'eq', '0', 'P3'),
(51, 51, 'LAW 11: the Gate-0 queue is untouched at 1240',
 $c$SELECT (value->>'machines_to_visit') FROM golden.scratch WHERE fixture_id=51 AND key='tripwires'$c$, 'eq', '1240', 'P3');
