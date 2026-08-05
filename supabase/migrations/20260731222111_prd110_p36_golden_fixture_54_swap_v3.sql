-- PRD-110 P3.6 — golden fixture 54: one-verb swap_v3 emits correct legs
-- BUILD-SPEC line 94 / charter E3. RED baseline: swap_v3 does not exist yet.
-- plan_date = DATE '2030-01-01' + 54 = 2030-02-24.
--
-- Anchors (all real, probed live at leg 73):
--   machine  9db7a821 HUAWEI-2003-0000-B1
--   A04 shelf b6454a65 / pod 31186e1c "Mountain Dew"   <- swapped OUT (max 14)
--   A05 shelf 0b3cc2d5 / pod 27444f0d "Krambals"       <- already on machine (dup guard)
--   new pod  cf2d60f1 "Al Ain Zero"                    <- NOT on the machine
--   donor    84386a8b shelf eb3b3d92 stock 28          <- cross-machine source
--
-- ⛔ guardrail_products is NOT checked here: preflight_refill_plan already owns
--    that rule. A second copy is the D-35 defect.

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql)
VALUES (54, 'One-verb swap_v3 emits correct legs',
        'PRD-110 BUILD-SPEC P3.6 line 94 / charter E3 (one-verb swap, same or cross machine)',
        'P3', DATE '2030-02-24', $scenario$

DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- (0) ANCHORS -----------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'anchors', jsonb_build_object(
  'machine',     '9db7a821-d312-43b0-8e83-9642abfbfb0b',
  'shelf_out',   'b6454a65-f4da-4c07-8570-b8791f687ee2',
  'pod_out',     '31186e1c-b61b-4d13-b520-052fb86725a3',
  'pod_dup',     '27444f0d-7d3c-4480-bbdc-4faf60acbdbc',
  'shelf_dup',   '0b3cc2d5-8dce-495c-a6c0-278722bebd1f',
  'pod_in',      'cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77',
  'donor',       '84386a8b-ba1c-4be1-aa51-a529203ecfb6');

-- (1) STRUCTURAL PROBE. Guarded: a missing verb must READ as absent, never throw.
DO $do$
DECLARE v jsonb := '{}'::jsonb;
BEGIN
  v := v || jsonb_build_object('verb',
    COALESCE(to_regprocedure('public.swap_v3(date,uuid,uuid,uuid,text,integer,uuid)')::text,'absent'));
  v := v || jsonb_build_object('writer',
    COALESCE(to_regprocedure('public.record_plan_edit_v3(date,uuid,uuid,text,integer,text,text)')::text,'absent'));
  v := v || jsonb_build_object('composer',
    COALESCE(to_regprocedure('public.compose_plan_with_edits_v3(date,uuid)')::text,'absent'));
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (54,'struct', v);
END $do$;

-- (2) PREMISES: the anchors are what the fixture claims they are.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT 54, 'premise', jsonb_build_object(
  'out_on_shelf',  (SELECT count(*) FROM v_shelf_state
                     WHERE shelf_id='b6454a65-f4da-4c07-8570-b8791f687ee2'
                       AND pod_product_id='31186e1c-b61b-4d13-b520-052fb86725a3'
                       AND machine_id='9db7a821-d312-43b0-8e83-9642abfbfb0b'),
  'in_not_on_machine', (SELECT count(*) FROM v_shelf_state
                     WHERE machine_id='9db7a821-d312-43b0-8e83-9642abfbfb0b'
                       AND pod_product_id='cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77'),
  'dup_on_machine', (SELECT count(*) FROM v_shelf_state
                     WHERE machine_id='9db7a821-d312-43b0-8e83-9642abfbfb0b'
                       AND pod_product_id='27444f0d-7d3c-4480-bbdc-4faf60acbdbc'),
  'donor_has_pod', (SELECT COALESCE(max(current_stock),0) FROM v_shelf_state
                     WHERE machine_id='84386a8b-ba1c-4be1-aa51-a529203ecfb6'
                       AND pod_product_id='cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77'),
  'shelf_cap',     (SELECT COALESCE(max(max_stock),0) FROM v_shelf_state
                     WHERE shelf_id='b6454a65-f4da-4c07-8570-b8791f687ee2'));

-- (3) BASE RUN. The engine planned the OUTGOING pod on the shelf; the swap must
--     unmake that line and make the incoming one.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT 54, 'r1', to_jsonb(gen_random_uuid());

INSERT INTO public.pod_refills_shadow
  (run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id, qty,
   current_stock, max_stock, wh_available_pod, availability_basis, reasoning)
SELECT (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=54 AND key='r1'),
       'golden_f54_base', DATE '2030-02-24',
       '9db7a821-d312-43b0-8e83-9642abfbfb0b','b6454a65-f4da-4c07-8570-b8791f687ee2',
       '31186e1c-b61b-4d13-b520-052fb86725a3', 9, 5, 14, 99, 'boonz_wh',
       jsonb_build_object('golden','f54 base line for the outgoing pod');

-- A second, untouched control line on the dup shelf: the swap must be surgical.
INSERT INTO public.pod_refills_shadow
  (run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id, qty,
   current_stock, max_stock, wh_available_pod, availability_basis, reasoning)
SELECT (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=54 AND key='r1'),
       'golden_f54_base', DATE '2030-02-24',
       '9db7a821-d312-43b0-8e83-9642abfbfb0b','0b3cc2d5-8dce-495c-a6c0-278722bebd1f',
       '27444f0d-7d3c-4480-bbdc-4faf60acbdbc', 2, 4, 6, 99, 'boonz_wh',
       jsonb_build_object('golden','f54 untouched control line');

-- (4) THE SWAP. ⛔ every call wrapped: a throw must land as DATA, not as a
--     fixture abort (pointer landmine).
DO $do$
DECLARE r jsonb; v jsonb := '{}'::jsonb;
BEGIN
  IF to_regprocedure('public.swap_v3(date,uuid,uuid,uuid,text,integer,uuid)') IS NULL THEN
    INSERT INTO golden.scratch (fixture_id,key,value)
    VALUES (54,'swap', jsonb_build_object('status','absent'));
    RETURN;
  END IF;

  -- 4a happy path, same machine, explicit qty
  BEGIN
    EXECUTE 'SELECT public.swap_v3($1,$2,$3,$4,$5,$6,$7)'
      INTO r USING DATE '2030-02-24',
        '9db7a821-d312-43b0-8e83-9642abfbfb0b'::uuid,
        'b6454a65-f4da-4c07-8570-b8791f687ee2'::uuid,
        'cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77'::uuid,
        'golden fixture 54 same-machine swap of the A04 shelf', 11, NULL::uuid;
    v := v || jsonb_build_object('ok', r);
  EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('ok', jsonb_build_object('threw', SQLERRM));
  END;

  -- 4b the in-machine duplicate. CS rule 2026-07-31: must REFUSE.
  BEGIN
    EXECUTE 'SELECT public.swap_v3($1,$2,$3,$4,$5,$6,$7)'
      INTO r USING DATE '2030-02-24',
        '9db7a821-d312-43b0-8e83-9642abfbfb0b'::uuid,
        'b6454a65-f4da-4c07-8570-b8791f687ee2'::uuid,
        '27444f0d-7d3c-4480-bbdc-4faf60acbdbc'::uuid,
        'golden fixture 54 duplicate assortment must be refused', 5, NULL::uuid;
    v := v || jsonb_build_object('dup', jsonb_build_object('returned', r));
  EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('dup', jsonb_build_object('threw', SQLERRM));
  END;

  -- 4c swapping a pod for itself is not a swap.
  BEGIN
    EXECUTE 'SELECT public.swap_v3($1,$2,$3,$4,$5,$6,$7)'
      INTO r USING DATE '2030-02-24',
        '9db7a821-d312-43b0-8e83-9642abfbfb0b'::uuid,
        'b6454a65-f4da-4c07-8570-b8791f687ee2'::uuid,
        '31186e1c-b61b-4d13-b520-052fb86725a3'::uuid,
        'golden fixture 54 self swap must be refused', 5, NULL::uuid;
    v := v || jsonb_build_object('self', jsonb_build_object('returned', r));
  EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('self', jsonb_build_object('threw', SQLERRM));
  END;

  -- 4d shelf that does not belong to the named machine.
  BEGIN
    EXECUTE 'SELECT public.swap_v3($1,$2,$3,$4,$5,$6,$7)'
      INTO r USING DATE '2030-02-24',
        '84386a8b-ba1c-4be1-aa51-a529203ecfb6'::uuid,
        'b6454a65-f4da-4c07-8570-b8791f687ee2'::uuid,
        'cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77'::uuid,
        'golden fixture 54 shelf machine mismatch must be refused', 5, NULL::uuid;
    v := v || jsonb_build_object('mismatch', jsonb_build_object('returned', r));
  EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('mismatch', jsonb_build_object('threw', SQLERRM));
  END;

  -- 4e cross-machine source that genuinely holds the pod.
  BEGIN
    EXECUTE 'SELECT public.swap_v3($1,$2,$3,$4,$5,$6,$7)'
      INTO r USING DATE '2030-02-24',
        '9db7a821-d312-43b0-8e83-9642abfbfb0b'::uuid,
        '8539b03e-4628-4e26-bffe-6aa33c282b7a'::uuid,
        'cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77'::uuid,
        'golden fixture 54 cross machine swap sourced from a donor', 6,
        '84386a8b-ba1c-4be1-aa51-a529203ecfb6'::uuid;
    v := v || jsonb_build_object('cross', r);
  EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('cross', jsonb_build_object('threw', SQLERRM));
  END;

  INSERT INTO golden.scratch (fixture_id,key,value) VALUES (54,'swap', v);
END $do$;

-- (5) COMPOSE, TWICE. The overlay must survive a re-run (P3.6's whole point).
DO $do$
DECLARE r jsonb; v jsonb := '{}'::jsonb;
BEGIN
  BEGIN
    SELECT public.compose_plan_with_edits_v3(DATE '2030-02-24',
      (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=54 AND key='r1')) INTO r;
    v := v || jsonb_build_object('c1', r);
  EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('c1', jsonb_build_object('threw', SQLERRM));
  END;
  BEGIN
    SELECT public.compose_plan_with_edits_v3(DATE '2030-02-24',
      (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=54 AND key='r1')) INTO r;
    v := v || jsonb_build_object('c2', r);
  EXCEPTION WHEN OTHERS THEN v := v || jsonb_build_object('c2', jsonb_build_object('threw', SQLERRM));
  END;
  INSERT INTO golden.scratch (fixture_id,key,value) VALUES (54,'compose', v);
END $do$;

$scenario$);


INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required) VALUES

