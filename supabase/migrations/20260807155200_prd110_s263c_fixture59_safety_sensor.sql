-- PRD-110 · S-263c · fixture 59 gets the S-264 safety sensor it never had,
--                     and the stability family gets its non-vacuity partner
--
-- ⛔ PROVENANCE, RECORDED BECAUSE IT IS A RELAY-HYGIENE FINDING (S-270). An
-- UNLOGGED, UNAPPLIED draft of the S-263 rewrite was sitting untracked at
-- `docs/prds/s263_fixture59_delta.sql` (mtime 2026-08-07 03:16Z, self-labelled
-- "leg 143"). It was never applied - verified at STEP R, where `prd110%` read 323
-- and fixture 59's scenario still carried `v_foreign` - and it left no execution-log
-- entry, no resume pointer and no parking-lot delta, so by the RELAY protocol it
-- was not a leg. ⭐ **It was also RIGHT about two things `20260807145900` shipped
-- without.** They are harvested here rather than lost:
--
--   1. THE SAFETY SENSOR. Fixture 57 got one at leg 142 (its seq 40/41) after
--      S-264 caught it eating real proposals. Fixture 59 touches the SAME two
--      queues and never got one. Leg 143 proved 8 -> 8 and 11 -> 11 BY HAND,
--      outside the harness - which proves nothing about the NEXT run. Now the
--      fixture asserts it itself, every run.
--   2. NON-VACUITY FOR THE STABILITY FAMILY. seq 11/15/17 are `after = before`.
--      ⛔ `0 = 0` satisfies all three. That is the S-48/S-52/S-55 mode exactly,
--      and nothing in the shipped fixture ruled it out.
--
-- ⭐ WHAT THE DRAFT GOT WRONG, AND WHAT SHIPPED IS RIGHT: it kept leg 142's
-- instruction to capture `before_sentinel` AFTER the reclaim, where the count is
-- 0 by construction and seq 5 asserts nothing. `20260807145900` moved it before.
-- Neither artefact was complete; this migration is the union.
--
-- ⛔ THE SENSOR MUST RUN BEFORE THE FIRST DELETE. A sensor that fires after the
-- reclaim proves the reclaim WORKED, not that it was SAFE TO RUN.
--
-- WHAT IT COUNTS: rows in BOTH queues that are pre-epoch (`< g12_fixture_epoch`)
-- AND not on the 1999 sentinel - precisely the population this fixture may never
-- touch. That is the real, CS-facing review queue.


DO $mig$
DECLARE
  v_old text; v_new text;
BEGIN
  SELECT scenario_sql INTO v_new FROM golden.fixtures WHERE fixture_id = 59;
  IF v_new IS NULL THEN RAISE EXCEPTION 'S-263c: fixture 59 has no scenario_sql'; END IF;
  IF position('real_before' in v_new) > 0 THEN
    RAISE EXCEPTION 'S-263c: the safety sensor is already present - refusing to double-apply';
  END IF;
  v_old := v_new;

  ----------------------------------------------------------- R1: declarations --
  v_new := replace(v_new,
$o1$  v_before jsonb; v_after jsonb; v_final jsonb;
  v_sentinel int;$o1$,
$n1$  v_before jsonb; v_after jsonb; v_final jsonb;
  v_sentinel int;
  v_real_before jsonb; v_real_final jsonb;$n1$);

  ------------------------------------------- R2: the sensor, before ANY DELETE --
  v_new := replace(v_new,
$o2$  ------------------------------------------- S-263: measured BEFORE the reclaim --$o2$,
$n2$  ------------------------------- S-263c: THE SAFETY SENSOR RUNS FIRST OF ALL ----
  -- ⛔ BEFORE THE FIRST DELETE. A sensor that fires after the reclaim proves the
  -- reclaim WORKED, not that it was SAFE TO RUN. This counts the rows this fixture
  -- may never touch: pre-epoch, non-sentinel, in BOTH queues - the real CS-facing
  -- review queue. seq 54 asserts it UNMOVED at the end; seq 55 is its non-vacuity
  -- partner. ⭐ Fixture 57 got this at leg 142 (S-264); fixture 59 touches the same
  -- two tables and went without it until now.
  SELECT jsonb_build_object(
           'feedback', (SELECT count(*) FROM public.feedback_proposals_v3 f
                         WHERE f.plan_date < (SELECT g12_fixture_epoch FROM public.refill_policy_params ORDER BY id LIMIT 1)
                           AND f.plan_date <> d_live),
           'picker',   (SELECT count(*) FROM public.picker_weight_proposals_v3 w
                         WHERE w.window_start < (SELECT g12_fixture_epoch FROM public.refill_policy_params ORDER BY id LIMIT 1)
                           AND w.window_start <> d_live))
    INTO v_real_before;

  ------------------------------------------- S-263: measured BEFORE the reclaim --$n2$);

  --------------------------------------------- R3: the closing half of the sensor --
  v_new := replace(v_new,
$o3$  v_final := (SELECT jsonb_object_agg(family, to_jsonb(v))
                FROM public.v_proposal_acceptance_v3 v);
  INSERT INTO golden.scratch(fixture_id, key, value) VALUES (59, 'final', v_final);$o3$,
$n3$  v_final := (SELECT jsonb_object_agg(family, to_jsonb(v))
                FROM public.v_proposal_acceptance_v3 v);
  INSERT INTO golden.scratch(fixture_id, key, value) VALUES (59, 'final', v_final);

  -- S-263c: the closing half of the safety sensor. Same predicate, same order of
  -- keys, so seq 54 can compare the two jsonb objects whole.
  SELECT jsonb_build_object(
           'feedback', (SELECT count(*) FROM public.feedback_proposals_v3 f
                         WHERE f.plan_date < (SELECT g12_fixture_epoch FROM public.refill_policy_params ORDER BY id LIMIT 1)
                           AND f.plan_date <> d_live),
           'picker',   (SELECT count(*) FROM public.picker_weight_proposals_v3 w
                         WHERE w.window_start < (SELECT g12_fixture_epoch FROM public.refill_policy_params ORDER BY id LIMIT 1)
                           AND w.window_start <> d_live))
    INTO v_real_final;
  INSERT INTO golden.scratch(fixture_id, key, value) VALUES (59, 'real_before', v_real_before);
  INSERT INTO golden.scratch(fixture_id, key, value) VALUES (59, 'real_final',  v_real_final);$n3$);

  ------------------------------------------------------------------- guards ----
  IF v_new = v_old THEN
    RAISE EXCEPTION 'S-263c: scenario_sql unchanged - every substitution missed';
  END IF;
  IF position('INTO v_real_before' in v_new) = 0 OR position('INTO v_real_final' in v_new) = 0 THEN
    RAISE EXCEPTION 'S-263c: one half of the sensor did not land';
  END IF;
  -- ⛔ ORDER IS THE CLAIM: the sensor's opening capture must precede every DELETE.
  IF position('INTO v_real_before' in v_new) > position('DELETE FROM public.' in v_new) THEN
    RAISE EXCEPTION 'S-263c: the sensor was placed AFTER a DELETE - it would prove the reclaim worked, not that it was safe';
  END IF;
  -- and the reclaim/cleanup must still be exactly what S-263 left behind
  IF (length(v_new) - length(replace(v_new, 'DELETE FROM public.', '')))
     / length('DELETE FROM public.') <> 4 THEN
    RAISE EXCEPTION 'S-263c: fixture 59 must still hold exactly 4 public-schema DELETEs';
  END IF;

  UPDATE golden.fixtures SET scenario_sql = v_new WHERE fixture_id = 59;
