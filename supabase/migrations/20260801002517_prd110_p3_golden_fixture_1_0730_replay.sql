-- PRD-110 · GOLDEN FIXTURE 1 — "VOX Spider-Man full replay" (the 07-30 session)
-- LAW 1: the fixture lands FIRST and its first run is recorded whatever colour it is.
--
-- Two halves, deliberately:
--   (A) HISTORICAL TRUTH — read-only assertions over the REAL live 2026-07-30 plan.
--       This is the incident itself: 71 lines, 64 dispatched, K&Z REMOVE resolved,
--       zero silent qty-0, the coconut ABSENCE. Nothing is written to that date.
--   (B) MECHANISM — the same nine-edit shape replayed through the v3 verbs on the
--       synthetic 2030-01-02 date: base run -> 9 edits -> compose -> stitch ->
--       approve -> engine re-run. Proves the edits survive a re-run while the
--       UNLOCKED lines still follow the engine.
--
-- ⛔ The v3 shadow vocabulary has NO 'Remove' action (refill_plan_output_shadow.action
--    is Refill / Add New / Blocked). The live A04 REMOVE is asserted as historical
--    truth in half (A); its v3 analogue in half (B) is a `drop` edit. The two are
--    asserted separately and are NOT conflated.

SET LOCAL statement_timeout = '300s';

