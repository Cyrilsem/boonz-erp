-- PRD-110 · leg 77 · FIXTURE 11 BUILT RED FIRST (LAW 1)
-- "Mid-plan machine drop" — AMZ drop 07-30, the VML(VW) A05 6-unit case.
-- Two machines are dropped after the draft. Their WH allocation is freed. Today
-- NOTHING re-offers it: compose_plan_with_edits_v3 sets a dropped line's effective
-- qty to 0 and simply does not insert it, so the units vanish with no record.
-- This fixture asserts an EXPLICIT re-allocation proposal exists. It is expected
-- to FAIL on the objects that do not exist yet — that failure is the point.

SET LOCAL statement_timeout = '180s';

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, enabled, baseline_status, notes)
VALUES (
  11,
  'Mid-plan machine drop: when a machine is dropped after the draft, the warehouse units its plan had already claimed are FREED, and every freed unit is re-offered as an explicit, reviewable re-allocation proposal — matched to a shelf in the same plan that was blocked on exactly that product, or recorded as unclaimed. A freed unit is never silently absorbed (P3.8)',
  'AMZ drop 07-30 (2 machines dropped post-draft; VML-1004 A05 wanted 6 Nutella Biscuits T12 and got none while AMZ-1029 A06 gave 6 back)',
  'P3',
  DATE '2030-01-12',
  true,
  'failing_expected',
  'Anchors are all real live rows. Freed: 6 Nutella (AMZ-1029 A06), 4+3 Dubai Popcorn (AMZ-1029 A11 + AMZ-1038 A11), 5 Chocolate Bar (AMZ-1038 A07). The only legitimate claimant is VML-1004 A05, blocked_no_wh on Nutella with 6 units of unmet headroom. AMZ-1046 A09 also carries Chocolate Bar but is NOT blocked, so it must NOT be treated as a claimant — that is the assertion that stops this becoming a rebalancer.'
)
ON CONFLICT (fixture_id) DO UPDATE SET
  name = EXCLUDED.name, source_incident = EXCLUDED.source_incident,
  phase_required = EXCLUDED.phase_required, plan_date = EXCLUDED.plan_date,
  enabled = EXCLUDED.enabled, baseline_status = EXCLUDED.baseline_status,
  notes = EXCLUDED.notes;

UPDATE golden.fixtures SET scenario_sql = $SCEN$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- ---------------------------------------------------------------------------
-- (0) ANCHORS. All real. Two AMZ machines get dropped; VML-1004 A05 is the
--     blocked claimant (the "VW 6u case"); AMZ-1046 A09 is the control that
--     carries a freed product but is NOT blocked and must never be offered it.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'anchors', jsonb_build_object(
  'drop1_machine',       'f1a528fb-15e8-4f20-b4e2-ebb2e6852198',
  'drop1_nutella_shelf', '3c03c14f-1cfb-4831-9470-4b086e4e6e51',
  'drop1_popcorn_shelf', '2a9de9de-03ca-4264-a804-35a3aed2e5c7',
  'drop2_machine',       'a75b847a-e920-4a94-bb2f-600280ff8b3c',
  'drop2_popcorn_shelf', '7370a5b7-a451-4a9a-b661-2dc0953fd854',
  'drop2_choc_shelf',    '46694c0a-774a-4a31-afd5-565b07b99b0e',
  'claim_machine',       '1b9f6cb5-dadd-4928-b321-c096f8b8607e',
  'claim_shelf',         'a489ab36-03b1-4691-8ca5-65d6b632fd75',
  'ctrl_machine',        '981a155e-8bfc-4d6e-b168-0770ef082dc9',
  'ctrl_shelf',          '18cbe815-4d7a-4ea4-8a1c-b846dbebaf00',
  'pod_nutella',         '7998f596-3cb3-45ea-81d2-2eb1fe1eded9',
  'pod_popcorn',         '31c78eac-d859-41d7-8ba1-6d5cee5381ff',
  'pod_choc',            '36f381fe-9e42-4d2f-920a-7c5192d56c43');

