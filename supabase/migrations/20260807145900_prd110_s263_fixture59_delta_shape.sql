-- PRD-110 · S-263 · fixture 59 stops measuring a live population it no longer owns
--
-- THE DEFECT (leg 141, re-derived leg 142, RE-RE-DERIVED leg 143 against the live
-- view because both earlier lists were REASONED, not observed - and by S-266 they
-- could not have been observed).
--
-- Fixture 59 was authored (leg 88) when every proposal row fleet-wide was
-- synthetic. It therefore states ABSOLUTE live_* counts: "AFTER: the 8 planted
-- pre-epoch rows land in live_rows = 8". DR-5 made the miners live on 2026-08-06
-- and the world moved under it:
--   · feedback_pins  live_rows 8 (8 real pending proposals CS is meant to review)
--   · picker_weights live_rows 1, live_accepted 1, live_acceptance_pct 100.00
--                    (DR-5's APPLIED w_empty 0.900 -> 0.945 proposal)
--   · rotation       live_rows 0 today - DR-7's heartbeat first fires 2026-08-09
--
-- ⛔ THE TRUE RED SET IS WIDER THAN EITHER EARLIER LIST. Leg 141 named seq
-- 5/10/20/45 + 14/23/29/46. Leg 142 added seq 12. Observed live this leg, the
-- fixture would today fail seq 5, 10, 12, 14, 20, 23 and 29 - and seq
-- 6/11/13/15/17/18/19/21/22/24/27/28/30/33/45/46 are green ONLY by luck: the 8
-- real feedback proposals all happen to be `pending`, and the other fixtures
-- happen to hold their counts. The moment CS decides ONE real proposal, or
-- fixture 58's S-262 treadmill turns once more, or DR-7 fires on Sunday, they
-- move. THIS IS ONE DEFECT CLASS, NOT EIGHT BUGS.
--
-- THE FIX - one rule, applied uniformly, so the fixture measures its OWN
-- contribution instead of the world's population:
--   absolute live_*   -> DELTA               after.X - before.X = <our plant>
--   absolute fixture_*-> STABILITY           after.X = before.X (several
--                                            descriptions ALREADY say "UNMOVED")
--   rendered rate     -> FORMULA             pct = round(100*acc/decided, 2)
--                                            AND the rate OUR delta implies
--   literal verdict   -> FORMULA-CONSISTENCY view = g12_verdict_v3(own inputs)
--                                            AND the verdict OUR delta implies
--   FINAL: X = 0      -> final.X = before.X  strictly STRONGER: proves the
--                                            fixture RESTORED the baseline
--
-- ⭐ NOTHING IS WEAKENED. Every original numeric claim (8, 5, 4, 1, 2, 80.00,
-- 20.00, pass, fail, insufficient_evidence) survives verbatim - it is now made
-- about the fixture's own delta rather than about a population it shares.
--
-- ⛔ THE scenario_sql CHANGE IS MANDATORY - no assertion edit alone can make this
-- fixture run. Its foreign-row guard RAISEs on exactly the situation that is now
-- permanent (real pre-epoch rows exist), and by S-266 that RAISE rolls back the
-- scenario's own `DELETE FROM golden.scratch`, so all 53 assertions re-evaluate
-- the PREVIOUS run's snapshot and report GREEN over nothing. The guard is deleted
-- outright. In its place: a `before_sentinel` scratch key capturing rows on the
-- 1999 sentinel immediately after the reclaim - the one absolute this fixture may
-- still legitimately make ("nothing of OURS survived the last run"), and seq 5.
--
-- ⚠️ AFTER THIS MIGRATION seq 5 IS THE ONLY ABSOLUTE LEFT IN THE FIXTURE. That is
-- intentional. Do not re-introduce another.


DO $mig$
DECLARE
  v_old text; v_new text;
BEGIN
  SELECT scenario_sql INTO v_new FROM golden.fixtures WHERE fixture_id = 59;
  IF v_new IS NULL THEN RAISE EXCEPTION 'S-263: fixture 59 has no scenario_sql'; END IF;
  v_old := v_new;

  ----------------------------------------------------------- R1: declarations --
  v_new := replace(v_new,
$o1$  d_live  date := DATE '1999-01-01';
  v_epoch date;
  v_m     uuid;$o1$,
$n1$  d_live  date := DATE '1999-01-01';
  v_m     uuid;$n1$);

  v_new := replace(v_new,
$o2$  v_foreign int;
  v_before jsonb; v_after jsonb; v_final jsonb;$o2$,
$n2$  v_before jsonb; v_after jsonb; v_final jsonb;
  v_sentinel int;$n2$);

  --------- R2: the now-unused epoch read -> the sentinel MEASUREMENT (pre-reclaim) --
  -- ⛔ CODY REQUIRED REVISION. The banked leg-142 design said "record
  -- before_sentinel immediately AFTER the reclaim". Taken there the count is 0 BY
  -- CONSTRUCTION - the reclaim has just deleted exactly the rows it counts - and
  -- seq 5, the only absolute the fixture is allowed to keep, would assert nothing
  -- at all. The measurement goes BEFORE the reclaim; only the scratch INSERT has
  -- to wait, because `DELETE FROM golden.scratch` runs inside the reclaim.
  v_new := replace(v_new,
$o3$  SELECT g12_fixture_epoch INTO v_epoch
    FROM public.refill_policy_params ORDER BY id LIMIT 1;

  ------------------------------------------------------------------ reclaim --$o3$,
$n3$  ------------------------------------------- S-263: measured BEFORE the reclaim --
  -- ⛔ THE ORDER IS THE WHOLE POINT. After the reclaim this is 0 by construction.
  -- Here it states the one durable absolute this fixture may still make:
  -- NOTHING OF OURS SURVIVED THE LAST RUN. Asserted at seq 5, banked below once
  -- the reclaim has cleared golden.scratch.
  SELECT (SELECT count(*) FROM public.feedback_proposals_v3      WHERE plan_date    = d_live)
       + (SELECT count(*) FROM public.picker_weight_proposals_v3 WHERE window_start = d_live)
    INTO v_sentinel;

  ------------------------------------------------------------------ reclaim --$n3$);

  ------------------------------------ R3: the foreign-row RAISE -> the sentinel --
  v_new := replace(v_new,
$o4$  ------------------------------------------------------- the live side is ours --
  -- Every assertion below claims an EXACT live count. A pre-epoch row this
  -- fixture did not create would redden it for an unrelated reason, so say so
  -- loudly instead of measuring a population we did not build.
  SELECT (SELECT count(*) FROM public.feedback_proposals_v3
            WHERE plan_date < v_epoch AND plan_date <> d_live)
       + (SELECT count(*) FROM public.picker_weight_proposals_v3
            WHERE window_start < v_epoch AND window_start <> d_live)
    INTO v_foreign;
  IF v_foreign > 0 THEN
    RAISE EXCEPTION 'FX59: % pre-epoch proposal row(s) this fixture did not create. Either real proposals have started arriving (then re-baseline seq 5-9 and 45-47 deliberately) or another fixture is planting below g12_fixture_epoch %.',
      v_foreign, v_epoch;
  END IF;$o4$,
$n4$  --------------------------------------------------- only the sentinel is ours --
  -- S-263: this fixture does NOT own the live population it measures. Real miner
  -- proposals arrived 2026-08-06 (DR-5) and DR-7's rotation heartbeat adds more
  -- every Sunday. Every live_* claim below is therefore a DELTA against `before`
  -- and every fixture_* claim is a STABILITY claim, so a foreign row can no
  -- longer redden this fixture for someone else's reason.
  --
  -- ⛔ DO NOT RESTORE THE OLD FOREIGN-ROW RAISE. Besides being permanently true
  -- now, by S-266 a scenario that RAISEs rolls back its own
  -- `DELETE FROM golden.scratch`, so every assertion re-evaluates the PREVIOUS
  -- run's snapshot and reports GREEN over nothing. A raising guard here does not
  -- fail loudly - it fails INVISIBLY, in the other direction.
  --
  -- What survives is the one absolute this fixture may still make: nothing of
  -- OURS outlived the last run. Measured above, BEFORE the reclaim; banked here,
  -- after the reclaim cleared golden.scratch. Asserted at seq 5.
  INSERT INTO golden.scratch(fixture_id, key, value)
  VALUES (59, 'before_sentinel', jsonb_build_object('sentinel_rows', v_sentinel));$n4$);

  ------------------------------------------------------------------- guards ----
  IF v_new = v_old THEN
    RAISE EXCEPTION 'S-263: scenario_sql unchanged - every substitution missed';
  END IF;
  IF position('v_foreign' in v_new) > 0 THEN
    RAISE EXCEPTION 'S-263 R1/R3 MISSED: v_foreign survives the rewrite';
  END IF;
  IF position('v_epoch' in v_new) > 0 THEN
    RAISE EXCEPTION 'S-263 R1/R2 MISSED: v_epoch survives the rewrite';
  END IF;
  IF position('FX59: % pre-epoch' in v_new) > 0 THEN
    RAISE EXCEPTION 'S-263 R3 MISSED: the foreign-row RAISE survives the rewrite';
  END IF;
  IF position('before_sentinel' in v_new) = 0 THEN
    RAISE EXCEPTION 'S-263 R3 MISSED: the sentinel capture did not land';
  END IF;
  IF position($chk$INSERT INTO golden.scratch(fixture_id, key, value) VALUES (59, 'before', v_before)$chk$ in v_new) = 0 THEN
    RAISE EXCEPTION 'S-263: the before snapshot was damaged by the rewrite';
  END IF;
  -- the reclaim and cleanup are deliberately UNTOUCHED: plan_date = 1999-01-01
  -- can never match a real row, so unlike fixture 57 (S-264) this fixture's
  -- DELETEs were never a live-data hazard. Prove they are still there.
  IF (length(v_new) - length(replace(v_new,
        'DELETE FROM public.feedback_proposals_v3      WHERE plan_date    = d_live;', '')))
     / length('DELETE FROM public.feedback_proposals_v3      WHERE plan_date    = d_live;') <> 2 THEN
    RAISE EXCEPTION 'S-263: expected exactly 2 sentinel-scoped feedback DELETEs (reclaim + cleanup)';
  END IF;
  IF (length(v_new) - length(replace(v_new,
        'DELETE FROM public.picker_weight_proposals_v3 WHERE window_start = d_live;', '')))
     / length('DELETE FROM public.picker_weight_proposals_v3 WHERE window_start = d_live;') <> 2 THEN
    RAISE EXCEPTION 'S-263: expected exactly 2 sentinel-scoped picker_weight DELETEs (reclaim + cleanup)';
  END IF;
  -- ⛔ AND NO DELETE MAY EVER BE SCOPED BY ANYTHING BUT THE 1999 SENTINEL. This is
  -- the S-264 lesson applied pre-emptively: fixture 57 ate real proposals because
  -- its reclaim keyed on a machine it shared with the production miner.
  IF (length(v_new) - length(replace(v_new, 'DELETE FROM public.', '')))
     / length('DELETE FROM public.') <> 4 THEN
    RAISE EXCEPTION 'S-263: fixture 59 must hold exactly 4 public-schema DELETEs, all sentinel-scoped';
  END IF;

  UPDATE golden.fixtures SET scenario_sql = v_new WHERE fixture_id = 59;
END
$mig$;


-- ==========================================================================
-- ASSERTIONS.  29 rewritten (5..24, 27..33, 45, 46).  Untouched: 1, 2, 3, 4,
-- 25, 26, 34..44, 47..53 - those already measure fixture-scoped or catalog
-- facts and carry no absolute live_* claim.
-- ==========================================================================

-- seq 5 - the ONLY absolute left, and the only one that is durably ours.
UPDATE golden.assertions SET
  check_sql = $c$SELECT (value ->> 'sentinel_rows') FROM golden.scratch WHERE fixture_id=59 AND key='before_sentinel'$c$,
  expect_op = 'eq', expect = '0',
  description = '⭐ S-263: THE ONE ABSOLUTE THIS FIXTURE MAY STILL MAKE - nothing of OURS survived the last run. Counted on the 1999 sentinel in both queues BEFORE the reclaim runs (after it, the count would be zero by construction and this would assert nothing). Goes red only if a previous run was killed mid-flight; the same run then repairs it. (Was: "feedback_pins has zero live proposals", which stopped being this fixture''s business on 2026-08-06 when DR-5''s miner minted 8 real ones.)'
WHERE fixture_id=59 AND seq=5;

-- seq 6 - STABILITY, end to end.
UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     f AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='final')
SELECT (((f.v->'feedback_pins'->>'fixture_rows')::int) = ((b.v->'feedback_pins'->>'fixture_rows')::int))::text FROM b, f$c$,
  expect_op = 'eq', expect = 'true',
  description = 'STABILITY (S-263): the feedback_pins FIXTURE-side population is identical at the start and at the end of the run. This fixture plants only below the epoch and cleans up after itself, so it may never move the synthetic band other fixtures own'
