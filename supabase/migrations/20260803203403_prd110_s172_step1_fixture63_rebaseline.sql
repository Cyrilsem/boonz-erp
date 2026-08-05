-- PRD-110 leg 100 / S-172 STEP 1 - fixture 63 re-baseline.
-- The four S-172 GAP assertions (52/53/54/55) pinned the CURRENT swallowed-refusal
-- behaviour DELIBERATELY, as a tripwire. Step 1 landed, so they SHOULD go red - that
-- is the tripwire working, not a regression. Re-pointed here at the DESIRED behaviour.
-- Seq 54 is additionally rebuilt to be signature-precise rather than a prosrc substring
-- count: the new message names p_force in prose, which would have made the old detector
-- report "step 2 shipped" when it had not (S-173: a detector that cannot distinguish is
-- the defect, whether it reads permanently red or vacuously green).

-- seq 52: the marker the operator actually sees
UPDATE golden.assertions SET
  expect      = 'PRE-FLIGHT REFUSED this commit (PRD-109',
  description = 'S-172 STEP 1 (now pinned as DESIRED behaviour): the operator sees the PRD-109 pre-flight refusal naming what stopped the commit, not the generic PRD-019 write_result rollback'
WHERE fixture_id = 63 AND seq = 52;

-- seq 53: the invariant id now survives all the way to the operator
UPDATE golden.assertions SET
  expect      = 'true',
  description = 'S-172 STEP 1: the refusal message carries the invariant id - the fix path fixture 63 seq 21/23 proves exists now reaches the operator instead of being swallowed'
WHERE fixture_id = 63 AND seq = 53;

-- seq 54: STEP 2 is still open. Detect the PARAMETER, not the word.
UPDATE golden.assertions SET
  check_sql   = $q$SELECT ((pg_get_function_identity_arguments(p.oid) NOT LIKE '%p_force%') AND p.pronargdefaults = 0)::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'commit_refill_plan_atomic'$q$,
  expect_op   = 'eq',
  expect      = 'true',
  description = 'S-172 STEP 2 STILL OPEN (signature-precise per S-173, immune to message prose): commit_refill_plan_atomic has NO p_force passthrough PARAMETER and no defaults, so the audited hatch remains unreachable from the only commit button the FE has'
WHERE fixture_id = 63 AND seq = 54;

-- seq 55: flipped from "the gap exists" to "step 1 shipped"
UPDATE golden.assertions SET
  expect_op   = 'gte',
  expect      = '1',
  check_sql   = $q$SELECT (SELECT count(*) FROM regexp_matches((SELECT p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'commit_refill_plan_atomic'), 'preflight_failed', 'g'))::text$q$,
  description = 'S-172 STEP 1 SHIPPED: commit_refill_plan_atomic handles the preflight_failed status itself instead of only ever seeing a missing write_result'
WHERE fixture_id = 63 AND seq = 55;

-- NEW 57/58: the two payload fields that matter, asserted on the BEHAVIOUR (the message
-- the probe actually captured), which is the positive control for the seq-55 source check.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
 (63, 57,
  'S-172 STEP 1: the message names the SPECIFIC invariant that stopped this commit (INV-06), not merely the shape of one',
  $q$SELECT value->'error'->>'message' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'atomic_block'$q$,
  'contains', 'INV-06', true, 'P2'),
 (63, 58,
  'S-172 STEP 1: the fix_path travels with the refusal, so the operator is told what to DO and not only what went wrong',
  $q$SELECT value->'error'->>'message' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'atomic_block'$q$,
  'contains', 'Re-run the stitch', true, 'P2'),
 (63, 59,
  'S-172 STEP 1 WAS ADDITIVE: the generic write_result guard is still in place, so a non-preflight stitch failure is still caught by the original PRD-019 E2 safety net',
  $q$SELECT (SELECT count(*) FROM regexp_matches((SELECT p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'commit_refill_plan_atomic'), 'write_result', 'g'))::text$q$,
  'gte', '1', true, 'P2');