-- ---- premises (must be green even at RED baseline) ----
(54, 1, 'premise: outgoing pod sits on the anchor shelf of the anchor machine',
 $$SELECT (value->>'out_on_shelf') FROM golden.scratch WHERE fixture_id=54 AND key='premise'$$, 'eq','1','P3'),
(54, 2, 'premise: the incoming pod is NOT already assorted on the machine',
 $$SELECT (value->>'in_not_on_machine') FROM golden.scratch WHERE fixture_id=54 AND key='premise'$$, 'eq','0','P3'),
(54, 3, 'premise: the duplicate pod IS already assorted on the machine',
 $$SELECT (value->>'dup_on_machine') FROM golden.scratch WHERE fixture_id=54 AND key='premise'$$, 'gte','1','P3'),
(54, 4, 'premise: the donor machine really holds the incoming pod in stock',
 $$SELECT (value->>'donor_has_pod') FROM golden.scratch WHERE fixture_id=54 AND key='premise'$$, 'gte','1','P3'),
(54, 5, 'premise: the composer this fixture leans on exists',
 $$SELECT CASE WHEN (value->>'composer')='absent' THEN 'absent' ELSE 'present' END
     FROM golden.scratch WHERE fixture_id=54 AND key='struct'$$, 'eq','present','P3'),