WHERE fixture_id=59 AND seq=6;

-- seq 7 - FORMULA-CONSISTENCY. The "zero evidence is not fail" claim it used to
-- carry is proven exhaustively and drift-proof at seq 35/36/40/41/42, and on this
-- fixture's own contribution at seq 31.
UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before')
SELECT ((b.v->'feedback_pins'->>'live_verdict') = public.g12_verdict_v3(
          (b.v->'feedback_pins'->>'live_accepted')::int,
          (b.v->'feedback_pins'->>'live_decided')::int,
          (b.v->'feedback_pins'->>'g12_min_decided')::int,
          (b.v->'feedback_pins'->>'g12_bar_pct')::numeric))::text FROM b$c$,
  expect_op = 'eq', expect = 'true',
  description = 'BEFORE, FORMULA-CONSISTENCY (S-263): the live_verdict the view publishes is exactly g12_verdict_v3 applied to the inputs the view publishes alongside it - the verdict is never hand-rolled inside the view. (Was: a literal "insufficient_evidence", which only held while the live queue was empty.)'
WHERE fixture_id=59 AND seq=7;

-- seq 8 - FORMULA.
UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before')
SELECT (CASE WHEN (b.v->'feedback_pins'->>'fixture_decided')::int = 0
             THEN (b.v->'feedback_pins'->>'fixture_acceptance_pct') IS NULL
             ELSE (b.v->'feedback_pins'->>'fixture_acceptance_pct')::numeric
                  = round(100.0 * (b.v->'feedback_pins'->>'fixture_accepted')::numeric
                                / (b.v->'feedback_pins'->>'fixture_decided')::numeric, 2)
        END)::text FROM b$c$,
  expect_op = 'eq', expect = 'true',
  description = 'BEFORE, FORMULA (S-263): whatever the synthetic band''s acceptance rate happens to be, it is quarantined in the FIXTURE column and equals round(100*fixture_accepted/fixture_decided,2) - the rate a naive acceptance view would have headlined as fleet truth. (Was the literal 75.00, which was only ever an accident of which other fixtures had run.)'
