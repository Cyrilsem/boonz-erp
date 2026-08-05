-- PRD-110 P3.1a · golden fixture 39 — substitute selection is CATEGORY-FIRST, not Pearson-first
-- LAW 1: this fixture is applied and run RED before find_substitutes_for_shelf_v3 exists.
-- plan_date anchor = DATE '2030-01-01' + 39 = 2030-02-09.
--   (38 is DELIBERATELY never minted: it renders 2030-02-08, which fixture 37 claims internally.)
--
-- SOURCE INCIDENT (CS, 2026-07-31, BUILD-SPEC line 89): raw Pearson basket correlation finds
-- COMPLEMENTS (a chips buyer also buys Pepsi), not SUBSTITUTES. Live reproduction this leg:
--   machine 4b235d37 · anchor Fade Fit (Protein & Health Bars)
--   v1 rank 1 = Pepsi Regular (Soft Drinks)   <- literally the "must NOT yield Pepsi" case
--   ...while SIX in-category Protein & Health Bars candidates sit in stock, unassorted.
--
-- TWO ANCHORS, deliberately different, because ONE anchor cannot prove both rules:
--   (A) CATEGORY PATH  machine 4b235d37 / Fade Fit 733dcd39 - 6 in-category candidates exist,
--       so the correct answer IS in-category and the assertion is non-vacuous.
--   (B) FLAG PATH      machine 9db7a821 / Hunter Ridge 51e4600f - the CS incident machine.
--       ⛔ ALL FOUR of its Chips & Crisps pods holding WH stock are ALREADY on the machine, so
--       rule (2) removes every one and the correct v3 answer there is STILL cross-category,
--       but FLAGGED. A fixture demanding an in-category winner THERE would be unsatisfiable by
--       construction (an S-55 repeat). Seq 6 pins that 0 explicitly, so the trap stays visible.
--
-- Also flips golden.config.current_phase P2 -> P3. Inert today (zero P3 assertions existed
-- before this file); without it every assertion below SKIPS and the run reports vacuous.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes,
   enabled, baseline_status)