-- ---- the verb itself ----
(54,10, 'swap_v3 exists with the BUILD-SPEC signature (plan_date, machine, shelf, new_pod, reason, qty?, cross_machine?)',
 $$SELECT CASE WHEN (value->>'verb')='absent' THEN 'absent' ELSE 'present' END
     FROM golden.scratch WHERE fixture_id=54 AND key='struct'$$, 'eq','present','P3'),
(54,11, 'swap_v3 is SECURITY DEFINER with a pinned search_path',
 $$SELECT CASE WHEN to_regprocedure('public.swap_v3(date,uuid,uuid,uuid,text,integer,uuid)') IS NULL THEN 'absent'
          ELSE (SELECT CASE WHEN p.prosecdef AND array_to_string(p.proconfig,',') LIKE '%search_path%'
                            THEN 'hardened' ELSE 'loose' END
                  FROM pg_proc p WHERE p.oid=to_regprocedure('public.swap_v3(date,uuid,uuid,uuid,text,integer,uuid)')) END$$,
 'eq','hardened','P3'),
(54,12, 'anon holds no privilege on the swap verb (S-88 fleet convention)',
 $$SELECT CASE WHEN to_regprocedure('public.swap_v3(date,uuid,uuid,uuid,text,integer,uuid)') IS NULL THEN 'absent'
          ELSE (SELECT COALESCE(has_function_privilege('anon', p.oid, 'EXECUTE')::text,'f')
                  FROM pg_proc p WHERE p.oid=to_regprocedure('public.swap_v3(date,uuid,uuid,uuid,text,integer,uuid)')) END$$,
 'eq','false','P3'),