WHERE fixture_id=59 AND seq=8;

-- seq 9 - FORMULA (NULL is a computed outcome, not a fact about this queue).
UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before')
SELECT (((b.v->'picker_weights'->>'fixture_acceptance_pct') IS NULL)
        = ((b.v->'picker_weights'->>'fixture_decided')::int = 0))::text FROM b$c$,
  expect_op = 'eq', expect = 'true',
  description = 'BEFORE, FORMULA (S-263): picker_weights'' fixture rate is NULL if and only if nothing on the fixture side is decided - zero of zero is not zero percent, and the NULL is derived rather than assumed'
WHERE fixture_id=59 AND seq=9;

-- seq 10 - DELTA.
UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT (((a.v->'feedback_pins'->>'live_rows')::int - (b.v->'feedback_pins'->>'live_rows')::int))::text FROM a, b$c$,
  expect_op = 'eq', expect = '8',
  description = 'AFTER, DELTA (S-263): the 8 rows THIS FIXTURE planted below the epoch land in live_rows - measured as its own contribution, not as the whole live population'
WHERE fixture_id=59 AND seq=10;

-- seq 11 - STABILITY (the description already said UNMOVED; only the check was absolute).
UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT (((a.v->'feedback_pins'->>'fixture_rows')::int) = ((b.v->'feedback_pins'->>'fixture_rows')::int))::text FROM a, b$c$,
  expect_op = 'eq', expect = 'true',
  description = 'AFTER, STABILITY (S-263): and the fixture side is UNMOVED - planting live rows must not disturb the fixture population'