VALUES (
  39,
  'Substitute selection is CATEGORY-FIRST; cross-category only when nothing in-category, and then FLAGGED (P3.1a)',
  'CS 2026-07-31: Hunter Ridge OOS on a machine carrying cola+soft-drinks yielded Pepsi. Pearson finds complements, not substitutes. Reproduced live on 4b235d37/Fade Fit -> v1 rank 1 = Pepsi Regular.',
  'P3',
  DATE '2030-02-09',
$SCEN$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- ---------------------------------------------------------------------------
-- (1) POPULATION EVIDENCE, computed INDEPENDENTLY of the function under test.
--     This is what makes seq 5/6 real evidence rather than self-confirmation:
--     the candidate universe is re-derived here from base tables, so the fixture
--     can say "an in-category answer EXISTS on A and does NOT on B" without
--     asking the function whether it found one.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
WITH m AS (
  SELECT machine_id, primary_warehouse_id AS pw, secondary_warehouse_id AS sw
  FROM public.machines
  WHERE machine_id IN ('4b235d37-c388-478b-8f3f-49d50971fcc1'::uuid,
                       '9db7a821-d312-43b0-8e83-9642abfbfb0b'::uuid)
),
present AS (
  SELECT m.machine_id, sl.pod_product_id
    FROM m JOIN public.slot_lifecycle sl
      ON sl.machine_id = m.machine_id AND sl.archived = false AND sl.is_current = true
  UNION
  SELECT m.machine_id, v.pod_product_id
    FROM m JOIN public.v_live_shelf_stock v
      ON v.machine_id = m.machine_id AND v.pod_product_id IS NOT NULL AND v.current_stock > 0
),
gp AS (
  SELECT sl.pod_product_id, AVG(sl.velocity_30d)::numeric AS g
    FROM public.slot_lifecycle sl
   WHERE sl.archived = false AND sl.is_current = true
   GROUP BY 1
),
wh AS (
  -- Mirrors v1's dedupe EXACTLY: DISTINCT over (pod, boonz) AFTER the machine filter, so a pod
  -- that carries both a global and a machine-specific mapping row is summed once, not twice.
  -- (Deduping over (pod, boonz, machine_id) instead re-introduces the product_mapping fan-out.)
  SELECT m.machine_id, pm.pod_product_id, SUM(wi.warehouse_stock)::numeric AS s
    FROM m
    JOIN LATERAL (SELECT DISTINCT pm0.pod_product_id, pm0.boonz_product_id
                    FROM public.product_mapping pm0
                   WHERE pm0.status = 'Active'
                     AND (pm0.machine_id IS NULL OR pm0.machine_id = m.machine_id)) pm ON true
    JOIN public.warehouse_inventory wi
      ON wi.boonz_product_id = pm.boonz_product_id
     AND wi.status = 'Active' AND wi.quarantined = false
     AND (wi.expiration_date >= CURRENT_DATE OR wi.expiration_date IS NULL)
     AND wi.warehouse_id IN (m.pw, m.sw)
     AND (wi.reserved_for_machine_id IS NULL OR wi.reserved_for_machine_id = m.machine_id)
   GROUP BY 1, 2
),
cand AS (
  SELECT w.machine_id, w.pod_product_id, pp.product_category AS cat
    FROM wh w
    JOIN gp ON gp.pod_product_id = w.pod_product_id AND gp.g > 0
    JOIN public.pod_products pp
      ON pp.pod_product_id = w.pod_product_id AND COALESCE(pp.is_catchall, false) = false
   WHERE w.s > 0
     AND NOT EXISTS (SELECT 1 FROM present p
                      WHERE p.machine_id = w.machine_id AND p.pod_product_id = w.pod_product_id)
     AND NOT EXISTS (SELECT 1 FROM public.strategic_intents si
                      WHERE si.intent_type = 'decommission'
                        AND si.status IN ('queued','in_progress')
                        AND si.scope_pod_product_id = w.pod_product_id)
)
SELECT {{fixture_id}}, 'population', jsonb_build_object(
  'cat_incat',  (SELECT count(*) FROM cand WHERE machine_id = '4b235d37-c388-478b-8f3f-49d50971fcc1'
                   AND cat = 'Protein & Health Bars'),
  'cat_total',  (SELECT count(*) FROM cand WHERE machine_id = '4b235d37-c388-478b-8f3f-49d50971fcc1'),
  'flag_incat', (SELECT count(*) FROM cand WHERE machine_id = '9db7a821-d312-43b0-8e83-9642abfbfb0b'
                   AND cat = 'Chips & Crisps'),
  'flag_total', (SELECT count(*) FROM cand WHERE machine_id = '9db7a821-d312-43b0-8e83-9642abfbfb0b'),
  'present_cat',  (SELECT jsonb_agg(DISTINCT pod_product_id) FROM present
                    WHERE machine_id = '4b235d37-c388-478b-8f3f-49d50971fcc1'),
  'present_flag', (SELECT jsonb_agg(DISTINCT pod_product_id) FROM present
                    WHERE machine_id = '9db7a821-d312-43b0-8e83-9642abfbfb0b')
);

-- ---------------------------------------------------------------------------
-- (2) THE v1 INCIDENT WITNESS. v1 is NOT being fixed (LAW 3: engine_swap_pod and
--     compute_nowh_proposals consume it and Phase 3 has not earned the right to
--     change swap behaviour). It is recorded so the fixture carries the RED it
--     was born from, and so seq 20/21 can prove v1 stayed byte-identical.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb;
BEGIN
  IF to_regprocedure('public.find_substitutes_for_shelf(date,uuid,uuid,uuid,integer,integer)') IS NULL
  THEN RETURN; END IF;
  EXECUTE $q$
    SELECT jsonb_agg(jsonb_build_object('rank', f.rank, 'name', f.pod_product_name,
                                        'cat', pp.product_category) ORDER BY f.rank)
      FROM public.find_substitutes_for_shelf(
             DATE '2030-02-09', '4b235d37-c388-478b-8f3f-49d50971fcc1'::uuid, NULL::uuid,
             '733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid, 4, 50) f
      JOIN public.pod_products pp ON pp.pod_product_id = f.pod_product_id $q$ INTO v;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (39, 'v1_top4', v);
END $do$;

-- ---------------------------------------------------------------------------
-- (3) THE SUBJECT. Guarded on to_regprocedure so a pre-existence baseline is a
--     clean RED (scratch keys simply ABSENT -> every v3 assertion NULL -> fail),
--     never a scenario ERROR. One call per anchor, stored whole, so that every
--     assertion below reads the SAME snapshot and cannot disagree with itself.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_cat jsonb; v_flag jsonb; v_d1 text; v_d2 text; v_v3_ids jsonb; v_v1_ids jsonb;
BEGIN
  IF to_regprocedure('public.find_substitutes_for_shelf_v3(date,uuid,uuid,uuid,integer,integer)') IS NULL
  THEN RETURN; END IF;

  -- (A) category path
  EXECUTE $q$
    SELECT jsonb_agg(to_jsonb(f) ORDER BY f.rank)
      FROM public.find_substitutes_for_shelf_v3(
             DATE '2030-02-09', '4b235d37-c388-478b-8f3f-49d50971fcc1'::uuid, NULL::uuid,
             '733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid, 8, 50) f $q$ INTO v_cat;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (39, 'v3_cat', COALESCE(v_cat, '[]'::jsonb));

  -- (B) flag path — the CS incident machine
  EXECUTE $q$
    SELECT jsonb_agg(to_jsonb(f) ORDER BY f.rank)
      FROM public.find_substitutes_for_shelf_v3(
             DATE '2030-02-09', '9db7a821-d312-43b0-8e83-9642abfbfb0b'::uuid, NULL::uuid,
             '51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid, 8, 50) f $q$ INTO v_flag;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (39, 'v3_flag', COALESCE(v_flag, '[]'::jsonb));

  -- (C) DETERMINISM (STRESS S7 requires run_all x3 identical). Two calls, one statement
  --     apart, digested. A ranking whose ties are not broken deterministically drifts here.
  EXECUTE $q$
    SELECT md5(string_agg(f.pod_product_id::text || ':' || f.rank::text, '|' ORDER BY f.rank))
      FROM public.find_substitutes_for_shelf_v3(
             DATE '2030-02-09', '4b235d37-c388-478b-8f3f-49d50971fcc1'::uuid, NULL::uuid,
             '733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid, 8, 50) f $q$ INTO v_d1;
  EXECUTE $q$
    SELECT md5(string_agg(f.pod_product_id::text || ':' || f.rank::text, '|' ORDER BY f.rank))
      FROM public.find_substitutes_for_shelf_v3(
             DATE '2030-02-09', '4b235d37-c388-478b-8f3f-49d50971fcc1'::uuid, NULL::uuid,
             '733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid, 8, 50) f $q$ INTO v_d2;
  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (39, 'determinism', jsonb_build_object('d1', v_d1, 'd2', v_d2));

  -- (D) ELIGIBILITY PARITY. v3 is a RE-RANKING, not a re-filtering: with p_top_n wide
  --     open the candidate SET must be identical to v1's. This is what stops a "fix"
  --     that quietly drops candidates in order to look category-clean.
  EXECUTE $q$
    SELECT jsonb_agg(x ORDER BY x)
      FROM (SELECT f.pod_product_id::text AS x
              FROM public.find_substitutes_for_shelf_v3(
                     DATE '2030-02-09', '4b235d37-c388-478b-8f3f-49d50971fcc1'::uuid, NULL::uuid,
                     '733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid, 500, 50) f) s $q$ INTO v_v3_ids;
  EXECUTE $q$
    SELECT jsonb_agg(x ORDER BY x)
      FROM (SELECT f.pod_product_id::text AS x
              FROM public.find_substitutes_for_shelf(
                     DATE '2030-02-09', '4b235d37-c388-478b-8f3f-49d50971fcc1'::uuid, NULL::uuid,
                     '733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid, 500, 50) f) s $q$ INTO v_v1_ids;
  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (39, 'parity', jsonb_build_object(
            'v3_n', jsonb_array_length(COALESCE(v_v3_ids,'[]'::jsonb)),
            'v1_n', jsonb_array_length(COALESCE(v_v1_ids,'[]'::jsonb)),
            'identical', (COALESCE(v_v3_ids,'[]'::jsonb) = COALESCE(v_v1_ids,'[]'::jsonb))));
END $do$;
$SCEN$,
  'P3.1a substitute-product selection. Pins CS rules (1) same-category-first, (2) never re-offer what the machine already carries, (3) rank on performance x stock with Pearson as an in-category tiebreak only. Also pins: cross-category is legal ONLY when nothing in-category qualifies and is then flagged; v1 stays byte-identical; v3 re-ranks without re-filtering; ties break deterministically for S7.',
  true,
  'failing_expected'
);

INSERT INTO golden.assertions
  (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES

-- ---- drift guards: if any of these move, every number below means something else ----
(39, 1, 'Drift guard: {{plan_date}} still renders as the fixture-39 anchor 2030-02-09',
 $q$SELECT {{plan_date}}::text$q$, 'eq', '2030-02-09', true, 'P3'),

(39, 2, 'Anchor guard (A): Fade Fit 733dcd39 is still categorised Protein & Health Bars',
 $q$SELECT product_category FROM public.pod_products
    WHERE pod_product_id = '733dcd39-dd50-4446-b1e4-5b36afbdf72a'$q$,
 'eq', 'Protein & Health Bars', true, 'P3'),

(39, 3, 'Anchor guard (B): Hunter Ridge 51e4600f is still categorised Chips & Crisps',
 $q$SELECT product_category FROM public.pod_products
    WHERE pod_product_id = '51e4600f-2c15-428b-92ef-85fdc783c3af'$q$,
 'eq', 'Chips & Crisps', true, 'P3'),

(39, 4, 'Anchor guard: both anchor machines are still Active',
 $q$SELECT count(*)::text FROM public.machines
    WHERE machine_id IN ('4b235d37-c388-478b-8f3f-49d50971fcc1'::uuid,
                         '9db7a821-d312-43b0-8e83-9642abfbfb0b'::uuid)
      AND status = 'Active'$q$,
 'eq', '2', true, 'P3'),

-- ---- population: the two paths are the two paths, proven independently ----
(39, 5, 'NON-VACUITY (A): the category path is SATISFIABLE - in-category candidates exist on 4b235d37',
 $q$SELECT (value->>'cat_incat') FROM golden.scratch
    WHERE fixture_id = {{fixture_id}} AND key = 'population'$q$,
 'gte', '1', true, 'P3'),

(39, 6, 'THE S-55 TRAP, PINNED (B): 9db7a821 has ZERO in-category candidates, so cross-category IS the right answer there',
 $q$SELECT (value->>'flag_incat') FROM golden.scratch
    WHERE fixture_id = {{fixture_id}} AND key = 'population'$q$,
 'eq', '0', true, 'P3'),

(39, 7, 'NON-VACUITY (B): 9db7a821 still has SOME eligible candidate (a selector with nothing to select proves nothing)',
 $q$SELECT (value->>'flag_total') FROM golden.scratch
    WHERE fixture_id = {{fixture_id}} AND key = 'population'$q$,
 'gte', '1', true, 'P3'),

(39, 8, 'INCIDENT WITNESS: v1 was actually consulted on the anchor and returned rows',
 $q$SELECT jsonb_array_length(value)::text FROM golden.scratch
    WHERE fixture_id = {{fixture_id}} AND key = 'v1_top4'$q$,
 'gte', '1', true, 'P3'),

-- ---- the object ----
(39, 9, 'OBJECT: find_substitutes_for_shelf_v3 exists with the pinned 6-arg signature',
 $q$SELECT golden.probe_scalar($p$SELECT to_regprocedure('public.find_substitutes_for_shelf_v3(date,uuid,uuid,uuid,integer,integer)')::text$p$)$q$,
 'contains', 'find_substitutes_for_shelf_v3', true, 'P3'),

(39, 10, 'OBJECT: v3 returns the category contract columns (product_category, category_match, requires_cs_review)',
 $q$SELECT golden.probe_scalar($p$SELECT (pg_get_function_result(oid) LIKE '%product_category%'
        AND pg_get_function_result(oid) LIKE '%category_match%'
        AND pg_get_function_result(oid) LIKE '%requires_cs_review%')::text
      FROM pg_proc WHERE proname = 'find_substitutes_for_shelf_v3'$p$)$q$,
 'eq', 'true', true, 'P3'),

(39, 11, 'NON-VACUITY: the v3 category-path call returned rows',
 $q$SELECT jsonb_array_length(value)::text FROM golden.scratch
    WHERE fixture_id = {{fixture_id}} AND key = 'v3_cat'$q$,
 'gte', '1', true, 'P3'),

-- ---- CS RULE (1): SAME CATEGORY FIRST ----
(39, 12, 'RULE 1 (A): rank 1 on the category path is IN CATEGORY',
 $q$SELECT (value->0->>'category_match') FROM golden.scratch
    WHERE fixture_id = {{fixture_id}} AND key = 'v3_cat'$q$,
 'eq', 'true', true, 'P3'),

(39, 13, 'RULE 1 (A): rank 1 carries the anchor category by name, not merely a true flag',
 $q$SELECT (value->0->>'product_category') FROM golden.scratch
    WHERE fixture_id = {{fixture_id}} AND key = 'v3_cat'$q$,
 'eq', 'Protein & Health Bars', true, 'P3'),

(39, 14, 'THE CS SENTENCE, LITERALLY: rank 1 is NOT a soft drink (v1 answered Pepsi Regular here)',
 $q$SELECT (COALESCE(value->0->>'product_category','') = 'Soft Drinks')::text FROM golden.scratch
    WHERE fixture_id = {{fixture_id}} AND key = 'v3_cat'$q$,
 'eq', 'false', true, 'P3'),

(39, 15, 'RULE 1 ORDERING INVARIANT: no cross-category row outranks any in-category row',
 $q$SELECT (
    COALESCE((SELECT max((e->>'rank')::int) FROM golden.scratch s,
                     jsonb_array_elements(s.value) e
               WHERE s.fixture_id = {{fixture_id}} AND s.key = 'v3_cat'
                 AND (e->>'category_match')::boolean), 0)
    <
    COALESCE((SELECT min((e->>'rank')::int) FROM golden.scratch s,
                     jsonb_array_elements(s.value) e
               WHERE s.fixture_id = {{fixture_id}} AND s.key = 'v3_cat'
                 AND NOT (e->>'category_match')::boolean), 2147483647)
   )::text$q$,
 'eq', 'true', true, 'P3'),

-- ---- CS RULE (2): never re-offer what the machine already carries ----
(39, 16, 'RULE 2 (A): zero returned rows are already assorted on 4b235d37',
 $q$SELECT count(*)::text
      FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id = {{fixture_id}} AND s.key = 'v3_cat'
       AND (e->>'pod_product_id') IN (
             SELECT jsonb_array_elements_text(p.value->'present_cat')
               FROM golden.scratch p
              WHERE p.fixture_id = {{fixture_id}} AND p.key = 'population')$q$,
 'eq', '0', true, 'P3'),

(39, 17, 'RULE 2 (B): zero returned rows are already assorted on 9db7a821',
 $q$SELECT count(*)::text
      FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id = {{fixture_id}} AND s.key = 'v3_flag'
       AND (e->>'pod_product_id') IN (
             SELECT jsonb_array_elements_text(p.value->'present_flag')
               FROM golden.scratch p
              WHERE p.fixture_id = {{fixture_id}} AND p.key = 'population')$q$,
 'eq', '0', true, 'P3'),

(39, 18, 'RULE 2: the anchor product never proposes itself',
 $q$SELECT count(*)::text
      FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id = {{fixture_id}} AND s.key IN ('v3_cat','v3_flag')
       AND (e->>'pod_product_id') IN ('733dcd39-dd50-4446-b1e4-5b36afbdf72a',
                                      '51e4600f-2c15-428b-92ef-85fdc783c3af')$q$,
 'eq', '0', true, 'P3'),

-- ---- the FLAG path ----
(39, 19, 'NON-VACUITY (B): the v3 flag-path call returned rows',
 $q$SELECT jsonb_array_length(value)::text FROM golden.scratch
    WHERE fixture_id = {{fixture_id}} AND key = 'v3_flag'$q$,
 'gte', '1', true, 'P3'),

(39, 20, 'FLAG PATH: with nothing in-category, EVERY row on 9db7a821 is cross-category',
 $q$SELECT count(*)::text
      FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id = {{fixture_id}} AND s.key = 'v3_flag'
       AND (e->>'category_match')::boolean$q$,
 'eq', '0', true, 'P3'),

(39, 21, 'FLAG PATH: and EVERY one of them is flagged for CS (a beverage-for-snack swap is never silent)',
 $q$SELECT count(*)::text
      FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id = {{fixture_id}} AND s.key = 'v3_flag'
       AND NOT (e->>'requires_cs_review')::boolean$q$,
 'eq', '0', true, 'P3'),

(39, 22, 'NO FALSE ALARM: on the category path the in-category rows are NOT flagged',
 $q$SELECT count(*)::text
      FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id = {{fixture_id}} AND s.key = 'v3_cat'
       AND (e->>'category_match')::boolean
       AND (e->>'requires_cs_review')::boolean$q$,
 'eq', '0', true, 'P3'),

(39, 23, 'FLAG INVARIANT: requires_cs_review is never true on an in-category row, either anchor',
 $q$SELECT count(*)::text
      FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id = {{fixture_id}} AND s.key IN ('v3_cat','v3_flag')
       AND (e->>'category_match')::boolean AND (e->>'requires_cs_review')::boolean$q$,
 'eq', '0', true, 'P3'),

-- ---- S-59: a fragmented taxonomy must not be papered over ----
(39, 24, 'S-59 GUARD: a NULL product_category never counts as a category match',
 $q$SELECT count(*)::text
      FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id = {{fixture_id}} AND s.key IN ('v3_cat','v3_flag')
       AND (e->>'category_match')::boolean AND (e->>'product_category') IS NULL$q$,
 'eq', '0', true, 'P3'),

-- ---- rank/top_n hygiene ----
(39, 25, 'CONTRACT: p_top_n is respected (8 requested)',
 $q$SELECT jsonb_array_length(value)::text FROM golden.scratch
    WHERE fixture_id = {{fixture_id}} AND key = 'v3_cat'$q$,
 'lte', '8', true, 'P3'),

(39, 26, 'CONTRACT: ranks are a dense 1..n sequence with no duplicates',
 $q$SELECT (count(DISTINCT (e->>'rank')) = jsonb_array_length(s.value)
          AND min((e->>'rank')::int) = 1
          AND max((e->>'rank')::int) = jsonb_array_length(s.value))::text
      FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id = {{fixture_id}} AND s.key = 'v3_cat'
     GROUP BY s.value$q$,
 'eq', 'true', true, 'P3'),

-- ---- STRESS S7 pre-clearance ----
(39, 27, 'S7 DETERMINISM: two consecutive v3 calls produce an identical ranking digest',
 $q$SELECT ((value->>'d1') = (value->>'d2') AND (value->>'d1') IS NOT NULL)::text
      FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'determinism'$q$,
 'eq', 'true', true, 'P3'),

-- ---- v3 RE-RANKS, it does not RE-FILTER ----
(39, 28, 'ELIGIBILITY PARITY: with top_n wide open, v3 returns exactly v1 candidate set',
 $q$SELECT (value->>'identical') FROM golden.scratch
    WHERE fixture_id = {{fixture_id}} AND key = 'parity'$q$,
 'eq', 'true', true, 'P3'),

(39, 29, 'ELIGIBILITY PARITY is non-vacuous: the shared candidate set is not empty',
 $q$SELECT (value->>'v3_n') FROM golden.scratch
    WHERE fixture_id = {{fixture_id}} AND key = 'parity'$q$,
 'gte', '2', true, 'P3'),

-- ---- LAW 3: versioned addition. v1 is UNTOUCHED. ----
(39, 30, 'LAW 3: v1 find_substitutes_for_shelf is byte-identical (engine_swap_pod consumes it)',
 $q$SELECT md5(prosrc) FROM pg_proc WHERE proname = 'find_substitutes_for_shelf'$q$,
 'eq', '8486ff042e91a3e42e862a395e205551', true, 'P3'),

(39, 31, 'LAW 3: v1 keeps its exact signature and its two live consumers still resolve',
 $q$SELECT count(*)::text FROM pg_proc
    WHERE prosrc LIKE '%find_substitutes_for_shelf%'
      AND proname IN ('engine_swap_pod','compute_nowh_proposals')$q$,
 'eq', '2', true, 'P3'),

(39, 32, 'MECHANISM WITNESS: v1 is structurally category-blind - no category column in its result type',
 $q$SELECT (pg_get_function_result(oid) LIKE '%category%')::text
      FROM pg_proc WHERE proname = 'find_substitutes_for_shelf'$q$,
 'eq', 'false', true, 'P3'),

-- ---- S-57 lesson applied FORWARD: a new object ships tight, and the pin proves it ----
(39, 33, 'S-57: v3 is NOT executable by anon (a GRANT adds; only a REVOKE narrows)',
 $q$SELECT golden.probe_scalar($p$SELECT has_function_privilege('anon',
      'public.find_substitutes_for_shelf_v3(date,uuid,uuid,uuid,integer,integer)', 'EXECUTE')::text$p$)$q$,
 'eq', 'false', true, 'P3'),

(39, 34, 'S-57: v3 IS executable by authenticated (tightening must not break the app)',
 $q$SELECT golden.probe_scalar($p$SELECT has_function_privilege('authenticated',
      'public.find_substitutes_for_shelf_v3(date,uuid,uuid,uuid,integer,integer)', 'EXECUTE')::text$p$)$q$,
 'eq', 'true', true, 'P3'),

-- ---- D-20 correction: margin IS available at pod grain ----
(39, 35, 'D-20 CORRECTION: unit_margin is populated for at least one candidate (pod_products.purchasing_cost exists)',
 $q$SELECT count(*)::text
      FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id = {{fixture_id}} AND s.key = 'v3_cat'
       AND (e->>'unit_margin') IS NOT NULL$q$,
 'gte', '1', true, 'P3'),

(39, 36, 'LAW 4 / no side effects: a selector writes nothing to the live plan table',
 $q$SELECT count(*)::text FROM public.pod_refill_plan WHERE plan_date = {{plan_date}}$q$,
 'eq', '0', true, 'P3'),

-- seq 16/17 are only meaningful if the machines actually carry an assortment to exclude.
(39, 37, 'NON-VACUITY for RULE 2: both anchor machines carry a non-empty present set to exclude',
 $q$SELECT (jsonb_array_length(COALESCE(value->'present_cat','[]'::jsonb)) > 0
          AND jsonb_array_length(COALESCE(value->'present_flag','[]'::jsonb)) > 0)::text
      FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'population'$q$,
 'eq', 'true', true, 'P3');

-- Flip the harness into P3. Inert on landing (verified live this leg: zero P3 assertions existed
-- before this file); without it every assertion above SKIPS and fixture 39 reports vacuous,
-- which by golden.run_fixture's guard-3 cannot pass.
UPDATE golden.config
   SET current_phase = 'P3',
       note = 'PRD-110 leg 55: Phases 0/1/2 CLOSED and checkpointed. Advancing to P3 (P3.1a substitution ladder). Flip was inert on landing - fixture 39 minted the first P3 assertions in the same migration.',
       updated_at = now()
 WHERE id = 1;