END
$mig$;


INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(59, 54,
 '⛔⛔ S-263c SAFETY SENSOR: running this fixture destroyed NOT ONE real proposal. The pre-epoch, non-sentinel population of BOTH queues - the review queue CS actually looks at - is captured before the first DELETE and compared after everything this fixture does. ⭐ Leg 143 proved 8 -> 8 and 11 -> 11 BY HAND, which proves nothing about the NEXT run; this proves it every run. Fixture 57 got this at leg 142 after S-264 caught it eating real rows; fixture 59 touches the same two tables',
 $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='real_before'),
     f AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='real_final')
SELECT (b.v = f.v)::text FROM b, f$c$,
 'eq', 'true', true, 'P4'),

(59, 55,
 '⛔ NON-VACUITY for seq 54: there IS a real pre-epoch population to protect, so the sensor is not comparing zero to zero. ⭐ It is non-empty today because DR-5 made the miners live on 2026-08-06 - which is the same event that broke this fixture in the first place',
 $c$SELECT (((value ->> 'feedback')::int) + ((value ->> 'picker')::int))::text
   FROM golden.scratch WHERE fixture_id=59 AND key='real_before'$c$,
 'gt', '0', true, 'P4'),

(59, 56,
 '⛔ NON-VACUITY for the whole STABILITY family (seq 11/15/17). Each of those is `after = before`, which `0 = 0` satisfies - the S-48/S-52/S-55 mode. This asserts every one of the three families it guards carries a real fixture-side population, so none of them can pass on an empty measurement',
 $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=59 AND key='before')
SELECT LEAST((b.v->'feedback_pins' ->>'fixture_rows')::int,
             (b.v->'picker_weights'->>'fixture_rows')::int,
             (b.v->'rotation'      ->>'fixture_rows')::int)::text FROM b$c$,
 'gt', '0', true, 'P4');


DO $post$
BEGIN
  IF (SELECT count(*) FROM golden.assertions WHERE fixture_id = 59) <> 56 THEN
    RAISE EXCEPTION 'S-263c: fixture 59 should now hold 56 assertions';
  END IF;
  -- The S-263 structural rule still holds: nothing reads after/final without before.
  -- (`key=''real_final''` deliberately does not match the `key=''final''` pattern.)
  IF EXISTS (SELECT 1 FROM golden.assertions
              WHERE fixture_id = 59
                AND (check_sql LIKE '%key=''after''%' OR check_sql LIKE '%key=''final''%')
                AND check_sql NOT LIKE '%key=''before''%'
                AND check_sql NOT LIKE '%''reallocation''%'
                AND seq <> 32) THEN
    RAISE EXCEPTION 'S-263c: an assertion now reads after/final with no before-baseline';
  END IF;
END
$post$;
