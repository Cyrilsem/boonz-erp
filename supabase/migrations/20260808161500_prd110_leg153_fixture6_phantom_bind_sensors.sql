-- PRD-110 leg 153 - UNIT A, fixture half. Fixture 6 keeps the reds it earned and gains the
-- regression sensors that make the defect uncatchable-by-accident next time.
--
-- Three of fixture 6's assertions were red BEFORE this leg touched anything (48/51, seqs
-- 30/31/38, isolation re-fire per S-283). Seq 31 and 38 go green on the code fix alone and
-- are not restated: they said the right thing and the system had stopped obeying them.
-- Seq 30 IS restated, because the binder now names a SHARPER reason than the one pinned.
--
-- ⛔ S-272: a restatement moves expect_op/expect WITH THE SHAPE. Seq 30's old shape was
-- "this exact literal reason"; the honest new shape is "one of the two legitimate no-supply
-- reasons", because which of the two applies depends on whether phantom rows happen to
-- exist on the day - and a fixed data problem must not red golden (leg 152, fixture 72
-- seq 27). The literal is therefore folded into a CASE and the assertion still eq's.

DO $mig$
DECLARE
  v_n            int;
  v_binder_md5   text;
  v_probe_token  text := $blk$'classifier'$blk$;
  v_old_bound    text := $blk$  'n_sentinel',   (SELECT count(*)::int FROM b WHERE b.batch LIKE 'VOXSOURCE-%'));$blk$;
  v_new_bound    text := $blk$  'n_sentinel',   (SELECT count(*)::int FROM b WHERE b.batch LIKE 'VOXSOURCE-%'),
  -- leg 153: the SHAPE-based twin of n_sentinel above. n_sentinel asks the NAME question and
  -- is NULL-blind by construction; this one asks the question that actually matters.
  'n_exp2099',    (SELECT count(*)::int FROM b WHERE b.exp = DATE '2099-12-31'));$blk$;
  v_probe        text := $blk$

-- ---------------------------------------------------------------------------
-- (7) leg 153: THE CLASSIFIER TRUTH TABLE, EXECUTED rather than inspected (S-273).
--     Guarded in the fixture-40 idiom so a missing object READS as absent instead of
--     throwing the whole scenario.
-- ---------------------------------------------------------------------------
DO $do$
BEGIN
  IF to_regprocedure('public._is_phantom_wh_row_v3(text,date)') IS NOT NULL THEN
    BEGIN
      EXECUTE $x$
        INSERT INTO golden.scratch (fixture_id, key, value)
        SELECT 6, 'classifier', jsonb_build_object(
          'null_batch_sentinel_exp', public._is_phantom_wh_row_v3(NULL, DATE '2099-12-31'),
          'named_sentinel',          public._is_phantom_wh_row_v3('VOXSOURCE-42', DATE '2099-12-31'),
          'real_named_batch',        public._is_phantom_wh_row_v3('BATCH-1', DATE '2027-01-01'),
          'null_batch_real_exp',     public._is_phantom_wh_row_v3(NULL, DATE '2027-01-01'),
          'both_null',               public._is_phantom_wh_row_v3(NULL, NULL))
      $x$;
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO golden.scratch (fixture_id, key, value)
      VALUES (6, 'classifier', jsonb_build_object('threw', SQLERRM));
    END;
  END IF;