DELETE FROM golden.assertions WHERE fixture_id = 1;
DELETE FROM golden.fixtures   WHERE fixture_id = 1;

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, baseline_status, enabled, notes, scenario_sql)
VALUES (
  1,
  'VOX Spider-Man full replay — 8 machines, 9 CS edits, approve, stitch',
  '2026-07-30 session (the PRD-110 founding incident)',
  'P3',
  DATE '2030-01-02',
  'unknown',
  true,
  'Half A asserts the real 07-30 plan read-only (64 dispatched rows, K&Z REMOVE resolved, coconut absent, 0 qty-0). Half B replays the nine-edit shape on 2030-01-02 through record_plan_edit_v3 -> run_pipeline_v3 -> approve_pipeline_run_v3, then re-runs the engine to prove hard edits survive while unlocked lines still move. All anchors are real shelves on the real machines of that session. ARTICLE 16 NOTE (Cody, leg 78): half A counts dispatched-vs-planned lines inline, which is adjacent to the registered metric "Refill execution accuracy" (v_refill_accuracy). That is deliberate and is NOT an illegal copy - a test oracle that read the canonical object would be asserting that object against itself. Do not "fix" this by rewiring it to v_refill_accuracy.',
$scenario$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- ---------------------------------------------------------------------------
-- (0) ANCHORS. Every uuid below is a REAL shelf/pod on a REAL machine that took
--     part in the 2026-07-30 session. Nothing here is a synthetic stand-in.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'anchors', jsonb_build_object(
  'E1_coconut_shelf','f0ebe768-d86c-481c-ab46-a361bd9535ba','E1_pod','9563f848-c123-499d-a8c3-039b693bf817',
  'E2_shelf','227ae9b5-7abb-4022-8533-ac98cded5c26',
  'E3_shelf','11d77651-ac83-4cd8-83f1-cf3117c21ac7',
  'E4_shelf','6f7c0d4b-8971-476f-ab8e-32b5a8ed5e23',
  'nutella_pod','7998f596-3cb3-45ea-81d2-2eb1fe1eded9',
  'E5_zigi_shelf','6d69c76c-9592-47c9-898b-25bd5bf6d4b6','E5_pod','da115e6f-8d9b-48ab-b998-531cb81d3faa',
  'A04_shelf','677aa6d8-475c-45ff-abd6-d42a14b41b3a',
  'E6_kz_pod','098f5c0c-28b1-46c3-869a-2da87297c4d5',
  'E7_tamreem_pod','acde9e53-d5aa-4b39-bcfb-b7bda4f2cd66',
  'E8_shelf','2b10662c-4830-4094-a33b-8858fa59de6b',
  'E9_shelf','86b91c23-eac9-4351-ad66-cc1ae333cb7c','E9_pod','ef8f3ea9-f121-4f8c-a4e6-6f9d0a39f239',
  'C1_shelf','65d699ab-441c-43e7-9a5d-bbd90d0da08e',
  'C2_shelf','70d9ca73-d690-4439-b568-53e3d169e9f0',
  'C3_shelf','07028f3a-b7f6-45a6-b2ac-e7ca44fae727',
  'C4_amz_shelf','3c03c14f-1cfb-4831-9470-4b086e4e6e51');

-- ---------------------------------------------------------------------------
-- (1) STRUCTURAL PROBES. All guarded (S-101/S-107): a missing verb becomes data.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb := '{}'::jsonb; t text;
BEGIN
  v := v || jsonb_build_object('editor',
    COALESCE(to_regprocedure('public.record_plan_edit_v3(date,uuid,uuid,text,integer,text,text)')::text,'absent'));
  v := v || jsonb_build_object('composer',
    COALESCE(to_regprocedure('public.compose_plan_with_edits_v3(date,uuid)')::text,'absent'));
  v := v || jsonb_build_object('runner',
    COALESCE(to_regprocedure('public.run_pipeline_v3(date,integer,uuid,boolean,text)')::text,'absent'));
  v := v || jsonb_build_object('approver',
    COALESCE(to_regprocedure('public.approve_pipeline_run_v3(uuid,text)')::text,'absent'));

  SELECT string_agg(conname,' | ' ORDER BY conname) INTO t
    FROM pg_constraint WHERE conrelid = 'public.pod_refills_shadow'::regclass AND contype='c';
  v := v || jsonb_build_object('shadow_checks', COALESCE(t,'none'));

  SELECT string_agg(indexname,' | ' ORDER BY indexname) INTO t
    FROM pg_indexes WHERE schemaname='public' AND tablename='plan_edits_v3';
  v := v || jsonb_build_object('edit_indexes', COALESCE(t,'none'));

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (1, 'struct', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (2) HALF A — THE INCIDENT ITSELF, READ ONLY.
--     ⛔ LAW 12: this block only SELECTs from the live 2026-07-30 date.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'hist', jsonb_build_object(
  'lines',        (SELECT count(*) FROM public.refill_plan_output WHERE plan_date = DATE '2026-07-30'),
  'dispatched',   (SELECT count(*) FROM public.refill_plan_output WHERE plan_date = DATE '2026-07-30' AND dispatched),
  'machines',     (SELECT count(DISTINCT machine_name) FROM public.refill_plan_output WHERE plan_date = DATE '2026-07-30'),
  'qty_zero',     (SELECT count(*) FROM public.refill_plan_output WHERE plan_date = DATE '2026-07-30' AND COALESCE(quantity,0) = 0),
  'not_approved', (SELECT count(*) FROM public.refill_plan_output WHERE plan_date = DATE '2026-07-30' AND COALESCE(operator_status,'') <> 'approved'),
  -- the K&Z REMOVE: it existed, and it was RESOLVED (it reached dispatch)
  'kz_remove_lines', (SELECT count(*) FROM public.refill_plan_output
                       WHERE plan_date = DATE '2026-07-30' AND action = 'Remove'
                         AND pod_product_name = 'Krambals & Zigi' AND shelf_code = 'A04'),
  'kz_remove_dispatched', (SELECT count(*) FROM public.refill_plan_output
                       WHERE plan_date = DATE '2026-07-30' AND action = 'Remove'
                         AND pod_product_name = 'Krambals & Zigi' AND shelf_code = 'A04' AND dispatched),
  -- A04 ADD_NEW, the other half of the same shelf decision
  'a04_addnew_units', (SELECT COALESCE(SUM(quantity),0) FROM public.refill_plan_output
                       WHERE plan_date = DATE '2026-07-30' AND action = 'Add New'
                         AND pod_product_name = 'Tamreem Date Ball' AND dispatched),
  -- the three CS numbers that must be reproducible to the unit
  'nutella_1054_units', (SELECT COALESCE(SUM(quantity),0) FROM public.refill_plan_output
                       WHERE plan_date = DATE '2026-07-30' AND machine_name = 'MPMCC-1054-0000-M0' AND dispatched),
  'vw_a05_units',       (SELECT COALESCE(SUM(quantity),0) FROM public.refill_plan_output
                       WHERE plan_date = DATE '2026-07-30' AND machine_name = 'ACTIVATEMCC-1037-0000-L0'
                         AND shelf_code = 'A05' AND dispatched),
  'zigi_a02_units',     (SELECT COALESCE(SUM(quantity),0) FROM public.refill_plan_output
                       WHERE plan_date = DATE '2026-07-30' AND machine_name = 'VOXMCC-1011-0101-B0'
                         AND shelf_code = 'A02' AND dispatched),
  -- ⭐ THE COCONUT STOP IS AN ABSENCE (S-114): assert the hole, not a value
  'coconut_lines',      (SELECT count(*) FROM public.refill_plan_output
                       WHERE plan_date = DATE '2026-07-30' AND pod_product_name ILIKE '%coconut%'),
  -- ⭐ tripwire BASELINES, taken at the START of the scenario. The matching
  --    readings in block (8) are compared to THESE, never to a magic number:
  --    a fixture pinned to ambient fleet state goes red for reasons that have
  --    nothing to do with the incident (Cody, Article 16 review).
  'mtv_before',         (SELECT count(*) FROM public.machines_to_visit));

-- ---------------------------------------------------------------------------
-- (3) HALF B — BASE ENGINE RUN R1. Ten lines over SIX machines; the remaining
--     two of the eight arrive only through the human's ADD edits, which is
--     exactly what happened on 07-30.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'r1', to_jsonb(gen_random_uuid());

INSERT INTO public.pod_refills_shadow
  (run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id, qty,
   availability_basis, wh_available_pod)
SELECT ((SELECT value FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key='r1') #>> '{}')::uuid,
       'engine_add_pod_v3', {{plan_date}}, a.mid, a.sid, a.pid, a.qty, 'boonz_wh', 0
FROM (VALUES
  -- edited shelves
  ('4b235d37-c388-478b-8f3f-49d50971fcc1'::uuid,'f0ebe768-d86c-481c-ab46-a361bd9535ba'::uuid,'9563f848-c123-499d-a8c3-039b693bf817'::uuid, 5),  -- E1 coconut
  ('148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,'227ae9b5-7abb-4022-8533-ac98cded5c26'::uuid,'7998f596-3cb3-45ea-81d2-2eb1fe1eded9'::uuid, 3),  -- E2 nutella
  ('b9f0c828-bcd1-493a-ac28-934f5dba0872'::uuid,'11d77651-ac83-4cd8-83f1-cf3117c21ac7'::uuid,'7998f596-3cb3-45ea-81d2-2eb1fe1eded9'::uuid, 3),  -- E3 nutella
  ('4b235d37-c388-478b-8f3f-49d50971fcc1'::uuid,'6f7c0d4b-8971-476f-ab8e-32b5a8ed5e23'::uuid,'7998f596-3cb3-45ea-81d2-2eb1fe1eded9'::uuid, 3),  -- E4 nutella target
  ('b9f0c828-bcd1-493a-ac28-934f5dba0872'::uuid,'6d69c76c-9592-47c9-898b-25bd5bf6d4b6'::uuid,'da115e6f-8d9b-48ab-b998-531cb81d3faa'::uuid,10),  -- E5 zigi 10
  ('bb9578ea-9aba-404e-881d-ea239f8609ce'::uuid,'677aa6d8-475c-45ff-abd6-d42a14b41b3a'::uuid,'098f5c0c-28b1-46c3-869a-2da87297c4d5'::uuid, 3),  -- E6 K&Z
  -- untouched controls
  ('9acce2bf-0e65-48f4-bf44-cefa0326f2c5'::uuid,'65d699ab-441c-43e7-9a5d-bbd90d0da08e'::uuid,'a602c923-c4c0-4ecc-b5f7-3c13a1960beb'::uuid, 7),  -- C1 red bull
  ('148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,'70d9ca73-d690-4439-b568-53e3d169e9f0'::uuid,'4901aaf4-a2f4-4d62-a089-d68178aa6c7f'::uuid, 4),  -- C2 pepsi black
  ('bb9578ea-9aba-404e-881d-ea239f8609ce'::uuid,'07028f3a-b7f6-45a6-b2ac-e7ca44fae727'::uuid,'11b11bda-d277-4ab0-8105-595a209750ce'::uuid, 4),  -- C3 aquafina
  ('f1a528fb-15e8-4f20-b4e2-ebb2e6852198'::uuid,'3c03c14f-1cfb-4831-9470-4b086e4e6e51'::uuid,'7998f596-3cb3-45ea-81d2-2eb1fe1eded9'::uuid, 6)   -- C4 AMZ (8th machine)
) AS a(mid,sid,pid,qty);

-- ---------------------------------------------------------------------------
-- (4) THE NINE CS EDITS, each through the P3.6 writer, each with its real reason.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb := '{}'::jsonb; r jsonb; n int := 0;
BEGIN
  IF to_regprocedure('public.record_plan_edit_v3(date,uuid,uuid,text,integer,text,text)') IS NOT NULL THEN

    BEGIN  -- 1. the coconut stop
      SELECT public.record_plan_edit_v3(DATE '2030-01-02',
        'f0ebe768-d86c-481c-ab46-a361bd9535ba','9563f848-c123-499d-a8c3-039b693bf817',
        'drop', NULL, 'hard', 'Stop Tender Coconut Water on 2005 A05 - it is not moving') INTO r;
      v := v || jsonb_build_object('e1', r->>'status'); n := n + 1;
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('e1','THREW: '||SQLERRM); END;

    BEGIN  -- 2. Nutella consolidation, leg 1 of 3
      SELECT public.record_plan_edit_v3(DATE '2030-01-02',
        '227ae9b5-7abb-4022-8533-ac98cded5c26','7998f596-3cb3-45ea-81d2-2eb1fe1eded9',
        'drop', NULL, 'hard', 'Consolidate Nutella onto one shelf - drop the 1005 A15 leg') INTO r;
      v := v || jsonb_build_object('e2', r->>'status'); n := n + 1;
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('e2','THREW: '||SQLERRM); END;

    BEGIN  -- 3. Nutella consolidation, leg 2 of 3
      SELECT public.record_plan_edit_v3(DATE '2030-01-02',
        '11d77651-ac83-4cd8-83f1-cf3117c21ac7','7998f596-3cb3-45ea-81d2-2eb1fe1eded9',
        'drop', NULL, 'hard', 'Consolidate Nutella onto one shelf - drop the 1011 A16 leg') INTO r;
      v := v || jsonb_build_object('e3', r->>'status'); n := n + 1;
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('e3','THREW: '||SQLERRM); END;

    BEGIN  -- 4. Nutella consolidation, leg 3 of 3: the survivor absorbs all three
      SELECT public.record_plan_edit_v3(DATE '2030-01-02',
        '6f7c0d4b-8971-476f-ab8e-32b5a8ed5e23','7998f596-3cb3-45ea-81d2-2eb1fe1eded9',
        'set_qty', 9, 'hard', 'Consolidated Nutella lands on 2005 B08 at nine units') INTO r;
      v := v || jsonb_build_object('e4', r->>'status'); n := n + 1;
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('e4','THREW: '||SQLERRM); END;

    BEGIN  -- 5. Zigi 10 -> 7
      SELECT public.record_plan_edit_v3(DATE '2030-01-02',
        '6d69c76c-9592-47c9-898b-25bd5bf6d4b6','da115e6f-8d9b-48ab-b998-531cb81d3faa',
        'set_qty', 7, 'hard', 'Zigi cut from ten to seven on 1011 A02 - warehouse cover') INTO r;
      v := v || jsonb_build_object('e5', r->>'status'); n := n + 1;
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('e5','THREW: '||SQLERRM); END;

    BEGIN  -- 6. A04 REMOVE (v3 analogue of the live Remove action)
      SELECT public.record_plan_edit_v3(DATE '2030-01-02',
        '677aa6d8-475c-45ff-abd6-d42a14b41b3a','098f5c0c-28b1-46c3-869a-2da87297c4d5',
        'drop', NULL, 'hard', 'Krambals and Zigi comes off 1013 A04 entirely') INTO r;
      v := v || jsonb_build_object('e6', r->>'status'); n := n + 1;
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('e6','THREW: '||SQLERRM); END;

    BEGIN  -- 7. A04 ADD_NEW, the same shelf, a different pod
      SELECT public.record_plan_edit_v3(DATE '2030-01-02',
        '677aa6d8-475c-45ff-abd6-d42a14b41b3a','acde9e53-d5aa-4b39-bcfb-b7bda4f2cd66',
        'add', 8, 'hard', 'Tamreem Date Ball takes over 1013 A04 with eight units') INTO r;
      v := v || jsonb_build_object('e7', r->>'status'); n := n + 1;
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('e7','THREW: '||SQLERRM); END;

    BEGIN  -- 8. 1054 Nutella +3 (a machine the engine never planned at all)
      SELECT public.record_plan_edit_v3(DATE '2030-01-02',
        '2b10662c-4830-4094-a33b-8858fa59de6b','7998f596-3cb3-45ea-81d2-2eb1fe1eded9',
        'add', 3, 'hard', 'MPMCC-1054 A03 needs three Nutella - engine missed the machine') INTO r;
      v := v || jsonb_build_object('e8', r->>'status'); n := n + 1;
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('e8','THREW: '||SQLERRM); END;

    BEGIN  -- 9. VW A05 0 -> 6 (the engine planned nothing here either)
      SELECT public.record_plan_edit_v3(DATE '2030-01-02',
        '86b91c23-eac9-4351-ad66-cc1ae333cb7c','ef8f3ea9-f121-4f8c-a4e6-6f9d0a39f239',
        'add', 6, 'hard', 'Vitamin Well on 1037 A05 goes from zero to six units') INTO r;
      v := v || jsonb_build_object('e9', r->>'status'); n := n + 1;
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('e9','THREW: '||SQLERRM); END;

  END IF;
  v := v || jsonb_build_object('accepted', n);
  v := v || jsonb_build_object('live_edit_rows',
    (SELECT count(*) FROM public.plan_edits_v3 WHERE plan_date = DATE '2030-01-02' AND superseded_at IS NULL));
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (1, 'edits', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (5) PIPELINE RUN 1: compose the nine edits over R1, then stitch.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb; rows jsonb;
BEGIN
  IF to_regprocedure('public.run_pipeline_v3(date,integer,uuid,boolean,text)') IS NOT NULL THEN
    BEGIN
      EXECUTE $x$ SELECT public.run_pipeline_v3(DATE '2030-01-02', 14,
        ((SELECT value FROM golden.scratch WHERE fixture_id = 1 AND key='r1') #>> '{}')::uuid,
        false, 'golden fixture 1 - the 07-30 nine-edit replay, run 1') $x$ INTO v;
    EXCEPTION WHEN OTHERS THEN
      v := jsonb_build_object('status','THREW: '||SQLERRM,'sqlstate',SQLSTATE);
    END;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (1, 'p1', v);

    EXECUTE $x$ SELECT COALESCE(jsonb_object_agg(shelf_id::text||':'||pod_product_id::text, qty),'{}'::jsonb)
                  FROM public.pod_refills_shadow WHERE run_id = $1 $x$
      INTO rows USING (v->>'planned_run_id')::uuid;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (1, 'p1_composed', rows);

    EXECUTE $x$ SELECT jsonb_build_object(
        'lines',    (SELECT count(*)                FROM public.pod_refills_shadow WHERE run_id = $1),
        'units',    (SELECT COALESCE(SUM(qty),0)    FROM public.pod_refills_shadow WHERE run_id = $1),
        'machines', (SELECT count(DISTINCT machine_id) FROM public.pod_refills_shadow WHERE run_id = $1),
        'silent_zero', (SELECT count(*) FROM public.pod_refills_shadow
                          WHERE run_id = $1 AND qty = 0 AND clamp_reason IS NULL)) $x$
      INTO rows USING (v->>'planned_run_id')::uuid;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (1, 'p1_shape', rows);

    EXECUTE $x$ SELECT COALESCE(jsonb_object_agg(shelf_id::text, q),'{}'::jsonb) FROM (
        SELECT shelf_id, SUM(qty)::int AS q FROM public.refill_plan_output_shadow
         WHERE run_id = $1 GROUP BY shelf_id) z $x$
      INTO rows USING (v#>>'{stitch,run_id}')::uuid;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (1, 'p1_stitched', rows);
  ELSE
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (1,'p1','"absent"'::jsonb);
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (1,'p1_composed','"absent"'::jsonb);
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (1,'p1_shape','"absent"'::jsonb);
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (1,'p1_stitched','"absent"'::jsonb);
  END IF;
END
$do$;

-- ---------------------------------------------------------------------------
-- (6) THE ENGINE RE-RUN. R2 moves SIX of the ten base numbers, including both
--     hard-edited shelves and one untouched control. The hard edits must hold
--     at 9 and 7; the control MUST move to 9 -- an engine frozen wholesale would
--     be just as wrong as one that trampled the human.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'r2', to_jsonb(gen_random_uuid());

INSERT INTO public.pod_refills_shadow
  (run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id, qty,
   availability_basis, wh_available_pod)
SELECT ((SELECT value FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key='r2') #>> '{}')::uuid,
       'engine_add_pod_v3', {{plan_date}}, a.mid, a.sid, a.pid, a.qty, 'boonz_wh', 0
FROM (VALUES
  ('4b235d37-c388-478b-8f3f-49d50971fcc1'::uuid,'f0ebe768-d86c-481c-ab46-a361bd9535ba'::uuid,'9563f848-c123-499d-a8c3-039b693bf817'::uuid, 6),  -- E1 re-proposed
  ('148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,'227ae9b5-7abb-4022-8533-ac98cded5c26'::uuid,'7998f596-3cb3-45ea-81d2-2eb1fe1eded9'::uuid, 4),  -- E2 moved
  ('b9f0c828-bcd1-493a-ac28-934f5dba0872'::uuid,'11d77651-ac83-4cd8-83f1-cf3117c21ac7'::uuid,'7998f596-3cb3-45ea-81d2-2eb1fe1eded9'::uuid, 4),  -- E3 moved
  ('4b235d37-c388-478b-8f3f-49d50971fcc1'::uuid,'6f7c0d4b-8971-476f-ab8e-32b5a8ed5e23'::uuid,'7998f596-3cb3-45ea-81d2-2eb1fe1eded9'::uuid, 5),  -- E4 3 -> 5
  ('b9f0c828-bcd1-493a-ac28-934f5dba0872'::uuid,'6d69c76c-9592-47c9-898b-25bd5bf6d4b6'::uuid,'da115e6f-8d9b-48ab-b998-531cb81d3faa'::uuid,12),  -- E5 10 -> 12
  ('bb9578ea-9aba-404e-881d-ea239f8609ce'::uuid,'677aa6d8-475c-45ff-abd6-d42a14b41b3a'::uuid,'098f5c0c-28b1-46c3-869a-2da87297c4d5'::uuid, 4),  -- E6 moved
  ('9acce2bf-0e65-48f4-bf44-cefa0326f2c5'::uuid,'65d699ab-441c-43e7-9a5d-bbd90d0da08e'::uuid,'a602c923-c4c0-4ecc-b5f7-3c13a1960beb'::uuid, 9),  -- C1 7 -> 9 (unlocked)
  ('148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,'70d9ca73-d690-4439-b568-53e3d169e9f0'::uuid,'4901aaf4-a2f4-4d62-a089-d68178aa6c7f'::uuid, 4),
  ('bb9578ea-9aba-404e-881d-ea239f8609ce'::uuid,'07028f3a-b7f6-45a6-b2ac-e7ca44fae727'::uuid,'11b11bda-d277-4ab0-8105-595a209750ce'::uuid, 4),
  ('f1a528fb-15e8-4f20-b4e2-ebb2e6852198'::uuid,'3c03c14f-1cfb-4831-9470-4b086e4e6e51'::uuid,'7998f596-3cb3-45ea-81d2-2eb1fe1eded9'::uuid, 6)
) AS a(mid,sid,pid,qty);

DO $do$
DECLARE v jsonb; rows jsonb;
BEGIN
  IF to_regprocedure('public.run_pipeline_v3(date,integer,uuid,boolean,text)') IS NOT NULL THEN
    BEGIN
      EXECUTE $x$ SELECT public.run_pipeline_v3(DATE '2030-01-02', 14,
        ((SELECT value FROM golden.scratch WHERE fixture_id = 1 AND key='r2') #>> '{}')::uuid,
        false, 'golden fixture 1 - engine re-run over the same nine edits') $x$ INTO v;
    EXCEPTION WHEN OTHERS THEN
      v := jsonb_build_object('status','THREW: '||SQLERRM,'sqlstate',SQLSTATE);
    END;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (1, 'p2', v);

    EXECUTE $x$ SELECT COALESCE(jsonb_object_agg(shelf_id::text||':'||pod_product_id::text, qty),'{}'::jsonb)
                  FROM public.pod_refills_shadow WHERE run_id = $1 $x$
      INTO rows USING (v->>'planned_run_id')::uuid;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (1, 'p2_composed', rows);

    -- the pipeline must never rewrite the base run it was handed
    EXECUTE $x$ SELECT COALESCE(jsonb_object_agg(shelf_id::text, qty),'{}'::jsonb)
                  FROM public.pod_refills_shadow WHERE run_id =
      ((SELECT value FROM golden.scratch WHERE fixture_id = 1 AND key='r2') #>> '{}')::uuid $x$ INTO rows;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (1, 'r2_after', rows);
  ELSE
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (1,'p2','"absent"'::jsonb);
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (1,'p2_composed','"absent"'::jsonb);
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (1,'r2_after','"absent"'::jsonb);
  END IF;
END
$do$;

-- ---------------------------------------------------------------------------
-- (7) APPROVE. CS signs the re-run plan off; exactly one approval may stand.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb := '{}'::jsonb; r jsonb; n int; p2 uuid;
BEGIN
  IF to_regprocedure('public.approve_pipeline_run_v3(uuid,text)') IS NOT NULL THEN
    SELECT (value->>'pipeline_run_id')::uuid INTO p2 FROM golden.scratch WHERE fixture_id=1 AND key='p2';
    BEGIN
      EXECUTE $x$ SELECT public.approve_pipeline_run_v3($1,
        'CS approves the 07-30 replay plan with all nine edits intact') $x$ INTO r USING p2;
      v := v || jsonb_build_object('approve', r->>'status');
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('approve','THREW: '||SQLERRM); END;

    BEGIN
      EXECUTE $x$ SELECT public.approve_pipeline_run_v3($1,
        'CS approves the very same run a second time') $x$ INTO r USING p2;
      v := v || jsonb_build_object('double_approve','ACCEPTED');
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('double_approve','REFUSED'); END;

    EXECUTE $x$ SELECT count(*)::int FROM public.pipeline_runs_v3
                 WHERE plan_date = DATE '2030-01-02'
                   AND approved_at IS NOT NULL AND approval_superseded_at IS NULL $x$ INTO n;
    v := v || jsonb_build_object('standing', n);
  ELSE
    v := jsonb_build_object('approve','absent','double_approve','absent','standing','absent');
  END IF;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (1, 'approve', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (8) LIVE TRIPWIRES. LAW 4 / LAW 12: a full replay that ends in an approval
--     must still have moved nothing live -- including the incident date it read.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'tripwires', jsonb_build_object(
  'live_rpo_on_fixture_date', (SELECT count(*) FROM public.refill_plan_output WHERE plan_date = {{plan_date}}),
  'live_pod_refills_on_date', (SELECT count(*) FROM public.pod_refills        WHERE plan_date = {{plan_date}}),
  'machines_to_visit',        (SELECT count(*) FROM public.machines_to_visit),
  'incident_date_rows',       (SELECT count(*) FROM public.refill_plan_output WHERE plan_date = DATE '2026-07-30'));
$scenario$
);

-- ===========================================================================
-- ASSERTIONS
-- ===========================================================================
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required) VALUES

-- ---- structural -----------------------------------------------------------
(1, 1,'record_plan_edit_v3 exists at the specified signature',
 $$SELECT value->>'editor' FROM golden.scratch WHERE fixture_id=1 AND key='struct'$$,'contains','record_plan_edit_v3','P3'),
(1, 2,'compose_plan_with_edits_v3 exists at the specified signature',
 $$SELECT value->>'composer' FROM golden.scratch WHERE fixture_id=1 AND key='struct'$$,'contains','compose_plan_with_edits_v3','P3'),
(1, 3,'run_pipeline_v3 exists at the specified signature',
 $$SELECT value->>'runner' FROM golden.scratch WHERE fixture_id=1 AND key='struct'$$,'contains','run_pipeline_v3','P3'),
(1, 4,'approve_pipeline_run_v3 exists at the specified signature',
 $$SELECT value->>'approver' FROM golden.scratch WHERE fixture_id=1 AND key='struct'$$,'contains','approve_pipeline_run_v3','P3'),
(1, 5,'LAW 5 IS ENCODED IN THE SCHEMA: a qty-0 shadow row is legal only with a clamp reason',
 $$SELECT value->>'shadow_checks' FROM golden.scratch WHERE fixture_id=1 AND key='struct'$$,'contains','no_silent_zero','P3'),
(1, 6,'one active edit per (date, shelf, pod) is structural, not writer discipline',
 $$SELECT value->>'edit_indexes' FROM golden.scratch WHERE fixture_id=1 AND key='struct'$$,'contains','ux_plan_edits_v3_active','P3'),

-- ---- HALF A: the incident, read-only --------------------------------------
(1,10,'THE INCIDENT: the live 2026-07-30 plan carried 71 lines',
 $$SELECT value->>'lines' FROM golden.scratch WHERE fixture_id=1 AND key='hist'$$,'eq','71','P3'),
(1,11,'THE GATE NUMBER: exactly 64 of those lines reached dispatch',
 $$SELECT value->>'dispatched' FROM golden.scratch WHERE fixture_id=1 AND key='hist'$$,'eq','64','P3'),
(1,12,'seven machines carried plan lines (the eighth, AMZ, was dropped mid-plan - fixture 11)',
 $$SELECT value->>'machines' FROM golden.scratch WHERE fixture_id=1 AND key='hist'$$,'eq','7','P3'),
(1,13,'LAW 5 ON THE REAL INCIDENT: not one silent qty-0 line in the whole session',
 $$SELECT value->>'qty_zero' FROM golden.scratch WHERE fixture_id=1 AND key='hist'$$,'eq','0','P3'),
(1,14,'every line of the session was operator-approved - nothing slipped through unreviewed',
 $$SELECT value->>'not_approved' FROM golden.scratch WHERE fixture_id=1 AND key='hist'$$,'eq','0','P3'),
(1,15,'the K&Z REMOVE on 1013 A04 existed',
 $$SELECT value->>'kz_remove_lines' FROM golden.scratch WHERE fixture_id=1 AND key='hist'$$,'eq','1','P3'),
(1,16,'K&Z REMOVE RESOLVED: the Remove leg reached dispatch rather than stalling',
 $$SELECT value->>'kz_remove_dispatched' FROM golden.scratch WHERE fixture_id=1 AND key='hist'$$,'eq','1','P3'),
(1,17,'the other half of the A04 decision shipped too: 8 Tamreem Date Ball units ADD_NEW',
 $$SELECT value->>'a04_addnew_units' FROM golden.scratch WHERE fixture_id=1 AND key='hist'$$,'eq','8','P3'),
(1,18,'the 1054 Nutella edit shipped exactly three units',
 $$SELECT value->>'nutella_1054_units' FROM golden.scratch WHERE fixture_id=1 AND key='hist'$$,'eq','3','P3'),
(1,19,'the VW A05 0->6 edit shipped exactly six units',
 $$SELECT value->>'vw_a05_units' FROM golden.scratch WHERE fixture_id=1 AND key='hist'$$,'eq','6','P3'),
(1,20,'the Zigi 10->7 edit shipped exactly seven units',
 $$SELECT value->>'zigi_a02_units' FROM golden.scratch WHERE fixture_id=1 AND key='hist'$$,'eq','7','P3'),
(1,21,'THE COCONUT STOP IS AN ABSENCE (S-114): no coconut line survived anywhere in the session',
 $$SELECT value->>'coconut_lines' FROM golden.scratch WHERE fixture_id=1 AND key='hist'$$,'eq','0','P3'),

-- ---- HALF B: the nine edits through the v3 verbs ---------------------------
(1,30,'all nine CS edits were accepted by the writer',
 $$SELECT value->>'accepted' FROM golden.scratch WHERE fixture_id=1 AND key='edits'$$,'eq','9','P3'),
(1,31,'and all nine are live and unsuperseded on the plan date',
 $$SELECT value->>'live_edit_rows' FROM golden.scratch WHERE fixture_id=1 AND key='edits'$$,'eq','9','P3'),
(1,32,'the pipeline ran to completion',
 $$SELECT value->>'status' FROM golden.scratch WHERE fixture_id=1 AND key='p1'$$,'eq','ok','P3'),
(1,33,'the base was the SUPPLIED engine run, and the pipeline says so rather than leaving it inferred',
 $$SELECT value->>'base_source' FROM golden.scratch WHERE fixture_id=1 AND key='p1'$$,'eq','supplied','P3'),
(1,34,'the pipeline composed the edits rather than skipping to stitch',
 $$SELECT COALESCE((SELECT value#>>'{compose,status}' FROM golden.scratch WHERE fixture_id=1 AND key='p1'),'absent')$$,'eq','ok','P3'),
(1,35,'all nine edits were considered',
 $$SELECT COALESCE((SELECT value#>>'{compose,edits_considered}' FROM golden.scratch WHERE fixture_id=1 AND key='p1'),'absent')$$,'eq','9','P3'),
(1,36,'all nine applied on the first pass - none yielded, none silently lost',
 $$SELECT COALESCE((SELECT value#>>'{compose,edits_applied}' FROM golden.scratch WHERE fixture_id=1 AND key='p1'),'absent')$$,'eq','9','P3'),
(1,37,'THE PIN: stitch was handed the COMPOSED run, explicitly, not left to guess',
 $$SELECT COALESCE((SELECT ((value->>'planned_run_id') = (value#>>'{compose,run_id}'))::text
     FROM golden.scratch WHERE fixture_id=1 AND key='p1'),'absent')$$,'eq','true','P3'),
(1,38,'...and stitch confirms from its own return value that it consumed exactly that run',
 $$SELECT COALESCE((SELECT ((value#>>'{stitch,source_run_id}') = (value->>'planned_run_id'))::text
     FROM golden.scratch WHERE fixture_id=1 AND key='p1'),'absent')$$,'eq','true','P3'),
(1,39,'the composed plan carries nine lines: ten base minus four drops plus three human adds',
 $$SELECT value->>'lines' FROM golden.scratch WHERE fixture_id=1 AND key='p1_shape'$$,'eq','9','P3'),
(1,40,'the composed plan carries 54 units',
 $$SELECT value->>'units' FROM golden.scratch WHERE fixture_id=1 AND key='p1_shape'$$,'eq','54','P3'),
(1,41,'ALL EIGHT MACHINES of the session are represented - two arrive only via human ADD edits',
 $$SELECT value->>'machines' FROM golden.scratch WHERE fixture_id=1 AND key='p1_shape'$$,'eq','8','P3'),
(1,42,'ZERO SILENT QTY-0 in the composed plan (LAW 5)',
 $$SELECT value->>'silent_zero' FROM golden.scratch WHERE fixture_id=1 AND key='p1_shape'$$,'eq','0','P3'),
(1,43,'consolidation target: 2005 B08 Nutella carries the consolidated nine',
 $$SELECT COALESCE((SELECT value->>'6f7c0d4b-8971-476f-ab8e-32b5a8ed5e23:7998f596-3cb3-45ea-81d2-2eb1fe1eded9'
     FROM golden.scratch WHERE fixture_id=1 AND key='p1_composed'),'absent')$$,'eq','9','P3'),
(1,44,'Zigi on 1011 A02 is the human seven, not the engine ten',
 $$SELECT COALESCE((SELECT value->>'6d69c76c-9592-47c9-898b-25bd5bf6d4b6:da115e6f-8d9b-48ab-b998-531cb81d3faa'
     FROM golden.scratch WHERE fixture_id=1 AND key='p1_composed'),'absent')$$,'eq','7','P3'),
(1,45,'A04 ADD_NEW: Tamreem Date Ball exists at eight on a shelf the engine gave to another pod',
 $$SELECT COALESCE((SELECT value->>'677aa6d8-475c-45ff-abd6-d42a14b41b3a:acde9e53-d5aa-4b39-bcfb-b7bda4f2cd66'
     FROM golden.scratch WHERE fixture_id=1 AND key='p1_composed'),'absent')$$,'eq','8','P3'),
(1,46,'1054 Nutella +3 reached the plan although the engine never planned that machine',
 $$SELECT COALESCE((SELECT value->>'2b10662c-4830-4094-a33b-8858fa59de6b:7998f596-3cb3-45ea-81d2-2eb1fe1eded9'
     FROM golden.scratch WHERE fixture_id=1 AND key='p1_composed'),'absent')$$,'eq','3','P3'),
(1,47,'VW A05 0->6 reached the plan from a standing start',
 $$SELECT COALESCE((SELECT value->>'86b91c23-eac9-4351-ad66-cc1ae333cb7c:ef8f3ea9-f121-4f8c-a4e6-6f9d0a39f239'
     FROM golden.scratch WHERE fixture_id=1 AND key='p1_composed'),'absent')$$,'eq','6','P3'),
(1,48,'THE COCONUT STOP HELD: the dropped line is absent from the composed plan',
 $$SELECT CASE WHEN (SELECT value FROM golden.scratch WHERE fixture_id=1 AND key='p1_composed')='"absent"'::jsonb
   THEN 'absent' ELSE COALESCE((SELECT value->>'f0ebe768-d86c-481c-ab46-a361bd9535ba:9563f848-c123-499d-a8c3-039b693bf817'
   FROM golden.scratch WHERE fixture_id=1 AND key='p1_composed'),'dropped') END$$,'eq','dropped','P3'),
(1,49,'Nutella consolidation leg 1: the 1005 A15 line is gone',
 $$SELECT CASE WHEN (SELECT value FROM golden.scratch WHERE fixture_id=1 AND key='p1_composed')='"absent"'::jsonb
   THEN 'absent' ELSE COALESCE((SELECT value->>'227ae9b5-7abb-4022-8533-ac98cded5c26:7998f596-3cb3-45ea-81d2-2eb1fe1eded9'
   FROM golden.scratch WHERE fixture_id=1 AND key='p1_composed'),'dropped') END$$,'eq','dropped','P3'),
(1,50,'Nutella consolidation leg 2: the 1011 A16 line is gone',
 $$SELECT CASE WHEN (SELECT value FROM golden.scratch WHERE fixture_id=1 AND key='p1_composed')='"absent"'::jsonb
   THEN 'absent' ELSE COALESCE((SELECT value->>'11d77651-ac83-4cd8-83f1-cf3117c21ac7:7998f596-3cb3-45ea-81d2-2eb1fe1eded9'
   FROM golden.scratch WHERE fixture_id=1 AND key='p1_composed'),'dropped') END$$,'eq','dropped','P3'),
(1,51,'A04 REMOVE (v3 analogue): the Krambals & Zigi line is gone from the composed plan',
 $$SELECT CASE WHEN (SELECT value FROM golden.scratch WHERE fixture_id=1 AND key='p1_composed')='"absent"'::jsonb
   THEN 'absent' ELSE COALESCE((SELECT value->>'677aa6d8-475c-45ff-abd6-d42a14b41b3a:098f5c0c-28b1-46c3-869a-2da87297c4d5'
   FROM golden.scratch WHERE fixture_id=1 AND key='p1_composed'),'dropped') END$$,'eq','dropped','P3'),
(1,52,'the untouched Red Bull control still carries the engine seven',
 $$SELECT COALESCE((SELECT value->>'65d699ab-441c-43e7-9a5d-bbd90d0da08e:a602c923-c4c0-4ecc-b5f7-3c13a1960beb'
     FROM golden.scratch WHERE fixture_id=1 AND key='p1_composed'),'absent')$$,'eq','7','P3'),
(1,53,'stitch was fed the composed 54 units, not the engine base 48',
 $$SELECT COALESCE((SELECT value#>>'{stitch,units_in}' FROM golden.scratch WHERE fixture_id=1 AND key='p1'),'absent')$$,'eq','54','P3'),
(1,54,'THE HUMAN NUMBER REACHED THE STITCHED PLAN: 2005 B08 carries nine end to end',
 $$SELECT COALESCE((SELECT value->>'6f7c0d4b-8971-476f-ab8e-32b5a8ed5e23'
     FROM golden.scratch WHERE fixture_id=1 AND key='p1_stitched'),'absent')$$,'eq','9','P3'),
(1,55,'...and the Zigi seven reached it too',
 $$SELECT COALESCE((SELECT value->>'6d69c76c-9592-47c9-898b-25bd5bf6d4b6'
     FROM golden.scratch WHERE fixture_id=1 AND key='p1_stitched'),'absent')$$,'eq','7','P3'),

-- ---- HALF B: survival under an engine re-run -------------------------------
(1,60,'the second pipeline run, over a MOVED engine base, also completed',
 $$SELECT value->>'status' FROM golden.scratch WHERE fixture_id=1 AND key='p2'$$,'eq','ok','P3'),
(1,61,'EDITS INTACT POST-RE-RUN: the consolidated nine held although the engine moved 3 -> 5',
 $$SELECT COALESCE((SELECT value->>'6f7c0d4b-8971-476f-ab8e-32b5a8ed5e23:7998f596-3cb3-45ea-81d2-2eb1fe1eded9'
     FROM golden.scratch WHERE fixture_id=1 AND key='p2_composed'),'absent')$$,'eq','9','P3'),
(1,62,'EDITS INTACT POST-RE-RUN: Zigi held at seven although the engine moved 10 -> 12',
 $$SELECT COALESCE((SELECT value->>'6d69c76c-9592-47c9-898b-25bd5bf6d4b6:da115e6f-8d9b-48ab-b998-531cb81d3faa'
     FROM golden.scratch WHERE fixture_id=1 AND key='p2_composed'),'absent')$$,'eq','7','P3'),
(1,63,'⭐ THE ENGINE WAS NOT FROZEN WHOLESALE: the UNLOCKED Red Bull control followed it 7 -> 9',
 $$SELECT COALESCE((SELECT value->>'65d699ab-441c-43e7-9a5d-bbd90d0da08e:a602c923-c4c0-4ecc-b5f7-3c13a1960beb'
     FROM golden.scratch WHERE fixture_id=1 AND key='p2_composed'),'absent')$$,'eq','9','P3'),
(1,64,'the coconut stop still holds after the engine re-proposed it at six',
 $$SELECT CASE WHEN (SELECT value FROM golden.scratch WHERE fixture_id=1 AND key='p2_composed')='"absent"'::jsonb
   THEN 'absent' ELSE COALESCE((SELECT value->>'f0ebe768-d86c-481c-ab46-a361bd9535ba:9563f848-c123-499d-a8c3-039b693bf817'
   FROM golden.scratch WHERE fixture_id=1 AND key='p2_composed'),'dropped') END$$,'eq','dropped','P3'),
(1,65,'the A04 REMOVE still holds after the engine re-proposed K&Z at four',
 $$SELECT CASE WHEN (SELECT value FROM golden.scratch WHERE fixture_id=1 AND key='p2_composed')='"absent"'::jsonb
   THEN 'absent' ELSE COALESCE((SELECT value->>'677aa6d8-475c-45ff-abd6-d42a14b41b3a:098f5c0c-28b1-46c3-869a-2da87297c4d5'
   FROM golden.scratch WHERE fixture_id=1 AND key='p2_composed'),'dropped') END$$,'eq','dropped','P3'),
(1,66,'the human ADD survived the re-run as well',
 $$SELECT COALESCE((SELECT value->>'677aa6d8-475c-45ff-abd6-d42a14b41b3a:acde9e53-d5aa-4b39-bcfb-b7bda4f2cd66'
     FROM golden.scratch WHERE fixture_id=1 AND key='p2_composed'),'absent')$$,'eq','8','P3'),
(1,67,'the pipeline never rewrote the base run it was handed: R2 Zigi is still the engine twelve',
 $$SELECT COALESCE((SELECT value->>'6d69c76c-9592-47c9-898b-25bd5bf6d4b6'
     FROM golden.scratch WHERE fixture_id=1 AND key='r2_after'),'absent')$$,'eq','12','P3'),

-- ---- approve --------------------------------------------------------------
(1,70,'CS approval of the replay plan was accepted',
 $$SELECT value->>'approve' FROM golden.scratch WHERE fixture_id=1 AND key='approve'$$,'eq','ok','P3'),
(1,71,'a second approval of the same run is refused',
 $$SELECT value->>'double_approve' FROM golden.scratch WHERE fixture_id=1 AND key='approve'$$,'eq','REFUSED','P3'),
(1,72,'exactly one approval stands for the plan date',
 $$SELECT value->>'standing' FROM golden.scratch WHERE fixture_id=1 AND key='approve'$$,'eq','1','P3'),

-- ---- live tripwires -------------------------------------------------------
(1,80,'LAW 4/12: the live plan table holds nothing on the fixture date',
 $$SELECT value->>'live_rpo_on_fixture_date' FROM golden.scratch WHERE fixture_id=1 AND key='tripwires'$$,'eq','0','P3'),
(1,81,'LAW 4/12: live pod_refills untouched on the fixture date',
 $$SELECT value->>'live_pod_refills_on_date' FROM golden.scratch WHERE fixture_id=1 AND key='tripwires'$$,'eq','0','P3'),
(1,82,'⭐ THE INCIDENT DATE WAS READ, NEVER WRITTEN: 2026-07-30 still holds its 71 rows',
 $$SELECT value->>'incident_date_rows' FROM golden.scratch WHERE fixture_id=1 AND key='tripwires'$$,'eq','71','P3'),
(1,83,'THE LIVE VISIT BOARD DID NOT MOVE - asserted as start-vs-end invariance, never as a pinned constant',
 $$SELECT COALESCE((SELECT ((SELECT value->>'machines_to_visit' FROM golden.scratch WHERE fixture_id=1 AND key='tripwires')
     = (SELECT value->>'mtv_before' FROM golden.scratch WHERE fixture_id=1 AND key='hist'))::text),'absent')$$,'eq','true','P3');