-- ---- happy path: the two legs ----
(54,20, 'the same-machine swap returns ok',
 $$SELECT COALESCE(value->'ok'->>'status', value->>'status', 'absent')
     FROM golden.scratch WHERE fixture_id=54 AND key='swap'$$, 'eq','ok','P3'),
(54,21, 'it emitted exactly two legs',
 $$SELECT COALESCE(jsonb_array_length(value->'ok'->'legs')::text,'none')
     FROM golden.scratch WHERE fixture_id=54 AND key='swap'$$, 'eq','2','P3'),
(54,22, 'leg 1 is a drop of the OUTGOING pod on the anchor shelf',
 $$SELECT COALESCE((SELECT count(*)::text FROM public.v_plan_edits_active_v3
                     WHERE plan_date=DATE '2030-02-24'
                       AND shelf_id='b6454a65-f4da-4c07-8570-b8791f687ee2'
                       AND pod_product_id='31186e1c-b61b-4d13-b520-052fb86725a3'
                       AND kind='drop'),'0')$$, 'eq','1','P3'),
(54,23, 'leg 2 is an add of the INCOMING pod on the same shelf at the asked qty',
 $$SELECT COALESCE((SELECT count(*)::text FROM public.v_plan_edits_active_v3
                     WHERE plan_date=DATE '2030-02-24'
                       AND shelf_id='b6454a65-f4da-4c07-8570-b8791f687ee2'
                       AND pod_product_id='cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77'
                       AND kind='add' AND qty=11),'0')$$, 'eq','1','P3'),
(54,24, 'both legs are HARD locked: a human swap is not a suggestion the engine may undo',
 $$SELECT COALESCE((SELECT count(*)::text FROM public.v_plan_edits_active_v3
                     WHERE plan_date=DATE '2030-02-24'
                       AND shelf_id='b6454a65-f4da-4c07-8570-b8791f687ee2'
                       AND "lock"='hard'),'0')$$, 'eq','2','P3'),
(54,25, 'both legs carry ONE shared swap group so the pair is reviewable as one act',
 $$SELECT COALESCE((SELECT count(DISTINCT substring(reason from 'swap_group:[0-9a-f-]{36}'))::text
                      FROM public.v_plan_edits_active_v3
                     WHERE plan_date=DATE '2030-02-24'
                       AND shelf_id='b6454a65-f4da-4c07-8570-b8791f687ee2'),'0')$$, 'eq','1','P3'),

-- ---- the guards ----
(54,30, 'swapping in a pod already assorted on the machine is REFUSED (CS rule 2026-07-31)',
 $$SELECT CASE WHEN (value->'dup'->>'threw') IS NOT NULL THEN 'refused'
               WHEN (value->'dup'->'returned'->>'status')='refused' THEN 'refused'
               ELSE COALESCE(value->'dup'->'returned'->>'status','none') END
     FROM golden.scratch WHERE fixture_id=54 AND key='swap'$$, 'eq','refused','P3'),
(54,31, 'the duplicate refusal NAMES the duplicate rather than failing vaguely',
 $$SELECT CASE WHEN COALESCE(value->'dup'->>'threw', value->'dup'->'returned'->>'message','')
                    ILIKE '%already%' THEN 'named' ELSE 'vague' END
     FROM golden.scratch WHERE fixture_id=54 AND key='swap'$$, 'eq','named','P3'),
(54,32, 'swapping a pod for itself is REFUSED',
 $$SELECT CASE WHEN (value->'self'->>'threw') IS NOT NULL THEN 'refused'
               WHEN (value->'self'->'returned'->>'status')='refused' THEN 'refused'
               ELSE COALESCE(value->'self'->'returned'->>'status','none') END
     FROM golden.scratch WHERE fixture_id=54 AND key='swap'$$, 'eq','refused','P3'),
(54,33, 'a shelf that does not belong to the named machine is REFUSED (DATA-SOURCE LAW: shelf_id, never shelf_code)',
 $$SELECT CASE WHEN (value->'mismatch'->>'threw') IS NOT NULL THEN 'refused'
               WHEN (value->'mismatch'->'returned'->>'status')='refused' THEN 'refused'
               ELSE COALESCE(value->'mismatch'->'returned'->>'status','none') END
     FROM golden.scratch WHERE fixture_id=54 AND key='swap'$$, 'eq','refused','P3'),