-- ---------------------------------------------------------------------------
-- (0b) S-116 RUN-SCOPED BASELINE. plan_edits_v3 is append-only and refuses
--      DELETE, so this fixture cannot clear its own rows; it measures what THIS
--      run appended.
-- ---------------------------------------------------------------------------
DO $pre$
DECLARE v jsonb := jsonb_build_object('pre_edits', 0, 'pre_props', 0); n int;
BEGIN
  IF to_regclass('public.plan_edits_v3') IS NOT NULL THEN
    EXECUTE $x$ SELECT count(*) FROM public.plan_edits_v3 WHERE plan_date = DATE '2030-01-12' $x$ INTO n;
    v := jsonb_set(v, '{pre_edits}', to_jsonb(n));
  END IF;
  IF to_regclass('public.reallocation_proposals_v3') IS NOT NULL THEN
    EXECUTE $x$ SELECT count(*) FROM public.reallocation_proposals_v3 WHERE plan_date = DATE '2030-01-12' $x$ INTO n;
    v := jsonb_set(v, '{pre_props}', to_jsonb(n));
  END IF;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (11, 'pre', v);
END
$pre$;

-- ---------------------------------------------------------------------------
-- (1) STRUCTURAL PROBES. Guarded; the absence of an object is DATA, never an
--     exception that would abort the fixture.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb := '{}'::jsonb; n int; t text;
BEGIN
  v := v || jsonb_build_object('tbl',
        COALESCE(to_regclass('public.reallocation_proposals_v3')::text, 'absent'));
  v := v || jsonb_build_object('verb',
        COALESCE(to_regprocedure('public.propose_reallocations_v3(date,uuid,uuid,boolean)')::text, 'absent'));
  v := v || jsonb_build_object('composer',
        COALESCE(to_regprocedure('public.compose_plan_with_edits_v3(date,uuid)')::text, 'absent'));
  v := v || jsonb_build_object('editor',
        COALESCE(to_regprocedure('public.record_plan_edit_v3(date,uuid,uuid,text,integer,text,text)')::text, 'absent'));

  IF to_regclass('public.reallocation_proposals_v3') IS NOT NULL THEN
    SELECT count(*) INTO n FROM information_schema.columns
     WHERE table_schema='public' AND table_name='reallocation_proposals_v3'
       AND column_name IN ('proposal_id','plan_date','source_machine_id','source_shelf_id',
                           'pod_product_id','freed_qty','proposed_qty','status');
    v := v || jsonb_build_object('spec_cols', n);
    SELECT count(*) INTO n FROM information_schema.columns
     WHERE table_schema='public' AND table_name='reallocation_proposals_v3'
       AND column_name IN ('target_machine_id','target_shelf_id','reviewed_by','reviewed_at','reasoning');
    v := v || jsonb_build_object('review_cols', n);
    -- the CS gate must be NAMED by a CHECK, not merely implied by a default
    SELECT string_agg(pg_get_constraintdef(c.oid), ' | ' ORDER BY conname) INTO t
      FROM pg_constraint c
     WHERE c.conrelid = 'public.reallocation_proposals_v3'::regclass AND c.contype='c';
    v := v || jsonb_build_object('checks', COALESCE(t,'none'));
    -- anon must hold nothing on the queue (S-88)
    SELECT count(*) INTO n FROM information_schema.role_table_grants
     WHERE table_schema='public' AND table_name='reallocation_proposals_v3' AND grantee='anon';
    v := v || jsonb_build_object('anon_grants', n);
    SELECT count(*) INTO n FROM pg_class WHERE oid='public.reallocation_proposals_v3'::regclass AND relrowsecurity;
    v := v || jsonb_build_object('rls', n);
  END IF;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (11, 'struct', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (2) BASE RUN R1 -- the draft, before anyone drops anything.
--     Six lines. Four belong to the two machines about to be dropped.
--     VML A05 is the blocked claimant: it wants 12-6=6 and got 0.
--     AMZ-1046 A09 is the control: it carries Chocolate Bar but is NOT blocked.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'r1', to_jsonb(gen_random_uuid());

INSERT INTO public.pod_refills_shadow
  (run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id, qty,
   current_stock, max_stock, clamp_reason, availability_basis, wh_available_pod)
SELECT ((SELECT value FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key='r1') #>> '{}')::uuid,
       'engine_add_pod_v3', {{plan_date}}, a.mid, a.sid, a.pid, a.qty,
       a.cur, a.mx, a.clamp, 'boonz_wh', a.wh
FROM (VALUES
  ('f1a528fb-15e8-4f20-b4e2-ebb2e6852198'::uuid,'3c03c14f-1cfb-4831-9470-4b086e4e6e51'::uuid,'7998f596-3cb3-45ea-81d2-2eb1fe1eded9'::uuid, 6, 2,  8, NULL::text,          6),
  ('f1a528fb-15e8-4f20-b4e2-ebb2e6852198'::uuid,'2a9de9de-03ca-4264-a804-35a3aed2e5c7'::uuid,'31c78eac-d859-41d7-8ba1-6d5cee5381ff'::uuid, 4, 2,  6, NULL::text,          4),
  ('a75b847a-e920-4a94-bb2f-600280ff8b3c'::uuid,'7370a5b7-a451-4a9a-b661-2dc0953fd854'::uuid,'31c78eac-d859-41d7-8ba1-6d5cee5381ff'::uuid, 3, 3,  6, NULL::text,          3),
  ('a75b847a-e920-4a94-bb2f-600280ff8b3c'::uuid,'46694c0a-774a-4a31-afd5-565b07b99b0e'::uuid,'36f381fe-9e42-4d2f-920a-7c5192d56c43'::uuid, 5,30, 35, NULL::text,          5),
  ('1b9f6cb5-dadd-4928-b321-c096f8b8607e'::uuid,'a489ab36-03b1-4691-8ca5-65d6b632fd75'::uuid,'7998f596-3cb3-45ea-81d2-2eb1fe1eded9'::uuid, 0, 6, 12, 'blocked_no_wh',     0),
  ('981a155e-8bfc-4d6e-b168-0770ef082dc9'::uuid,'18cbe815-4d7a-4ea4-8a1c-b846dbebaf00'::uuid,'36f381fe-9e42-4d2f-920a-7c5192d56c43'::uuid, 6,29, 35, NULL::text,          6)
) AS a(mid,sid,pid,qty,cur,mx,clamp,wh);

-- ---------------------------------------------------------------------------
-- (3) THE DROP. CS drops both AMZ machines post-draft. A machine drop is
--     expressed today as one 'drop' edit per planned line -- there is no
--     machine-level verb, which is itself recorded below.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb := '{}'::jsonb; r jsonb;
BEGIN
  IF to_regprocedure('public.record_plan_edit_v3(date,uuid,uuid,text,integer,text,text)') IS NOT NULL THEN
    BEGIN
      EXECUTE $x$ SELECT public.record_plan_edit_v3(DATE '2030-01-12',
         '3c03c14f-1cfb-4831-9470-4b086e4e6e51'::uuid,'7998f596-3cb3-45ea-81d2-2eb1fe1eded9'::uuid,
         'drop', NULL, 'hard', 'AMZ-1029 dropped from the run: site access withdrawn for the day') $x$ INTO r;
      v := v || jsonb_build_object('d1_nutella', r);
      EXECUTE $x$ SELECT public.record_plan_edit_v3(DATE '2030-01-12',
         '2a9de9de-03ca-4264-a804-35a3aed2e5c7'::uuid,'31c78eac-d859-41d7-8ba1-6d5cee5381ff'::uuid,
         'drop', NULL, 'hard', 'AMZ-1029 dropped from the run: site access withdrawn for the day') $x$ INTO r;
      v := v || jsonb_build_object('d1_popcorn', r);
      EXECUTE $x$ SELECT public.record_plan_edit_v3(DATE '2030-01-12',
         '7370a5b7-a451-4a9a-b661-2dc0953fd854'::uuid,'31c78eac-d859-41d7-8ba1-6d5cee5381ff'::uuid,
         'drop', NULL, 'hard', 'AMZ-1038 dropped from the run: site access withdrawn for the day') $x$ INTO r;
      v := v || jsonb_build_object('d2_popcorn', r);
      EXECUTE $x$ SELECT public.record_plan_edit_v3(DATE '2030-01-12',
         '46694c0a-774a-4a31-afd5-565b07b99b0e'::uuid,'36f381fe-9e42-4d2f-920a-7c5192d56c43'::uuid,
         'drop', NULL, 'hard', 'AMZ-1038 dropped from the run: site access withdrawn for the day') $x$ INTO r;
      v := v || jsonb_build_object('d2_choc', r);
    EXCEPTION WHEN OTHERS THEN
      v := v || jsonb_build_object('error', SQLERRM);
    END;
  END IF;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (11, 'drops', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (4) COMPOSE. The four dropped lines fall out; the composed plan keeps only
--     the control (the blocked claimant carried qty 0 and is not emitted).
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb; rows jsonb;
BEGIN
  IF to_regprocedure('public.compose_plan_with_edits_v3(date,uuid)') IS NOT NULL THEN
    BEGIN
      EXECUTE $x$ SELECT public.compose_plan_with_edits_v3(DATE '2030-01-12',
        ((SELECT value FROM golden.scratch WHERE fixture_id = 11 AND key='r1') #>> '{}')::uuid) $x$ INTO v;
      INSERT INTO golden.scratch (fixture_id, key, value) VALUES (11, 'c1', v);
      EXECUTE $x$ SELECT COALESCE(jsonb_object_agg(shelf_id::text, qty), '{}'::jsonb)
                   FROM public.pod_refills_shadow WHERE run_id = $1 $x$
        INTO rows USING (v->>'run_id')::uuid;
      INSERT INTO golden.scratch (fixture_id, key, value) VALUES (11, 'c1_rows', rows);
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO golden.scratch (fixture_id, key, value)
      VALUES (11, 'c1', jsonb_build_object('error', SQLERRM));
    END;
  END IF;
END
$do$;

-- ---------------------------------------------------------------------------
-- (5) THE RE-OFFER. This is the fixture. Everything above is setup.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb := '{}'::jsonb; res jsonb; props jsonb; n int; base uuid; comp uuid;
BEGIN
  base := ((SELECT value FROM golden.scratch WHERE fixture_id = 11 AND key='r1') #>> '{}')::uuid;
  comp := ((SELECT value FROM golden.scratch WHERE fixture_id = 11 AND key='c1')->>'run_id')::uuid;
  v := v || jsonb_build_object('base_run', base, 'composed_run', comp);

  -- freed units, computed independently of the verb so the fixture can state
  -- what SHOULD have been re-offered even when nothing re-offers it
  EXECUTE $x$
    SELECT COALESCE(jsonb_object_agg(k, freed), '{}'::jsonb) FROM (
      SELECT b.shelf_id::text AS k,
             (b.qty - COALESCE((SELECT SUM(c.qty) FROM public.pod_refills_shadow c
                                 WHERE c.run_id = $2 AND c.shelf_id = b.shelf_id
                                   AND c.pod_product_id = b.pod_product_id), 0))::int AS freed
        FROM public.pod_refills_shadow b
       WHERE b.run_id = $1 AND b.availability_basis = 'boonz_wh'
    ) q WHERE freed > 0 $x$ INTO props USING base, comp;
  v := v || jsonb_build_object('freed_by_shelf', props);
  v := v || jsonb_build_object('freed_total',
        (SELECT COALESCE(SUM((e.value)::int),0) FROM jsonb_each_text(props) e));

  IF to_regprocedure('public.propose_reallocations_v3(date,uuid,uuid,boolean)') IS NOT NULL THEN
    BEGIN
      -- dry run first: it must compute the same answer and write NOTHING
      EXECUTE $x$ SELECT public.propose_reallocations_v3(DATE '2030-01-12', $1, $2, true) $x$
        INTO res USING base, comp;
      v := v || jsonb_build_object('dry', res);
      EXECUTE $x$ SELECT count(*) FROM public.reallocation_proposals_v3
                   WHERE plan_date = DATE '2030-01-12' $x$ INTO n;
      v := v || jsonb_build_object('rows_after_dry', n);

      EXECUTE $x$ SELECT public.propose_reallocations_v3(DATE '2030-01-12', $1, $2, false) $x$
        INTO res USING base, comp;
      v := v || jsonb_build_object('live', res);
    EXCEPTION WHEN OTHERS THEN
      v := v || jsonb_build_object('error', SQLERRM);
    END;
  ELSE
    v := v || jsonb_build_object('verb', 'absent');
  END IF;

  IF to_regclass('public.reallocation_proposals_v3') IS NOT NULL THEN
    EXECUTE $x$
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'src_machine', source_machine_id, 'src_shelf', source_shelf_id,
               'pod', pod_product_id, 'freed', freed_qty,
               'tgt_machine', target_machine_id, 'tgt_shelf', target_shelf_id,
               'qty', proposed_qty, 'status', status,
               'reviewed_by', reviewed_by) ORDER BY source_shelf_id, proposed_qty DESC), '[]'::jsonb)
        FROM public.reallocation_proposals_v3 WHERE plan_date = DATE '2030-01-12' $x$ INTO props;
    v := v || jsonb_build_object('props', props);
  ELSE
    v := v || jsonb_build_object('props', '[]'::jsonb);
  END IF;

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (11, 'realloc', v);
END
$do$;

-- ---------------------------------------------------------------------------
-- (6) LIVE-TABLE TRIPWIRES (LAW 4/12).
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'tripwires', jsonb_build_object(
  'refill_plan_output', (SELECT count(*) FROM public.refill_plan_output),
  'pod_refills',        (SELECT count(*) FROM public.pod_refills),
  'machines_to_visit',  (SELECT count(*) FROM public.machines_to_visit),
  'live_rpo_on_date',   (SELECT count(*) FROM public.refill_plan_output WHERE plan_date = {{plan_date}}));
$SCEN$
WHERE fixture_id = 11;

-- ---------------------------------------------------------------------------
-- ASSERTIONS
-- ---------------------------------------------------------------------------
DELETE FROM golden.assertions WHERE fixture_id = 11;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES

-- --- premise: the setup is what the fixture claims it is -------------------
(11, 1, 'PREMISE: the base draft R1 carries exactly 6 lines',
 $$SELECT count(*)::text FROM public.pod_refills_shadow WHERE run_id =
   ((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='r1') #>> '{}')::uuid$$,
 'eq', '6', true, 'P3'),
(11, 2, 'PREMISE: AMZ-1029 A06 had claimed 6 Nutella Biscuits T12 from the warehouse',
 $$SELECT qty::text FROM public.pod_refills_shadow WHERE run_id =
   ((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='r1') #>> '{}')::uuid
   AND shelf_id='3c03c14f-1cfb-4831-9470-4b086e4e6e51'::uuid$$,
 'eq', '6', true, 'P3'),
(11, 3, 'PREMISE: VML-1004 A05 is blocked_no_wh on the SAME product, unmet headroom 6 (the VW 6u case)',
 $$SELECT (max_stock - current_stock - qty)::text FROM public.pod_refills_shadow WHERE run_id =
   ((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='r1') #>> '{}')::uuid
   AND shelf_id='a489ab36-03b1-4691-8ca5-65d6b632fd75'::uuid$$,
 'eq', '6', true, 'P3'),
(11, 4, 'PREMISE: the control shelf AMZ-1046 A09 carries a freed product but is NOT blocked',
 $$SELECT COALESCE(clamp_reason,'none') FROM public.pod_refills_shadow WHERE run_id =
   ((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='r1') #>> '{}')::uuid
   AND shelf_id='18cbe815-4d7a-4ea4-8a1c-b846dbebaf00'::uuid$$,
 'eq', 'none', true, 'P3'),
(11, 5, 'PREMISE: all four drop edits were accepted by the canonical writer',
 $$SELECT (SELECT count(*) FROM jsonb_object_keys(
     (SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='drops')) k
     WHERE k LIKE 'd%')::text$$,
 'eq', '4', true, 'P3'),
(11, 6, 'PREMISE: the drop edits are recorded as hard drops in the edit ledger',
 $$SELECT count(*)::text FROM public.v_plan_edits_active_v3
   WHERE plan_date = DATE '2030-01-12' AND kind='drop' AND "lock"='hard'$$,
 'eq', '4', true, 'P3'),

-- --- the drop actually removes the lines ------------------------------------
(11, 7, 'The composed plan drops all four lines of the two dropped machines',
 $$SELECT jsonb_array_length(COALESCE(
     (SELECT jsonb_agg(k) FROM jsonb_object_keys(
        (SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='c1_rows')) k),
     '[]'::jsonb))::text$$,
 'eq', '1', true, 'P3'),
(11, 8, 'The composer accounted for every edit (none silently lost)',
 $$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='c1')->>'edits_applied')$$,
 'eq', '4', true, 'P3'),
(11, 9, 'The surviving control line keeps its full quantity',
 $$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='c1_rows')
           ->>'18cbe815-4d7a-4ea4-8a1c-b846dbebaf00')$$,
 'eq', '6', true, 'P3'),

-- --- the freed units are real and measurable --------------------------------
(11, 10, 'FREED: exactly four source lines released warehouse units',
 $$SELECT (SELECT count(*) FROM jsonb_object_keys(
     (SELECT value->'freed_by_shelf' FROM golden.scratch WHERE fixture_id=11 AND key='realloc')) k)::text$$,
 'eq', '4', true, 'P3'),
(11, 11, 'FREED: 18 warehouse units in total came back (6 Nutella + 7 Popcorn + 5 Chocolate Bar)',
 $$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='realloc')->>'freed_total')$$,
 'eq', '18', true, 'P3'),
(11, 12, 'FREED: AMZ-1029 A06 specifically released its 6 Nutella units',
 $$SELECT ((SELECT value->'freed_by_shelf' FROM golden.scratch WHERE fixture_id=11 AND key='realloc')
           ->>'3c03c14f-1cfb-4831-9470-4b086e4e6e51')$$,
 'eq', '6', true, 'P3'),

-- --- THE RED: the re-offer must exist at all --------------------------------
(11, 13, 'THE QUEUE EXISTS: a re-allocation proposal table is present',
 $$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='struct')->>'tbl')$$,
 'eq', 'reallocation_proposals_v3', true, 'P3'),
