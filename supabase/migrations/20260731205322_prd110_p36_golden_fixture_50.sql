-- PRD-110 P3.6 — golden fixture 50: edits-as-events
-- LAW 1: this fixture lands BEFORE plan_edits_v3, record_plan_edit_v3 and
-- compose_plan_with_edits_v3 exist. Every probe of a not-yet-existing object is
-- guarded (to_regclass / to_regprocedure) inside scenario_sql and lands in
-- golden.scratch; the assertions read ONLY scratch, so a missing object reads as
-- a clean RED (golden.compare returns false for a NULL actual) and never throws.

DELETE FROM golden.assertions WHERE fixture_id = 50;
DELETE FROM golden.fixtures  WHERE fixture_id = 50;

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql)
VALUES (
50,
'Human edits are EVENTS that survive an engine re-run: a hard edit outranks a moved base, a soft edit yields to it and says so, a drop stays dropped and an add stays added -- and no edit is ever silently lost (P3.6)',
'PRD-110 BUILD-SPEC P3.6 / WS-E2. The ANTI-PATTERNS list names "re-running engines over human edits" as one of the failures that cost real hours on 2026-07-30, and the PHASE 3 GATE is fixture 1''s 9-edit replay plus edit survival. Today there is no plan_edits object at all: the only edit surfaces are refill_dispatching_edit_log (an audit trail written AFTER the fact, which no engine reads) and restitch_after_edits (which re-derives from the live plan and cannot distinguish a human number from an engine number). So an engine re-run silently reverts every human decision, and nothing records that it happened.',
'P3',
DATE '2030-02-20',
$scen$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- ---------------------------------------------------------------------------
-- (0) ANCHORS. Five real boonz_wh shelves on one Active machine
--     (HUAWEI-2003-0000-B1). Four carry an edit, one is the untouched control
--     that proves the overlay is surgical rather than global.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'anchors', jsonb_build_object(
  'machine', '9db7a821-d312-43b0-8e83-9642abfbfb0b',
  'E_shelf', 'b6454a65-f4da-4c07-8570-b8791f687ee2', 'E_pod', '31186e1c-b61b-4d13-b520-052fb86725a3',
  'S_shelf', '0b3cc2d5-8dce-495c-a6c0-278722bebd1f', 'S_pod', '27444f0d-7d3c-4480-bbdc-4faf60acbdbc',
  'D_shelf', '8539b03e-4628-4e26-bffe-6aa33c282b7a', 'D_pod', 'fad6df6d-ac14-487a-be17-4210fb2d3c70',
  'A_shelf', '13e2f91f-8d0e-4a82-af03-058763887ce4', 'A_pod', '417a7836-e82e-4050-bbfc-8a7892d9ddcb',
  'U_shelf', '8ae4c5f3-cde6-4210-859b-a7aff71895a2', 'U_pod', '36f381fe-9e42-4d2f-920a-7c5192d56c43');

-- ---------------------------------------------------------------------------
-- (1) STRUCTURAL PROBES. All guarded; all land in scratch.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb := '{}'::jsonb; n int; t text;
BEGIN
  v := v || jsonb_build_object('tbl', COALESCE(to_regclass('public.plan_edits_v3')::text, 'absent'));
  v := v || jsonb_build_object('view', COALESCE(to_regclass('public.v_plan_edits_active_v3')::text, 'absent'));
  v := v || jsonb_build_object('writer', COALESCE(to_regprocedure('public.record_plan_edit_v3(date,uuid,uuid,text,integer,text,text)')::text, 'absent'));
  v := v || jsonb_build_object('composer', COALESCE(to_regprocedure('public.compose_plan_with_edits_v3(date,uuid)')::text, 'absent'));

  IF to_regclass('public.plan_edits_v3') IS NOT NULL THEN
    -- the spec's eight named columns plus the event-sourcing carriers
    SELECT count(*) INTO n FROM information_schema.columns
     WHERE table_schema='public' AND table_name='plan_edits_v3'
       AND column_name IN ('plan_date','shelf_id','pod_product_id','kind','qty','lock','author','reason');
    v := v || jsonb_build_object('spec_cols', n);
    SELECT count(*) INTO n FROM information_schema.columns
     WHERE table_schema='public' AND table_name='plan_edits_v3'
       AND column_name IN ('base_qty_at_edit','superseded_at','machine_id','created_at');
    v := v || jsonb_build_object('event_cols', n);
    -- CHECK constraints must NAME the legal values, not merely exist
    SELECT string_agg(pg_get_constraintdef(c.oid), ' | ' ORDER BY conname) INTO t
      FROM pg_constraint c WHERE c.conrelid = 'public.plan_edits_v3'::regclass AND c.contype='c';
    v := v || jsonb_build_object('checks', COALESCE(t,'none'));
    -- anon must hold nothing on the ledger (S-88: the GRANT is the write guard)
    SELECT count(*) INTO n FROM information_schema.role_table_grants
     WHERE table_schema='public' AND table_name='plan_edits_v3' AND grantee='anon';
    v := v || jsonb_build_object('anon_grants', n);
  END IF;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (50, 'struct', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (2) BASE RUN R1. pod_refills_shadow is append-only by trigger, so every run
--     is a fresh run_id and the base can never be rewritten in place.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'r1', to_jsonb(gen_random_uuid());

INSERT INTO public.pod_refills_shadow
  (run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id, qty,
   availability_basis, wh_available_pod)
SELECT ((SELECT value FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key='r1') #>> '{}')::uuid,
       'engine_add_pod_v3', {{plan_date}},
       '9db7a821-d312-43b0-8e83-9642abfbfb0b'::uuid, a.sid, a.pid, a.qty, 'boonz_wh', 0
FROM (VALUES
  ('b6454a65-f4da-4c07-8570-b8791f687ee2'::uuid,'31186e1c-b61b-4d13-b520-052fb86725a3'::uuid, 6),
  ('0b3cc2d5-8dce-495c-a6c0-278722bebd1f'::uuid,'27444f0d-7d3c-4480-bbdc-4faf60acbdbc'::uuid, 4),
  ('8539b03e-4628-4e26-bffe-6aa33c282b7a'::uuid,'fad6df6d-ac14-487a-be17-4210fb2d3c70'::uuid, 3),
  ('8ae4c5f3-cde6-4210-859b-a7aff71895a2'::uuid,'36f381fe-9e42-4d2f-920a-7c5192d56c43'::uuid, 5)
) AS a(sid,pid,qty);

-- ---------------------------------------------------------------------------
-- (3) THE FOUR EDITS, through the writer. E hard set_qty, S soft set_qty,
--     D hard drop, A soft add on a shelf the engine never planned.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb := '{}'::jsonb; r jsonb; n int; msg text;
BEGIN
  IF to_regprocedure('public.record_plan_edit_v3(date,uuid,uuid,text,integer,text,text)') IS NOT NULL THEN
    EXECUTE $x$ SELECT public.record_plan_edit_v3(DATE '2030-02-20',
       'b6454a65-f4da-4c07-8570-b8791f687ee2'::uuid,'31186e1c-b61b-4d13-b520-052fb86725a3'::uuid,
       'set_qty', 11, 'hard', 'CS holds Mountain Dew at 11 for the promo endcap') $x$ INTO r;
    v := v || jsonb_build_object('E', r);
    EXECUTE $x$ SELECT public.record_plan_edit_v3(DATE '2030-02-20',
       '0b3cc2d5-8dce-495c-a6c0-278722bebd1f'::uuid,'27444f0d-7d3c-4480-bbdc-4faf60acbdbc'::uuid,
       'set_qty', 9, 'soft', 'Krambals looked light on the last visit photo') $x$ INTO r;
    v := v || jsonb_build_object('S', r);
    EXECUTE $x$ SELECT public.record_plan_edit_v3(DATE '2030-02-20',
       '8539b03e-4628-4e26-bffe-6aa33c282b7a'::uuid,'fad6df6d-ac14-487a-be17-4210fb2d3c70'::uuid,
       'drop', NULL, 'hard', 'SF Pancake is being delisted, do not send more') $x$ INTO r;
    v := v || jsonb_build_object('D', r);
    EXECUTE $x$ SELECT public.record_plan_edit_v3(DATE '2030-02-20',
       '13e2f91f-8d0e-4a82-af03-058763887ce4'::uuid,'417a7836-e82e-4050-bbfc-8a7892d9ddcb'::uuid,
       'add', 7, 'soft', 'Be-kind Bar empty on the floor, engine missed it') $x$ INTO r;
    v := v || jsonb_build_object('A', r);

    -- the writer must REFUSE a thin reason and an unknown kind (named, not generic)
    BEGIN
      EXECUTE $x$ SELECT public.record_plan_edit_v3(DATE '2030-02-20',
         '8ae4c5f3-cde6-4210-859b-a7aff71895a2'::uuid,'36f381fe-9e42-4d2f-920a-7c5192d56c43'::uuid,
         'set_qty', 2, 'soft', 'oops') $x$ INTO r;
      v := v || jsonb_build_object('thin_reason', 'ACCEPTED');
    EXCEPTION WHEN OTHERS THEN
      v := v || jsonb_build_object('thin_reason', 'REFUSED');
    END;
    BEGIN
      EXECUTE $x$ SELECT public.record_plan_edit_v3(DATE '2030-02-20',
         '8ae4c5f3-cde6-4210-859b-a7aff71895a2'::uuid,'36f381fe-9e42-4d2f-920a-7c5192d56c43'::uuid,
         'obliterate', 2, 'soft', 'not a legal kind at all') $x$ INTO r;
      v := v || jsonb_build_object('bad_kind', 'ACCEPTED');
    EXCEPTION WHEN OTHERS THEN
      v := v || jsonb_build_object('bad_kind', 'REFUSED');
    END;

    -- re-editing the SAME key must supersede, never accumulate a second active row
    EXECUTE $x$ SELECT public.record_plan_edit_v3(DATE '2030-02-20',
       'b6454a65-f4da-4c07-8570-b8791f687ee2'::uuid,'31186e1c-b61b-4d13-b520-052fb86725a3'::uuid,
       'set_qty', 11, 'hard', 'CS re-confirms the 11 after the second photo') $x$ INTO r;
    EXECUTE $x$ SELECT count(*) FROM public.v_plan_edits_active_v3
              WHERE plan_date = DATE '2030-02-20'
                AND shelf_id = 'b6454a65-f4da-4c07-8570-b8791f687ee2'::uuid $x$ INTO n;
    v := v || jsonb_build_object('active_after_reedit', n);
    EXECUTE $x$ SELECT count(*) FROM public.plan_edits_v3
              WHERE plan_date = DATE '2030-02-20'
                AND shelf_id = 'b6454a65-f4da-4c07-8570-b8791f687ee2'::uuid $x$ INTO n;
    v := v || jsonb_build_object('rows_after_reedit', n);

    -- base_qty_at_edit is the whole basis of the soft rule: it must be CAPTURED
    EXECUTE $x$ SELECT COALESCE(base_qty_at_edit, -1) FROM public.v_plan_edits_active_v3
              WHERE plan_date = DATE '2030-02-20'
                AND shelf_id = '0b3cc2d5-8dce-495c-a6c0-278722bebd1f'::uuid $x$ INTO n;
    v := v || jsonb_build_object('S_base_at_edit', n);
  END IF;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (50, 'edits', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (4) COMPOSE over R1.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb; rows jsonb;
BEGIN
  IF to_regprocedure('public.compose_plan_with_edits_v3(date,uuid)') IS NOT NULL THEN
    EXECUTE $x$ SELECT public.compose_plan_with_edits_v3(DATE '2030-02-20',
      ((SELECT value FROM golden.scratch WHERE fixture_id = 50 AND key='r1') #>> '{}')::uuid) $x$ INTO v;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (50, 'c1', v);
    EXECUTE $x$ SELECT COALESCE(jsonb_object_agg(shelf_id::text, qty), '{}'::jsonb)
                 FROM public.pod_refills_shadow WHERE run_id = $1 $x$
      INTO rows USING (v->>'run_id')::uuid;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (50, 'c1_rows', rows);
  END IF;
END
$do$;

-- ---------------------------------------------------------------------------
-- (5) BASE RUN R2 -- the engine re-run. E and S move; D and U do not. This is
--     the premise the survival assertions stand on, so it is asserted too.
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
  ('0b3cc2d5-8dce-495c-a6c0-278722bebd1f'::uuid,'27444f0d-7d3c-4480-bbdc-4faf60acbdbc'::uuid, 7),
  ('8539b03e-4628-4e26-bffe-6aa33c282b7a'::uuid,'fad6df6d-ac14-487a-be17-4210fb2d3c70'::uuid, 3),
  ('8ae4c5f3-cde6-4210-859b-a7aff71895a2'::uuid,'36f381fe-9e42-4d2f-920a-7c5192d56c43'::uuid, 5)
) AS a(sid,pid,qty);

-- ---------------------------------------------------------------------------
-- (6) COMPOSE over R2 (the survival test), then AGAIN (idempotency).
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb; v2 jsonb; rows jsonb; rows2 jsonb; n int;
BEGIN
  IF to_regprocedure('public.compose_plan_with_edits_v3(date,uuid)') IS NOT NULL THEN
    EXECUTE $x$ SELECT public.compose_plan_with_edits_v3(DATE '2030-02-20',
      ((SELECT value FROM golden.scratch WHERE fixture_id = 50 AND key='r2') #>> '{}')::uuid) $x$ INTO v;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (50, 'c2', v);
    EXECUTE $x$ SELECT COALESCE(jsonb_object_agg(shelf_id::text, qty), '{}'::jsonb)
                 FROM public.pod_refills_shadow WHERE run_id = $1 $x$
      INTO rows USING (v->>'run_id')::uuid;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (50, 'c2_rows', rows);

    -- second compose over the SAME base: same content, distinct run_id
    EXECUTE $x$ SELECT public.compose_plan_with_edits_v3(DATE '2030-02-20',
      ((SELECT value FROM golden.scratch WHERE fixture_id = 50 AND key='r2') #>> '{}')::uuid) $x$ INTO v2;
    EXECUTE $x$ SELECT COALESCE(jsonb_object_agg(shelf_id::text, qty), '{}'::jsonb)
                 FROM public.pod_refills_shadow WHERE run_id = $1 $x$
      INTO rows2 USING (v2->>'run_id')::uuid;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES
      (50, 'c2b', jsonb_build_object(
        'same_content', (rows = rows2),
        'distinct_run', ((v->>'run_id') IS DISTINCT FROM (v2->>'run_id')),
        'rows', rows2));

    -- the composer must never rewrite its own input, nor write an edit
    EXECUTE $x$ SELECT COALESCE(jsonb_object_agg(shelf_id::text, qty), '{}'::jsonb)
                 FROM public.pod_refills_shadow WHERE run_id =
      ((SELECT value FROM golden.scratch WHERE fixture_id = 50 AND key='r2') #>> '{}')::uuid $x$ INTO rows2;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (50, 'r2_after', rows2);
    EXECUTE $x$ SELECT count(*) FROM public.plan_edits_v3 WHERE plan_date = DATE '2030-02-20' $x$ INTO n;
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (50, 'edits_after_compose', to_jsonb(n));
  END IF;
END
$do$;

-- ---------------------------------------------------------------------------
-- (7) APPEND-ONLY GUARDS. An edit ledger that can be UPDATEd in place is not an
--     event log. DELETE and a qty rewrite must both be refused; the supersede
--     UPDATE must be permitted, or the writer could not do its job.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb := '{}'::jsonb;
BEGIN
  IF to_regclass('public.plan_edits_v3') IS NOT NULL THEN
    BEGIN
      EXECUTE $x$ DELETE FROM public.plan_edits_v3 WHERE plan_date = DATE '2030-02-20' $x$;
      v := v || jsonb_build_object('delete', 'ALLOWED');
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('delete', 'REFUSED');
    END;
    BEGIN
      EXECUTE $x$ UPDATE public.plan_edits_v3 SET qty = 999 WHERE plan_date = DATE '2030-02-20' $x$;
      v := v || jsonb_build_object('update_qty', 'ALLOWED');
    EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('update_qty', 'REFUSED');
    END;
  END IF;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (50, 'guards', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (8) LIVE-TABLE TRIPWIRES. P3.6 is shadow work (LAW 4): nothing it does may
--     move a live plan table or the Gate-0 queue.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'tripwires', jsonb_build_object(
  'refill_plan_output', (SELECT count(*) FROM public.refill_plan_output),
  'pod_refills',        (SELECT count(*) FROM public.pod_refills),
  'machines_to_visit',  (SELECT count(*) FROM public.machines_to_visit),
  'live_rpo_on_date',   (SELECT count(*) FROM public.refill_plan_output WHERE plan_date = {{plan_date}}));
$scen$
);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required) VALUES

-- ============================ STRUCTURE ==================================
(50, 1, 'plan_edits_v3 exists',
 $c$SELECT value->>'tbl' FROM golden.scratch WHERE fixture_id=50 AND key='struct'$c$, 'eq', 'plan_edits_v3', 'P3'),
(50, 2, 'the eight BUILD-SPEC columns are all present',
 $c$SELECT (value->>'spec_cols') FROM golden.scratch WHERE fixture_id=50 AND key='struct'$c$, 'eq', '8', 'P3'),
(50, 3, 'the event-sourcing carriers are present (base_qty_at_edit, superseded_at, machine_id, created_at)',
 $c$SELECT (value->>'event_cols') FROM golden.scratch WHERE fixture_id=50 AND key='struct'$c$, 'eq', '4', 'P3'),
(50, 4, 'kind is constrained to set_qty/add/drop',
 $c$SELECT value->>'checks' FROM golden.scratch WHERE fixture_id=50 AND key='struct'$c$, 'contains', 'set_qty', 'P3'),
(50, 5, 'lock is constrained to hard/soft',
 $c$SELECT value->>'checks' FROM golden.scratch WHERE fixture_id=50 AND key='struct'$c$, 'contains', 'soft', 'P3'),
(50, 6, 'anon holds no grant on the edit ledger (S-88: the GRANT is the write guard, not RLS)',
 $c$SELECT (value->>'anon_grants') FROM golden.scratch WHERE fixture_id=50 AND key='struct'$c$, 'eq', '0', 'P3'),
(50, 7, 'v_plan_edits_active_v3 exists',
 $c$SELECT value->>'view' FROM golden.scratch WHERE fixture_id=50 AND key='struct'$c$, 'eq', 'v_plan_edits_active_v3', 'P3'),
(50, 8, 'record_plan_edit_v3 exists at the specified signature',
 $c$SELECT value->>'writer' FROM golden.scratch WHERE fixture_id=50 AND key='struct'$c$, 'contains', 'record_plan_edit_v3', 'P3'),
(50, 9, 'compose_plan_with_edits_v3 exists at the specified signature',
 $c$SELECT value->>'composer' FROM golden.scratch WHERE fixture_id=50 AND key='struct'$c$, 'contains', 'compose_plan_with_edits_v3', 'P3'),

-- ============================ WRITER =====================================
(50, 10, 'the writer accepted the hard set_qty edit',
 $c$SELECT value#>>'{E,status}' FROM golden.scratch WHERE fixture_id=50 AND key='edits'$c$, 'eq', 'ok', 'P3'),
(50, 11, 'the writer accepted the soft set_qty edit',
 $c$SELECT value#>>'{S,status}' FROM golden.scratch WHERE fixture_id=50 AND key='edits'$c$, 'eq', 'ok', 'P3'),
(50, 12, 'the writer accepted the drop edit',
 $c$SELECT value#>>'{D,status}' FROM golden.scratch WHERE fixture_id=50 AND key='edits'$c$, 'eq', 'ok', 'P3'),
(50, 13, 'the writer accepted the add edit on a shelf the engine never planned',
 $c$SELECT value#>>'{A,status}' FROM golden.scratch WHERE fixture_id=50 AND key='edits'$c$, 'eq', 'ok', 'P3'),
(50, 14, 'a reason under 10 characters is REFUSED (the house note-length rule)',
 $c$SELECT value->>'thin_reason' FROM golden.scratch WHERE fixture_id=50 AND key='edits'$c$, 'eq', 'REFUSED', 'P3'),
(50, 15, 'an unknown kind is REFUSED rather than stored and ignored later',
 $c$SELECT value->>'bad_kind' FROM golden.scratch WHERE fixture_id=50 AND key='edits'$c$, 'eq', 'REFUSED', 'P3'),
(50, 16, 're-editing one key leaves exactly ONE active edit',
 $c$SELECT (value->>'active_after_reedit') FROM golden.scratch WHERE fixture_id=50 AND key='edits'$c$, 'eq', '1', 'P3'),
(50, 17, '...but BOTH events survive in the ledger -- supersession, not overwrite',
 $c$SELECT (value->>'rows_after_reedit') FROM golden.scratch WHERE fixture_id=50 AND key='edits'$c$, 'eq', '2', 'P3'),
(50, 18, 'the writer captured base_qty_at_edit=4 from the base run (the basis of the soft rule)',
 $c$SELECT (value->>'S_base_at_edit') FROM golden.scratch WHERE fixture_id=50 AND key='edits'$c$, 'eq', '4', 'P3'),

-- ============================ COMPOSE over R1 ============================
(50, 19, 'compose over the first base run succeeds',
 $c$SELECT value->>'status' FROM golden.scratch WHERE fixture_id=50 AND key='c1'$c$, 'eq', 'ok', 'P3'),
(50, 20, 'the composed run is a NEW run, never a rewrite of the base',
 $c$SELECT (( (SELECT value->>'run_id' FROM golden.scratch WHERE fixture_id=50 AND key='c1')
   IS DISTINCT FROM (SELECT value#>>'{}' FROM golden.scratch WHERE fixture_id=50 AND key='r1') ))::text$c$, 'eq', 'true', 'P3'),
(50, 21, 'C1 E: the hard edit qty 11 replaced the base 6',
 $c$SELECT value->>'b6454a65-f4da-4c07-8570-b8791f687ee2' FROM golden.scratch WHERE fixture_id=50 AND key='c1_rows'$c$, 'eq', '11', 'P3'),
(50, 22, 'C1 S: the soft edit qty 9 applied while the base was unmoved',
 $c$SELECT value->>'0b3cc2d5-8dce-495c-a6c0-278722bebd1f' FROM golden.scratch WHERE fixture_id=50 AND key='c1_rows'$c$, 'eq', '9', 'P3'),
(50, 23, 'C1 D: the dropped shelf emits NO line at all',
 $c$SELECT COALESCE((SELECT value->>'8539b03e-4628-4e26-bffe-6aa33c282b7a' FROM golden.scratch WHERE fixture_id=50 AND key='c1_rows'),'absent')$c$, 'eq', 'absent', 'P3'),
(50, 24, 'C1 A: the added shelf emits a line the engine never produced',
 $c$SELECT value->>'13e2f91f-8d0e-4a82-af03-058763887ce4' FROM golden.scratch WHERE fixture_id=50 AND key='c1_rows'$c$, 'eq', '7', 'P3'),
(50, 25, 'C1 U: the untouched control keeps the base qty -- the overlay is surgical',
 $c$SELECT value->>'8ae4c5f3-cde6-4210-859b-a7aff71895a2' FROM golden.scratch WHERE fixture_id=50 AND key='c1_rows'$c$, 'eq', '5', 'P3'),
(50, 26, 'C1 emits exactly 4 lines (4 base - 1 dropped + 1 added)',
 $c$SELECT (SELECT count(*) FROM jsonb_object_keys((SELECT value FROM golden.scratch WHERE fixture_id=50 AND key='c1_rows')))::text$c$, 'eq', '4', 'P3'),

-- ============ THE HEART: SURVIVAL ACROSS AN ENGINE RE-RUN ================
(50, 27, 'PREMISE: the re-run genuinely moved E from 6 to 9 (a vacuous premise would fake every survival assertion below)',
 $c$SELECT value->>'b6454a65-f4da-4c07-8570-b8791f687ee2' FROM golden.scratch WHERE fixture_id=50 AND key='r2_after'$c$, 'eq', '9', 'P3'),
(50, 28, 'PREMISE: the re-run genuinely moved S from 4 to 7',
 $c$SELECT value->>'0b3cc2d5-8dce-495c-a6c0-278722bebd1f' FROM golden.scratch WHERE fixture_id=50 AND key='r2_after'$c$, 'eq', '7', 'P3'),
(50, 29, 'C2 E: THE HARD EDIT SURVIVED THE RE-RUN -- still 11, not the engine''s new 9',
 $c$SELECT value->>'b6454a65-f4da-4c07-8570-b8791f687ee2' FROM golden.scratch WHERE fixture_id=50 AND key='c2_rows'$c$, 'eq', '11', 'P3'),
(50, 30, 'C2 S: the SOFT edit yielded to a base that moved -- 7, not the stale 9',
 $c$SELECT value->>'0b3cc2d5-8dce-495c-a6c0-278722bebd1f' FROM golden.scratch WHERE fixture_id=50 AND key='c2_rows'$c$, 'eq', '7', 'P3'),
(50, 31, '...and the yield was RECORDED, never silent',
 $c$SELECT (value->>'edits_yielded') FROM golden.scratch WHERE fixture_id=50 AND key='c2'$c$, 'eq', '1', 'P3'),
(50, 32, 'the yielded edit names the shelf it yielded on',
 $c$SELECT (value->'yielded')::text FROM golden.scratch WHERE fixture_id=50 AND key='c2'$c$, 'contains', '0b3cc2d5-8dce-495c-a6c0-278722bebd1f', 'P3'),
(50, 33, 'C2 D: the drop survived the re-run -- still no line',
 $c$SELECT COALESCE((SELECT value->>'8539b03e-4628-4e26-bffe-6aa33c282b7a' FROM golden.scratch WHERE fixture_id=50 AND key='c2_rows'),'absent')$c$, 'eq', 'absent', 'P3'),
(50, 34, 'C2 A: the add survived the re-run -- still 7',
 $c$SELECT value->>'13e2f91f-8d0e-4a82-af03-058763887ce4' FROM golden.scratch WHERE fixture_id=50 AND key='c2_rows'$c$, 'eq', '7', 'P3'),
(50, 35, 'C2 U: the control is still the base qty',
 $c$SELECT value->>'8ae4c5f3-cde6-4210-859b-a7aff71895a2' FROM golden.scratch WHERE fixture_id=50 AND key='c2_rows'$c$, 'eq', '5', 'P3'),
(50, 36, 'NO EDIT IS LOST: applied + yielded = considered',
 $c$SELECT ( (value->>'edits_applied')::int + (value->>'edits_yielded')::int
          = (value->>'edits_considered')::int )::text FROM golden.scratch WHERE fixture_id=50 AND key='c2'$c$, 'eq', 'true', 'P3'),
(50, 37, 'all four edits were considered on the re-run',
 $c$SELECT (value->>'edits_considered') FROM golden.scratch WHERE fixture_id=50 AND key='c2'$c$, 'eq', '4', 'P3'),
(50, 38, 'three edits applied on the re-run (E hard, D drop, A add)',
 $c$SELECT (value->>'edits_applied') FROM golden.scratch WHERE fixture_id=50 AND key='c2'$c$, 'eq', '3', 'P3'),

-- ============================ IDEMPOTENCY ================================
(50, 39, 'composing twice over one base yields identical content (S4 idempotency)',
 $c$SELECT (value->>'same_content') FROM golden.scratch WHERE fixture_id=50 AND key='c2b'$c$, 'eq', 'true', 'P3'),
(50, 40, '...under a DISTINCT run_id, because the shadow ledger is append-only',
 $c$SELECT (value->>'distinct_run') FROM golden.scratch WHERE fixture_id=50 AND key='c2b'$c$, 'eq', 'true', 'P3'),
(50, 41, 'the composer never rewrote its own input run',
 $c$SELECT value->>'8ae4c5f3-cde6-4210-859b-a7aff71895a2' FROM golden.scratch WHERE fixture_id=50 AND key='r2_after'$c$, 'eq', '5', 'P3'),
(50, 42, 'the composer wrote no edit of its own (5 events: 4 edits + 1 supersession)',
 $c$SELECT (value#>>'{}') FROM golden.scratch WHERE fixture_id=50 AND key='edits_after_compose'$c$, 'eq', '5', 'P3'),

-- ============================ APPEND-ONLY ================================
(50, 43, 'DELETE on the edit ledger is REFUSED -- an event log is not a scratchpad',
 $c$SELECT value->>'delete' FROM golden.scratch WHERE fixture_id=50 AND key='guards'$c$, 'eq', 'REFUSED', 'P3'),
(50, 44, 'rewriting a recorded qty in place is REFUSED',
 $c$SELECT value->>'update_qty' FROM golden.scratch WHERE fixture_id=50 AND key='guards'$c$, 'eq', 'REFUSED', 'P3'),

-- ============================ TRIPWIRES ==================================
(50, 45, 'LAW 4: no live refill_plan_output row exists on the fixture date',
 $c$SELECT (value->>'live_rpo_on_date') FROM golden.scratch WHERE fixture_id=50 AND key='tripwires'$c$, 'eq', '0', 'P3'),
(50, 46, 'LAW 11: the Gate-0 queue is untouched at 1240',
 $c$SELECT (value->>'machines_to_visit') FROM golden.scratch WHERE fixture_id=50 AND key='tripwires'$c$, 'eq', '1240', 'P3');
