-- PRD-110 leg 112 · S-200 red set · fixture 2 seq 64 (class (B), re-derived live and CONFIRMED)
--
-- WHY seq 64 was red, measured live this leg:
--   split_family 24 · shelfstate_family 24 · split_raw_key 0 · split_total 544
--   The pinned constant was 26 (METRICS_REGISTRY line 229 records "family 26, 24 recover
--   velocity, the 2 that stay NULL are AMZ-1046 (D-13)" at the time of the S-37 fix).
--   The split view and v_shelf_state AGREE at 24, and split_total is still exactly 544.
--   ⭐ Nothing in the build moved: two alias shelves left the eligible fleet. The fact the
--   assertion exists to prove stayed true throughout -- only the photograph aged. That is
--   class (B), and S-200 filed it correctly.
--
-- WHAT seq 64 IS FOR: it is the NON-VACUITY guard for seq 60/61/62/63. If the alias family
-- were empty, seq 60 (s37_raw_key = 0), 61 (s37_family_null <= 2), 62 (s37_n_mismatch = 0)
-- and 63 (s37_single_w = 0) would ALL pass trivially. A hard-coded count of live rows is a
-- photograph, not an invariant -- but "> 0" alone would be weaker than what we can prove.
--
-- REMEDY (fixture 40's idiom, leg 111): re-express the RELATIONSHIP off the population that
-- already exists, and add the half the original never covered.
--   seq 64  -> non-vacuity, drift-immune: the alias family is a real, NON-EMPTY population.
--   seq 102 -> NEW CONSERVATION: the split view keeps EVERY alias shelf v_shelf_state has.
-- Together these are strictly STRONGER than "eq 26", which asserted nothing about
-- conservation and went red on ordinary fleet turnover.
-- ⛔ seq 102 without seq 64 would be satisfiable on 0 = 0 -- the exact green-at-zero defect
--    fixture 24 was fixed for this leg. The pair must move together.
--
-- ⚠️ PERF (S-26 / RISK 88, METRICS_REGISTRY line 229): v_shelf_instock_velocity_split_v3
--    costs ~20 s per evaluation and machine-scoping does NOT reduce it (the inner vel CTE is
--    MATERIALIZED). This migration therefore EXTENDS THE EXISTING SINGLE READ of `s` rather
--    than adding a second one. v_shelf_state costs ~113 ms, so pulling it in is free.

UPDATE golden.fixtures
SET scenario_sql = replace(
      scenario_sql,
      $old$  's37_single_w',    (SELECT count(*) FROM s WHERE split_method = 'single_shelf' AND w_instock <> 1.0));$old$,
      $new$  's37_single_w',    (SELECT count(*) FROM s WHERE split_method = 'single_shelf' AND w_instock <> 1.0),
  -- leg 112 (S-200 class (B)): the alias family stated as a RELATIONSHIP, not a photograph.
  's37_family_state',    (SELECT count(*) FROM public.v_shelf_state
                           WHERE pod_product_id IN ('168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid,
                                                    '51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid)),
  's37_family_vs_state', (SELECT count(*) FROM s
                           WHERE pod_product_id IN ('168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid,
                                                    '51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid))
                         - (SELECT count(*) FROM public.v_shelf_state
                             WHERE pod_product_id IN ('168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid,
                                                      '51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid)));$new$)
WHERE fixture_id = 2;

-- seq 64 RESTATED: non-vacuity, drift-immune. ⛔ Threshold is the POSITIVE form (gt 0), which
-- is the same form seq 27-31 use -- this is NOT a relaxation to gte 0.
UPDATE golden.assertions
SET check_sql   = 'SELECT value->>''s37_family'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf''',
    expect_op   = 'gt',
    expect      = '0',
    description = 'S-37 NON-VACUITY (ungated): the alias family is a real, NON-EMPTY population of shelves. Without this, seq 60/61/62/63 all go green vacuously on an empty family. ⛔ RESTATED leg 112 (S-200 class (B)): this was pinned at eq 26, a photograph of the fleet on the day the S-37 fix landed. It read 24 live -- two alias shelves left the eligible fleet while the split view and v_shelf_state stayed in perfect agreement, so the red carried no information about the build. Paired with seq 102, which supplies the conservation half; the two must move together, because seq 102 alone is satisfiable on 0 = 0.'
WHERE fixture_id = 2 AND seq = 64;

-- NEW: the conservation half seq 64 never covered.
INSERT INTO golden.assertions (fixture_id, seq, check_sql, expect_op, expect, description, enabled, phase_required)
VALUES
 (2, 102,
  'SELECT value->>''s37_family_vs_state'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf''',
  'eq', '0',
  'S-37 CONSERVATION (leg 112, the half seq 64 never covered): the split view carries EXACTLY the alias-family shelves that v_shelf_state carries -- no shelf in the merged Hunter/Hunter-Ridge family is silently dropped on the way through the split. This is what actually catches an S-37 regression, and unlike the old eq 26 it is immune to ordinary fleet turnover: both sides move together. Measured at restatement: split 24, v_shelf_state 24, delta 0.',
  true, 'P0');

-- ⛔ FAIL-LOUD GUARD. replace() is silent when the needle does not match: the scenario would
-- keep its old body, seq 102 would read a missing key, and the failure would surface far from
-- its cause. The migration body is ONE transaction (leg 111), so raising here costs nothing.
DO $guard$
DECLARE v_hits int;
BEGIN
  SELECT count(*) INTO v_hits FROM golden.fixtures
   WHERE fixture_id = 2 AND scenario_sql LIKE '%s37_family_vs_state%';
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'leg112 f2/64: scenario_sql replace() did not apply (hits=%). Needle drifted.', v_hits;
  END IF;
END $guard$;