(11, 14, 'THE VERB EXISTS: propose_reallocations_v3(date,uuid,uuid,boolean) is callable',
 $$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='struct')->>'verb')$$,
 'ne', 'absent', true, 'P3'),
(11, 15, 'The re-offer ran without error',
 $$SELECT COALESCE((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='realloc')->>'error','none')$$,
 'eq', 'none', true, 'P3'),
(11, 16, 'NOT SILENT: every freed source line is represented in the queue',
 $$SELECT (SELECT count(DISTINCT p->>'src_shelf') FROM jsonb_array_elements(
     (SELECT value->'props' FROM golden.scratch WHERE fixture_id=11 AND key='realloc')) p)::text$$,
 'eq', '4', true, 'P3'),
(11, 17, 'NOT SILENT: the queue accounts for all 18 freed units',
 $$SELECT (SELECT COALESCE(SUM(DISTINCT (p->>'freed')::int),0) FROM jsonb_array_elements(
     (SELECT value->'props' FROM golden.scratch WHERE fixture_id=11 AND key='realloc')) p)::text$$,
 'gte', '18', true, 'P3'),

-- --- THE VW 6u CASE: the match that should have been made -------------------
(11, 18, 'THE VW 6u CASE: a proposal offers the freed Nutella units to VML-1004 A05',
 $$SELECT (SELECT count(*) FROM jsonb_array_elements(
     (SELECT value->'props' FROM golden.scratch WHERE fixture_id=11 AND key='realloc')) p
    WHERE p->>'src_shelf' = '3c03c14f-1cfb-4831-9470-4b086e4e6e51'
      AND p->>'tgt_shelf' = 'a489ab36-03b1-4691-8ca5-65d6b632fd75')::text$$,
 'eq', '1', true, 'P3'),