(54,34, 'a refused swap writes NO edits: a rejected act leaves no residue',
 $$SELECT (SELECT count(*)::text FROM public.v_plan_edits_active_v3
            WHERE plan_date=DATE '2030-02-24'
              AND pod_product_id='27444f0d-7d3c-4480-bbdc-4faf60acbdbc'
              AND shelf_id='b6454a65-f4da-4c07-8570-b8791f687ee2')$$, 'eq','0','P3'),

-- ---- cross-machine ----
(54,40, 'the cross-machine swap returns ok',
 $$SELECT COALESCE(value->'cross'->>'status','absent')
     FROM golden.scratch WHERE fixture_id=54 AND key='swap'$$, 'eq','ok','P3'),
(54,41, 'it records the donor machine as the source rather than defaulting to the warehouse',
 $$SELECT COALESCE(value->'cross'->>'source_machine_id','none')
     FROM golden.scratch WHERE fixture_id=54 AND key='swap'$$,
 'eq','84386a8b-ba1c-4be1-aa51-a529203ecfb6','P3'),
(54,42, 'the cross-machine add leg names its donor in the reason, so pack can trace it',
 $$SELECT CASE WHEN EXISTS (SELECT 1 FROM public.v_plan_edits_active_v3
                             WHERE plan_date=DATE '2030-02-24'
                               AND shelf_id='8539b03e-4628-4e26-bffe-6aa33c282b7a'
                               AND pod_product_id='cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77'
                               AND reason ILIKE '%84386a8b%') THEN 'traced' ELSE 'untraced' END$$,
 'eq','traced','P3'),

-- ---- composition + re-run survival ----
(54,50, 'compose succeeds over the swapped plan',
 $$SELECT COALESCE(value->'c1'->>'status','absent')
     FROM golden.scratch WHERE fixture_id=54 AND key='compose'$$, 'eq','ok','P3'),
(54,51, 'the composed plan no longer carries the outgoing pod on the swapped shelf',
 $$SELECT (SELECT count(*)::text FROM public.pod_refills_shadow s
            WHERE s.run_id = ((SELECT value->'c1'->>'run_id' FROM golden.scratch
                                WHERE fixture_id=54 AND key='compose'))::uuid
              AND s.shelf_id='b6454a65-f4da-4c07-8570-b8791f687ee2'
              AND s.pod_product_id='31186e1c-b61b-4d13-b520-052fb86725a3')$$, 'eq','0','P3'),
(54,52, 'the composed plan carries the incoming pod at the swapped qty',
 $$SELECT COALESCE((SELECT sum(s.qty)::text FROM public.pod_refills_shadow s
            WHERE s.run_id = ((SELECT value->'c1'->>'run_id' FROM golden.scratch
                                WHERE fixture_id=54 AND key='compose'))::uuid
              AND s.shelf_id='b6454a65-f4da-4c07-8570-b8791f687ee2'
              AND s.pod_product_id='cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77'),'0')$$, 'eq','11','P3'),
(54,53, 'the untouched control shelf is unmoved: the swap was surgical',
 $$SELECT COALESCE((SELECT sum(s.qty)::text FROM public.pod_refills_shadow s
            WHERE s.run_id = ((SELECT value->'c1'->>'run_id' FROM golden.scratch
                                WHERE fixture_id=54 AND key='compose'))::uuid
              AND s.shelf_id='0b3cc2d5-8dce-495c-a6c0-278722bebd1f'),'0')$$, 'eq','2','P3'),
(54,54, 'RE-RUN PRESERVATION: a second compose applies the same swap, dropping nothing',
 $$SELECT COALESCE(value->'c2'->>'edits_applied','none')
     FROM golden.scratch WHERE fixture_id=54 AND key='compose'$$,
 'eq','4','P3'),
(54,55, 'the second compose yielded no swap leg (hard locks never yield)',
 $$SELECT COALESCE(value->'c2'->>'edits_yielded','none')
     FROM golden.scratch WHERE fixture_id=54 AND key='compose'$$, 'eq','0','P3'),

-- ---- LAW 4 tripwire ----
(54,90, 'LAW 4: the fixture wrote nothing to the LIVE plan table on its own date',
 $$SELECT (SELECT count(*)::text FROM public.refill_plan_output
            WHERE plan_date = DATE '2030-02-24')$$, 'eq','0','P3'),
(54,91, 'LAW 4: the fixture wrote no live pod_refill_plan rows on its own date',
 $$SELECT (SELECT count(*)::text FROM public.pod_refill_plan_shadow
            WHERE plan_date = DATE '2030-02-24')$$, 'eq','0','P3');