WHERE fixture_id=59 AND seq=11;

-- seq 12 - DELTA *and* the partition invariant the description actually claimed.
UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT ((((a.v->'feedback_pins'->>'total_rows')::int - (b.v->'feedback_pins'->>'total_rows')::int) = 8)
    AND ((a.v->'feedback_pins'->>'total_rows')::int
         = (a.v->'feedback_pins'->>'live_rows')::int + (a.v->'feedback_pins'->>'fixture_rows')::int))::text FROM a, b$c$,
  expect_op = 'eq', expect = 'true',
  description = 'AFTER, DELTA + PARTITION (S-263): total_rows grew by exactly our 8, AND total_rows is the SUM of both populations, never one of them. The sum claim is the one seq 12 always meant; the absolute 16 merely encoded it for one day''s world'
WHERE fixture_id=59 AND seq=12;

-- seq 13 - STABILITY, NULL-safe.
UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT ((a.v->'feedback_pins'->>'fixture_acceptance_pct')
        IS NOT DISTINCT FROM (b.v->'feedback_pins'->>'fixture_acceptance_pct'))::text FROM a, b$c$,
  expect_op = 'eq', expect = 'true',
  description = 'AFTER, STABILITY (S-263): the FIXTURE acceptance rate is UNMOVED while the live rate is something else entirely - the partition is real in both directions'