(11, 19, 'THE VW 6u CASE: the offer is for exactly 6 units',
 $$SELECT COALESCE((SELECT p->>'qty' FROM jsonb_array_elements(
     (SELECT value->'props' FROM golden.scratch WHERE fixture_id=11 AND key='realloc')) p
    WHERE p->>'src_shelf' = '3c03c14f-1cfb-4831-9470-4b086e4e6e51'
      AND p->>'tgt_shelf' = 'a489ab36-03b1-4691-8ca5-65d6b632fd75'), 'none')$$,
 'eq', '6', true, 'P3'),
(11, 20, 'THE VW 6u CASE: the offer names the target MACHINE, not just the shelf',
 $$SELECT COALESCE((SELECT p->>'tgt_machine' FROM jsonb_array_elements(
     (SELECT value->'props' FROM golden.scratch WHERE fixture_id=11 AND key='realloc')) p
    WHERE p->>'src_shelf' = '3c03c14f-1cfb-4831-9470-4b086e4e6e51'
      AND p->>'tgt_shelf' = 'a489ab36-03b1-4691-8ca5-65d6b632fd75'), 'none')$$,
 'eq', '1b9f6cb5-dadd-4928-b321-c096f8b8607e', true, 'P3'),
(11, 21, 'THE VW 6u CASE: the matched offer carries the product that was actually freed',
 $$SELECT COALESCE((SELECT p->>'pod' FROM jsonb_array_elements(
     (SELECT value->'props' FROM golden.scratch WHERE fixture_id=11 AND key='realloc')) p
    WHERE p->>'src_shelf' = '3c03c14f-1cfb-4831-9470-4b086e4e6e51'
      AND p->>'tgt_shelf' = 'a489ab36-03b1-4691-8ca5-65d6b632fd75'), 'none')$$,
 'eq', '7998f596-3cb3-45ea-81d2-2eb1fe1eded9', true, 'P3'),