END $do$;
$blk$;
BEGIN
  -- --------------------------------------------------------------- scenario, substituted
  SELECT (length(scenario_sql) - length(replace(scenario_sql, v_old_bound, ''))) / length(v_old_bound)
    INTO v_n FROM golden.fixtures WHERE fixture_id = 6;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'REFUSE: bound_wh anchor occurs % time(s) in fixture 6, expected exactly 1', v_n;
  END IF;

  -- Idempotence guard. Counted with substring arithmetic against the token's own measured
  -- length (S-291a), never a hardcoded divisor.
  SELECT (length(scenario_sql) - length(replace(scenario_sql, v_probe_token, ''))) / length(v_probe_token)
    INTO v_n FROM golden.fixtures WHERE fixture_id = 6;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'REFUSE: fixture 6 already carries a classifier probe (% occurrence(s))', v_n;
  END IF;

  UPDATE golden.fixtures
     SET scenario_sql = replace(scenario_sql, v_old_bound, v_new_bound) || v_probe
   WHERE fixture_id = 6;

  -- --------------------------------------------------------------- seq 30, RESTATED
  UPDATE golden.assertions SET
    check_sql = $sql$SELECT CASE WHEN (value->>'unbound_reason') IN ('no_pickable_batch_in_scope','all_batches_sentinel')
            THEN 'NO_SUPPLY_NAMED' ELSE COALESCE(value->>'unbound_reason','NULL') END
  FROM golden.scratch WHERE fixture_id=6 AND key='bind_far'$sql$,
    expect_op = 'eq',
    expect    = 'NO_SUPPLY_NAMED',
    description = 'LAW 7 ARTEFACT, PINNED: at the far-future plan_date the alt-WH binder finds nothing bindable and NAMES why rather than returning a bare verdict. RESTATED at leg 153 (was the literal no_pickable_batch_in_scope): once the phantom classifier became NULL-safe the binder started reporting the sharper all_batches_sentinel on this anchor, because the only row still in date range at 2030 IS a phantom. Both strings are legitimate no-supply reasons and which one applies depends on whether phantom rows exist that day, so the assertion pins the CLASS and treats a NULL or an unrecognised reason as the failure it is.'
  WHERE fixture_id = 6 AND seq = 30;

  -- --------------------------------------------------------------- seq 51, RE-DERIVED
  -- ⛔ S-109: md5(prosrc), never pg_get_functiondef. Derived from the applied object rather
  -- than typed, then CHECKED against the value the S-287 dry run measured - so a
  -- mis-transcribed migration 20260808161000 cannot silently pin its own mistake.
  SELECT md5(p.prosrc) INTO v_binder_md5
    FROM pg_proc p WHERE p.proname = 'resolve_fefo_sku_legs_v3'
     AND p.pronamespace = 'public'::regnamespace ORDER BY p.oid LIMIT 1;
  IF v_binder_md5 IS DISTINCT FROM '95301156c2f16a1446b424feab433c85' THEN
    RAISE EXCEPTION 'REFUSE: binder md5 is % but the leg-153 dry run measured 95301156c2f16a1446b424feab433c85 - the applied body is not the reviewed body', v_binder_md5;
  END IF;
  UPDATE golden.assertions SET
    expect = v_binder_md5,
    description = 'LAW 3: resolve_fefo_sku_legs_v3 carries the leg-153 body and no other. Restated at leg 153 (was 229a8970...): UNIT A switched the seam''s phantom test from _is_sentinel_wh_row_v3 (name AND expiry, NULL-blind) to _is_phantom_wh_row_v3 (either shape, NULL-safe). One anchor moved; every other byte is as pg_get_functiondef returned it. Any OTHER movement of this md5 is an unreviewed engine edit.'
  WHERE fixture_id = 6 AND seq = 51;

  -- --------------------------------------------------------------- new sensors 52..57
  INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES
  (6, 52, 'THE DEFECT ITSELF, PINNED BY SHAPE: not one batch the near-date binder bound carries the 2099-12-31 phantom marker. Seq 40 above asks the same question by NAME and is exactly the test that missed 5 rows holding 5,029 units - this is its shape-based twin and the two must both hold.',
   $sql$SELECT (value->>'n_exp2099') FROM golden.scratch WHERE fixture_id=6 AND key='bound_wh'$sql$, 'eq', '0', true, 'P3'),
  (6, 53, 'CLASSIFIER TRUTH TABLE (a): a NULL batch_id on a 2099-12-31 row IS phantom. This is the exact input that read FALSE before leg 153, because NULL AND true is NULL and the old COALESCE turned that into "real stock". Data-independent, so it stays honest after CS cleans the rows up.',
   $sql$SELECT (value->>'null_batch_sentinel_exp') FROM golden.scratch WHERE fixture_id=6 AND key='classifier'$sql$, 'eq', 'true', true, 'P3'),
  (6, 54, 'CLASSIFIER TRUTH TABLE (b): the NAMED VOXSOURCE sentinel is still classified phantom - widening the test did not lose the case it already caught.',
   $sql$SELECT (value->>'named_sentinel') FROM golden.scratch WHERE fixture_id=6 AND key='classifier'$sql$, 'eq', 'true', true, 'P3'),
  (6, 55, 'CLASSIFIER TRUTH TABLE (c), the over-classification guard: an ordinary named batch with a real expiry is NOT phantom. Without this the fix could pass by refusing everything.',
   $sql$SELECT (value->>'real_named_batch') FROM golden.scratch WHERE fixture_id=6 AND key='classifier'$sql$, 'eq', 'false', true, 'P3'),
  (6, 56, 'CLASSIFIER TRUTH TABLE (d): a NULL batch_id with a REAL expiry is NOT phantom. Live there are 11 such rows at CENTRAL holding 91 units of genuine stock, and this assertion is what stops a future tightening from writing them off as ghosts.',
   $sql$SELECT (value->>'null_batch_real_exp') FROM golden.scratch WHERE fixture_id=6 AND key='classifier'$sql$, 'eq', 'false', true, 'P3'),
  (6, 57, 'CLASSIFIER TRUTH TABLE (e), S-289 in its own words: both arguments NULL must answer FALSE and never NULL. An assertion that can go neither true nor false is the vacuous-green shape this whole class of defect hides in.',
   $sql$SELECT (value->>'both_null') FROM golden.scratch WHERE fixture_id=6 AND key='classifier'$sql$, 'eq', 'false', true, 'P3');

  -- --------------------------------------------------------------- fixture note
  UPDATE golden.fixtures SET notes = notes || '  ⛔ LEG 153 (UNIT A): fired in isolation BEFORE any leg-153 change this fixture read 48/51 - seqs 30, 31 and 38 were a PRE-EXISTING red that no leg had seen because fixture 6 had not been fired since leg 148''s sweep. Cause: _is_sentinel_wh_row_v3 required the VOXSOURCE NAME *and* the 2099-12-31 expiry, so 5 rows holding 5,029 units with a NULL batch_id were classified as REAL and the FEFO seam bound them - including 1,002 units at the anchor''s own primary warehouse, which is why the seq-38 mirror said ok. Seq 52..57 are the regression sensors. ⛔ STILL OPEN AND WIDER THAN THIS FIXTURE: wh_fefo_for_line filters no sentinels at all and push_plan_to_dispatch, receive_dispatch_line and record_actual_refill call it unguarded.'
   WHERE fixture_id = 6;
END $mig$;