WHERE fixture_id=59 AND seq=13;

-- seq 14 - DELTA.
UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT (((a.v->'picker_weights'->>'live_rows')::int - (b.v->'picker_weights'->>'live_rows')::int))::text FROM a, b$c$,
  expect_op = 'eq', expect = '5',
  description = 'AFTER, DELTA (S-263): picker_weights picks up the 5 rows THIS FIXTURE planted. ⛔ Its live baseline is no longer zero - DR-5''s applied w_empty 0.900 -> 0.945 proposal is a real live row'
WHERE fixture_id=59 AND seq=14;

-- seq 15 - STABILITY. ⛔ fixture 58's S-262 treadmill grows this population between
-- runs; within one run it must not move.
UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT (((a.v->'picker_weights'->>'fixture_rows')::int) = ((b.v->'picker_weights'->>'fixture_rows')::int))::text FROM a, b$c$,
  expect_op = 'eq', expect = 'true',
  description = 'AFTER, STABILITY (S-263): and its fixture side is UNMOVED. ⛔ The absolute 2 could never hold - fixture 58''s S-262 treadmill adds a superseded pair every time it runs'
WHERE fixture_id=59 AND seq=15;

-- seq 16 - DELTA (zero, which is the point: families do not leak).
UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT (((a.v->'rotation'->>'live_rows')::int - (b.v->'rotation'->>'live_rows')::int))::text FROM a, b$c$,
  expect_op = 'eq', expect = '0',
  description = 'AFTER, DELTA (S-263): a family nobody planted into gains ZERO live rows from this fixture - families do not leak into each other. As a delta this survives DR-7''s heartbeat starting to mint real rotation proposals on 2026-08-09'
WHERE fixture_id=59 AND seq=16;

-- seq 17 - STABILITY.
UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT (((a.v->'rotation'->>'fixture_rows')::int) = ((b.v->'rotation'->>'fixture_rows')::int))::text FROM a, b$c$,
  expect_op = 'eq', expect = 'true',
  description = 'AFTER, STABILITY (S-263): and that family still reports its own fixture rows, unmoved. ⛔ The absolute 25 was a snapshot of one day - DR-7 first fires 2026-08-09'
WHERE fixture_id=59 AND seq=17;

-- seq 18..24 - DELTA. The status-vocabulary mapping claims are unchanged in
-- substance: each is now the number of rows OUR plant contributed to that bucket.
UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT (((a.v->'feedback_pins'->>'live_accepted')::int - (b.v->'feedback_pins'->>'live_accepted')::int))::text FROM a, b$c$,
  expect_op = 'eq', expect = '4',
  description = 'DELTA (S-263): approved maps to accepted - our 4 approved rows, and only ours'
WHERE fixture_id=59 AND seq=18;

UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT (((a.v->'feedback_pins'->>'live_rejected')::int - (b.v->'feedback_pins'->>'live_rejected')::int))::text FROM a, b$c$,
  expect_op = 'eq', expect = '1',
  description = 'DELTA (S-263): rejected maps to rejected - our 1 rejected row, and only ours'
WHERE fixture_id=59 AND seq=19;

UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT (((a.v->'feedback_pins'->>'live_undecided')::int - (b.v->'feedback_pins'->>'live_undecided')::int))::text FROM a, b$c$,
  expect_op = 'eq', expect = '2',
  description = 'DELTA (S-263): pending maps to undecided - our 2 pending rows. ⛔ The absolute 2 is already wrong today: the 8 real proposals CS is reviewing are all pending'
WHERE fixture_id=59 AND seq=20;

UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT (((a.v->'feedback_pins'->>'live_withdrawn')::int - (b.v->'feedback_pins'->>'live_withdrawn')::int))::text FROM a, b$c$,
  expect_op = 'eq', expect = '1',
  description = 'DELTA (S-263), S-139 member-of-the-difference: superseded maps to withdrawn, NOT to rejected'
WHERE fixture_id=59 AND seq=21;

UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT (((a.v->'feedback_pins'->>'live_decided')::int - (b.v->'feedback_pins'->>'live_decided')::int))::text FROM a, b$c$,
  expect_op = 'eq', expect = '5',
  description = 'DELTA (S-263): withdrawn is EXCLUDED from the denominator - we planted 8 rows and contributed exactly 5 decided'
WHERE fixture_id=59 AND seq=22;

UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT (((a.v->'picker_weights'->>'live_accepted')::int - (b.v->'picker_weights'->>'live_accepted')::int))::text FROM a, b$c$,
  expect_op = 'eq', expect = '1',
  description = 'DELTA (S-263), S-139 member-of-the-difference: applied maps to accepted, not to a fourth state. ⛔ As an absolute this is already wrong - DR-5''s real applied row makes live_accepted 2, not 1'
WHERE fixture_id=59 AND seq=23;

UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT (((a.v->'picker_weights'->>'live_rejected')::int - (b.v->'picker_weights'->>'live_rejected')::int))::text FROM a, b$c$,
  expect_op = 'eq', expect = '4',
  description = 'DELTA (S-263): picker_weights rejected count - our 4, and only ours'
WHERE fixture_id=59 AND seq=24;

-- seq 27 / 29 - FORMULA, and the rate OUR OWN DELTA implies. Both halves matter:
-- the first proves the view computes the rate it publishes, the second keeps the
-- original 80.00 / 20.00 claim alive against a moving live baseline.
UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT (((a.v->'feedback_pins'->>'live_acceptance_pct')::numeric
         = round(100.0 * (a.v->'feedback_pins'->>'live_accepted')::numeric
                       / NULLIF((a.v->'feedback_pins'->>'live_decided')::numeric, 0), 2))
    AND (round(100.0 * ((a.v->'feedback_pins'->>'live_accepted')::numeric - (b.v->'feedback_pins'->>'live_accepted')::numeric)
                     / NULLIF((a.v->'feedback_pins'->>'live_decided')::numeric - (b.v->'feedback_pins'->>'live_decided')::numeric, 0), 2)
         = 80.00))::text FROM a, b$c$,
  expect_op = 'eq', expect = 'true',
  description = 'AFTER, FORMULA + OWN-DELTA RATE (S-263): the published live rate IS round(100*accepted/decided,2), and the 4-accepted-of-5-decided WE contributed is 80.00% - the original claim, made about our own rows'
WHERE fixture_id=59 AND seq=27;

UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT (((a.v->'picker_weights'->>'live_acceptance_pct')::numeric
         = round(100.0 * (a.v->'picker_weights'->>'live_accepted')::numeric
                       / NULLIF((a.v->'picker_weights'->>'live_decided')::numeric, 0), 2))
    AND (round(100.0 * ((a.v->'picker_weights'->>'live_accepted')::numeric - (b.v->'picker_weights'->>'live_accepted')::numeric)
                     / NULLIF((a.v->'picker_weights'->>'live_decided')::numeric - (b.v->'picker_weights'->>'live_decided')::numeric, 0), 2)
         = 20.00))::text FROM a, b$c$,
  expect_op = 'eq', expect = 'true',
  description = 'AFTER, FORMULA + OWN-DELTA RATE (S-263): 1 accepted of 5 decided is 20.00% for OUR plant. ⛔ The published rate is no longer 20.00 and cannot be - DR-5''s applied proposal is a real accepted live row'
WHERE fixture_id=59 AND seq=29;