-- --- unclaimed freed stock is still visible, never absorbed -----------------
(11, 22, 'UNCLAIMED IS NOT SILENT: the three freed lines with no blocked claimant are recorded as unclaimed',
 $$SELECT (SELECT count(*) FROM jsonb_array_elements(
     (SELECT value->'props' FROM golden.scratch WHERE fixture_id=11 AND key='realloc')) p
    WHERE p->>'status' = 'unclaimed')::text$$,
 'eq', '3', true, 'P3'),
(11, 23, 'UNCLAIMED: an unclaimed row names no target shelf',
 $$SELECT (SELECT count(*) FROM jsonb_array_elements(
     (SELECT value->'props' FROM golden.scratch WHERE fixture_id=11 AND key='realloc')) p
    WHERE p->>'status' = 'unclaimed' AND p->>'tgt_shelf' IS NOT NULL)::text$$,
 'eq', '0', true, 'P3'),

-- --- the boundary that stops this becoming a rebalancer ---------------------
(11, 24, 'BOUNDARY: the un-blocked control shelf is never offered the freed Chocolate Bar',
 $$SELECT (SELECT count(*) FROM jsonb_array_elements(
     (SELECT value->'props' FROM golden.scratch WHERE fixture_id=11 AND key='realloc')) p
    WHERE p->>'tgt_shelf' = '18cbe815-4d7a-4ea4-8a1c-b846dbebaf00')::text$$,
 'eq', '0', true, 'P3'),