-- seq 28 / 30 / 31 - FORMULA-CONSISTENCY, and the verdict OUR OWN DELTA implies.
UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT (((a.v->'feedback_pins'->>'live_verdict') = public.g12_verdict_v3(
            (a.v->'feedback_pins'->>'live_accepted')::int,
            (a.v->'feedback_pins'->>'live_decided')::int,
            (a.v->'feedback_pins'->>'g12_min_decided')::int,
            (a.v->'feedback_pins'->>'g12_bar_pct')::numeric))
    AND (public.g12_verdict_v3(
            (a.v->'feedback_pins'->>'live_accepted')::int - (b.v->'feedback_pins'->>'live_accepted')::int,
            (a.v->'feedback_pins'->>'live_decided')::int  - (b.v->'feedback_pins'->>'live_decided')::int,
            (a.v->'feedback_pins'->>'g12_min_decided')::int,
            (a.v->'feedback_pins'->>'g12_bar_pct')::numeric) = 'pass'))::text FROM a, b$c$,
  expect_op = 'eq', expect = 'true',
  description = 'AFTER, CONSISTENCY + OWN-DELTA VERDICT (S-263): the view publishes exactly g12_verdict_v3 of its own inputs, AND our 80% over 5 decided clears the 60% bar - pass'
WHERE fixture_id=59 AND seq=28;

UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT (((a.v->'picker_weights'->>'live_verdict') = public.g12_verdict_v3(
            (a.v->'picker_weights'->>'live_accepted')::int,
            (a.v->'picker_weights'->>'live_decided')::int,
            (a.v->'picker_weights'->>'g12_min_decided')::int,
            (a.v->'picker_weights'->>'g12_bar_pct')::numeric))
    AND (public.g12_verdict_v3(
            (a.v->'picker_weights'->>'live_accepted')::int - (b.v->'picker_weights'->>'live_accepted')::int,
            (a.v->'picker_weights'->>'live_decided')::int  - (b.v->'picker_weights'->>'live_decided')::int,
            (a.v->'picker_weights'->>'g12_min_decided')::int,
            (a.v->'picker_weights'->>'g12_bar_pct')::numeric) = 'fail'))::text FROM a, b$c$,
  expect_op = 'eq', expect = 'true',
  description = 'AFTER, CONSISTENCY + OWN-DELTA VERDICT (S-263): 20% with enough evidence to judge is a real fail - the miner IS noise on this showing. Made about our own 5 decided rows so a real applied proposal cannot launder it into a pass'
WHERE fixture_id=59 AND seq=30;

UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT (((a.v->'rotation'->>'live_verdict') = public.g12_verdict_v3(
            (a.v->'rotation'->>'live_accepted')::int,
            (a.v->'rotation'->>'live_decided')::int,
            (a.v->'rotation'->>'g12_min_decided')::int,
            (a.v->'rotation'->>'g12_bar_pct')::numeric))
    AND (public.g12_verdict_v3(
            (a.v->'rotation'->>'live_accepted')::int - (b.v->'rotation'->>'live_accepted')::int,
            (a.v->'rotation'->>'live_decided')::int  - (b.v->'rotation'->>'live_decided')::int,
            (a.v->'rotation'->>'g12_min_decided')::int,
            (a.v->'rotation'->>'g12_bar_pct')::numeric) = 'insufficient_evidence'))::text FROM a, b$c$,
  expect_op = 'eq', expect = 'true',
  description = '⛔ THE DISTINCTION THAT PROTECTS A WORKING MINER (S-263 delta form): a family we contributed NO decided proposals to grades insufficient_evidence, never fail. Holds even after DR-7 starts minting real rotation rows on 2026-08-09'
WHERE fixture_id=59 AND seq=31;

-- seq 32 - FORMULA.
UPDATE golden.assertions SET
  check_sql = $c$WITH a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT (((a.v->'rotation'->>'live_acceptance_pct') IS NULL)
        = ((a.v->'rotation'->>'live_decided')::int = 0))::text FROM a$c$,
  expect_op = 'eq', expect = 'true',
  description = 'AFTER, FORMULA (S-263): the rate is NULL if and only if nothing is decided - zero of zero is not zero percent, derived rather than pinned'
WHERE fixture_id=59 AND seq=32;

-- seq 33 - DELTA against the dial.
UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     a AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='after')
SELECT ((((a.v->'feedback_pins'->>'live_decided')::int - (b.v->'feedback_pins'->>'live_decided')::int))
        = (a.v->'feedback_pins'->>'g12_min_decided')::int)::text FROM a, b$c$,
  expect_op = 'eq', expect = 'true',
  description = 'DELTA vs THE DIAL (S-263): our plant contributed EXACTLY g12_min_decided decided rows - the boundary is inclusive and was exercised, not stepped over'
WHERE fixture_id=59 AND seq=33;

-- seq 45 / 46 - RESTORED-BASELINE. Strictly stronger than "= 0": proves the
-- fixture put the world back, rather than that the world happens to be empty.
UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     f AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='final')
SELECT (((f.v->'feedback_pins'->>'live_rows')::int) = ((b.v->'feedback_pins'->>'live_rows')::int))::text FROM b, f$c$,
  expect_op = 'eq', expect = 'true',
  description = 'FINAL, RESTORED BASELINE (S-263): the live feedback_pins population is back exactly where it started - STRONGER than the old "= 0", which merely said the queue was empty and would have gone red the day CS had real proposals to review'
WHERE fixture_id=59 AND seq=45;

UPDATE golden.assertions SET
  check_sql = $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before'),
     f AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='final')
SELECT (((f.v->'picker_weights'->>'live_rows')::int) = ((b.v->'picker_weights'->>'live_rows')::int))::text FROM b, f$c$,
  expect_op = 'eq', expect = 'true',
  description = 'FINAL, RESTORED BASELINE (S-263): the live picker_weights population is back exactly where it started - DR-5''s applied proposal included, untouched'
WHERE fixture_id=59 AND seq=46;


-- ==========================================================================
-- POST-CONDITIONS
-- ==========================================================================
DO $post$
DECLARE
  n_seq int;
  v_unbaselined int[];
BEGIN
  -- Every rewritten seq landed.
  SELECT count(*) INTO n_seq FROM golden.assertions
   WHERE fixture_id = 59
     AND seq IN (5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,27,28,29,30,31,32,33,45,46)
     AND (check_sql LIKE '%before_sentinel%'
          OR check_sql LIKE '%key=''before''%'
          OR check_sql LIKE '%key=''after''%'
          OR check_sql LIKE '%key=''final''%');
  IF n_seq <> 29 THEN
    RAISE EXCEPTION 'S-263: expected 29 rewritten assertions, found %', n_seq;
  END IF;

  -- ⛔ THE STRUCTURAL RULE THIS FIXTURE NOW LIVES BY, ENFORCED AT APPLY TIME:
  -- any assertion that reads the `after` or `final` snapshot must ALSO read
  -- `before`, so that what it states is a DELTA or a STABILITY claim rather than
  -- an absolute over a population this fixture shares with production.
  -- TWO DOCUMENTED EXCEPTIONS, neither of which is a population-size absolute:
  --   · seq 32 is a within-snapshot FORMULA (rate IS NULL <-> decided = 0);
  --   · the `reallocation` seqs (25/26/51/52/53) were already hardened by S-204 -
  --     25/26 RE-DERIVE against the live table with epoch scoping, 51/52 are
  --     `> 0` non-vacuity guards, 53 is an inequality between two of its own
  --     buckets. None states a fixed count.
  -- If a future leg adds another single-snapshot absolute, this goes red HERE,
  -- at apply time, instead of silently months later when the world moves.
  SELECT array_agg(seq ORDER BY seq) INTO v_unbaselined
    FROM golden.assertions
   WHERE fixture_id = 59
     AND (check_sql LIKE '%key=''after''%' OR check_sql LIKE '%key=''final''%')
     AND check_sql NOT LIKE '%key=''before''%'
     AND check_sql NOT LIKE '%''reallocation''%'
     AND seq <> 32;
  IF v_unbaselined IS NOT NULL THEN
    RAISE EXCEPTION 'S-263: seq % read the after/final snapshot with no before-baseline to subtract', v_unbaselined;
  END IF;

  -- The fixture still has its 53 assertions - nothing was dropped or added.
  IF (SELECT count(*) FROM golden.assertions WHERE fixture_id = 59) <> 53 THEN
    RAISE EXCEPTION 'S-263: fixture 59 assertion count moved off 53';
  END IF;
END
$post$;