(11, 25, 'BOUNDARY: no proposal ever targets a shelf on one of the DROPPED machines',
 $$SELECT (SELECT count(*) FROM jsonb_array_elements(
     (SELECT value->'props' FROM golden.scratch WHERE fixture_id=11 AND key='realloc')) p
    WHERE p->>'tgt_machine' IN ('f1a528fb-15e8-4f20-b4e2-ebb2e6852198',
                                'a75b847a-e920-4a94-bb2f-600280ff8b3c'))::text$$,
 'eq', '0', true, 'P3'),
(11, 26, 'BOUNDARY: a proposal never offers a product other than the one that was freed',
 $$SELECT (SELECT count(*) FROM jsonb_array_elements(
     (SELECT value->'props' FROM golden.scratch WHERE fixture_id=11 AND key='realloc')) p
    WHERE p->>'tgt_shelf' IS NOT NULL
      AND p->>'pod' NOT IN ('7998f596-3cb3-45ea-81d2-2eb1fe1eded9',
                            '31c78eac-d859-41d7-8ba1-6d5cee5381ff',
                            '36f381fe-9e42-4d2f-920a-7c5192d56c43'))::text$$,
 'eq', '0', true, 'P3'),

-- --- conservation -----------------------------------------------------------
(11, 27, 'CONSERVATION: no source line ever offers more than it actually freed',
 $$SELECT (SELECT count(*) FROM (
     SELECT p->>'src_shelf' s, SUM((p->>'qty')::int) q, MAX((p->>'freed')::int) f
       FROM jsonb_array_elements(
         (SELECT value->'props' FROM golden.scratch WHERE fixture_id=11 AND key='realloc')) p
      GROUP BY 1) t WHERE t.q > t.f)::text$$,
 'eq', '0', true, 'P3'),

-- --- the CS gate ------------------------------------------------------------
(11, 28, 'CS GATE: every proposal lands unreviewed',
 $$SELECT (SELECT count(*) FROM jsonb_array_elements(
     (SELECT value->'props' FROM golden.scratch WHERE fixture_id=11 AND key='realloc')) p
    WHERE p->>'reviewed_by' IS NOT NULL)::text$$,
 'eq', '0', true, 'P3'),
(11, 29, 'CS GATE: a matched proposal sits in proposed status, not applied',
 $$SELECT COALESCE((SELECT p->>'status' FROM jsonb_array_elements(
     (SELECT value->'props' FROM golden.scratch WHERE fixture_id=11 AND key='realloc')) p
    WHERE p->>'tgt_shelf' = 'a489ab36-03b1-4691-8ca5-65d6b632fd75'), 'none')$$,
 'eq', 'proposed', true, 'P3'),
(11, 30, 'CS GATE: the status values are NAMED by a CHECK constraint',
 $$SELECT COALESCE((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='struct')->>'checks','none')$$,
 'contains', 'unclaimed', true, 'P3'),
(11, 31, 'The queue carries its full spec grain (8 named columns)',
 $$SELECT COALESCE((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='struct')->>'spec_cols','0')$$,
 'eq', '8', true, 'P3'),
(11, 32, 'The queue carries its review + provenance columns',
 $$SELECT COALESCE((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='struct')->>'review_cols','0')$$,
 'eq', '5', true, 'P3'),
(11, 33, 'anon holds no grant on the queue (S-88)',
 $$SELECT COALESCE((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='struct')->>'anon_grants','-1')$$,
 'eq', '0', true, 'P3'),
(11, 34, 'RLS is enabled on the queue',
 $$SELECT COALESCE((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='struct')->>'rls','-1')$$,
 'eq', '1', true, 'P3'),

-- --- dry run writes nothing --------------------------------------------------
(11, 35, 'DRY RUN: computing the answer writes no row',
 $$SELECT COALESCE((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='realloc')->>'rows_after_dry','-1')$$,
 'eq', '0', true, 'P3'),
(11, 36, 'DRY RUN: it still reports the same four proposals it would have written',
 $$SELECT COALESCE((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='realloc')
                   #>>'{dry,proposals}','none')$$,
 'eq', '4', true, 'P3'),

-- --- LAW 4 / LAW 12 tripwires ------------------------------------------------
(11, 37, 'LAW 12: no live refill_plan_output row was created on the fixture date',
 $$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='tripwires')->>'live_rpo_on_date')$$,
 'eq', '0', true, 'P3'),
(11, 38, 'LAW 4: the Gate-0 queue is untouched',
 $$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='tripwires')->>'machines_to_visit')::text$$,
 'eq', '1240', true, 'P3'),
(11, 39, 'LAW 4: the live v19 pod_refills table is untouched by any of this',
 $$SELECT (((SELECT value FROM golden.scratch WHERE fixture_id=11 AND key='tripwires')->>'pod_refills')::int
           - (SELECT count(*) FROM public.pod_refills))::text$$,
 'eq', '0', true, 'P3');
