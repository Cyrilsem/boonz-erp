-- PRD-110 leg 88 — golden fixture 59: the G12 acceptance-rate telemetry object.
-- LAW 1: no engine change before the fixture that proves it.
--
-- WHY THE 1999 SENTINEL (the design decision of this fixture):
--   v_proposal_acceptance_v3 splits every queue into a LIVE population and a
--   FIXTURE population at g12_fixture_epoch (2030-01-01). Every proposal row in
--   the database today is 2030 fixture residue, so a fixture that planted only
--   2030 rows would leave live_* pinned at 0 and assert nothing about the half of
--   the object that actually matters. That is S-132's vacuity in a new organ.
--   So this fixture plants at 1999-01-01: unmistakably synthetic to any human,
--   yet BELOW the epoch, so it drives the live path for real.
--   The plants live inside a plpgsql BEGIN/EXCEPTION subtransaction and are
--   deleted on the success path, so no live-looking row survives the run either
--   way; seq 45-47 prove the cleanup rather than trusting it.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes, enabled, baseline_status)
VALUES (
  59,
  'G12 acceptance-rate telemetry: per-family, live vs fixture, and zero evidence is not a failing grade',
  'PRD-110 P4.3 G12 + leg 88. All 82 proposal rows fleet-wide are synthetic; a naive acceptance view headlines "feedback pins 75%" over four fixture rows.',
  'P4',
  -- ⚠️ DECLARED plan_date is 2030 because golden.fixtures_plan_date_check requires
  --    every fixture to declare a date inside 2030. This fixture does not use the
  --    {{plan_date}} token at all: its scenario deliberately works at the 1999
  --    PRE-EPOCH sentinel, because that is the only way to exercise live_*.
  --    The constraint governs the DECLARED date, not what the scenario plants.
  DATE '2030-06-01',
$fx59body$
DO $fx59$
DECLARE
  d_live  date := DATE '1999-01-01';
  v_epoch date;
  v_m     uuid;
  v_bp    uuid;
  v_rev   uuid := '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d';
  v_foreign int;
  v_before jsonb; v_after jsonb; v_final jsonb;
BEGIN
  -- Article 8 (leg 87's lesson): name the harness write, do not claim it was an RPC.
  PERFORM set_config('app.rpc_name', 'golden.fixture_59', true);

  SELECT g12_fixture_epoch INTO v_epoch
    FROM public.refill_policy_params ORDER BY id LIMIT 1;

  ------------------------------------------------------------------ reclaim --
  -- S-134: reclaim by THIS fixture's own marker (the 1999 sentinel), never a
  -- shared anchor. Survives a hard session kill in the previous run.
  DELETE FROM public.feedback_proposals_v3      WHERE plan_date    = d_live;
  DELETE FROM public.picker_weight_proposals_v3 WHERE window_start = d_live;
  DELETE FROM golden.scratch WHERE fixture_id = 59;

  ------------------------------------------------------- the live side is ours --
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
  END IF;

  SELECT machine_id INTO v_m  FROM public.machines       ORDER BY machine_id LIMIT 1;
  SELECT product_id INTO v_bp FROM public.boonz_products ORDER BY product_id LIMIT 1;
  IF v_m IS NULL OR v_bp IS NULL THEN
    RAISE EXCEPTION 'FX59 setup: no machine/product to hang proposals on - the fixture would assert over nothing';
  END IF;

  v_before := (SELECT jsonb_object_agg(family, to_jsonb(v))
                 FROM public.v_proposal_acceptance_v3 v);
  INSERT INTO golden.scratch(fixture_id, key, value) VALUES (59, 'before', v_before);

  BEGIN
    ------------------------------------------------------------------ plant --
    -- feedback_pins: 4 approved + 1 rejected + 2 pending + 1 superseded.
    -- decided = 5, which is EXACTLY g12_min_decided, at 80% -> pass.
    -- The superseded row is the S-139 member-of-the-difference: it proves
    -- 'withdrawn' is excluded from the denominator rather than counted a reject.
    INSERT INTO public.feedback_proposals_v3
      (plan_date, machine_id, boonz_product_id, pin_kind, pin_value, pin_mode,
       feedback_ids, trigger_reason, status, reviewed_by, reviewed_at)
    SELECT d_live, v_m, v_bp, 'min_facing', 2, 'perpetual',
           ARRAY[gen_random_uuid()], 'FX59 ' || t.st, t.st,
           CASE WHEN t.st IN ('approved','rejected') THEN v_rev END,
           CASE WHEN t.st IN ('approved','rejected') THEN now() END
      FROM (VALUES ('approved'),('approved'),('approved'),('approved'),
                   ('rejected'),('pending'),('pending'),('superseded')) AS t(st);

    -- picker_weights: 1 applied + 4 rejected -> decided = 5 at 20% -> fail.
    -- The applied row proves 'applied' maps to accepted, not to a fourth state.
    -- ⛔ NOT ONE PENDING ROW: fixture 58 hard-RAISEs on any pending
    --    picker_weight_proposals_v3 row outside its own window.
    INSERT INTO public.picker_weight_proposals_v3
      (window_start, window_end, target_param, current_weight, proposed_weight,
       direction, lead_feature, concordance_pct, pairs, concordant, discordant,
       days_covered, status, reviewed_by, reviewed_at, applied_at, applied_weight)
    SELECT d_live, d_live + 9, t.param, 0.900, 0.945, 'raise',
           'empty_shelves_count', 68.57, 100, 60, 40, 24, t.st,
           CASE WHEN t.st = 'rejected' THEN v_rev END,
           CASE WHEN t.st = 'rejected' THEN now() END,
           CASE WHEN t.st = 'applied'  THEN now() END,
           CASE WHEN t.st = 'applied'  THEN 0.945 END
      FROM (VALUES ('w_empty','applied'), ('w_expiry','rejected'),
                   ('w_stale','rejected'), ('w_holes','rejected'),
                   ('w_runout','rejected')) AS t(param, st);

    v_after := (SELECT jsonb_object_agg(family, to_jsonb(v))
                  FROM public.v_proposal_acceptance_v3 v);
    INSERT INTO golden.scratch(fixture_id, key, value) VALUES (59, 'after', v_after);
  EXCEPTION WHEN OTHERS THEN
    -- The subtransaction rolls the plants back on its own; re-raise so the
    -- harness records a THROWN scenario (S-135) instead of green-over-nothing.
    RAISE;
  END;

  ---------------------------------------------------------------- cleanup ----
  -- No live-looking proposal may outlive this fixture. Proven by seq 45-47.
  DELETE FROM public.feedback_proposals_v3      WHERE plan_date    = d_live;
  DELETE FROM public.picker_weight_proposals_v3 WHERE window_start = d_live;

  v_final := (SELECT jsonb_object_agg(family, to_jsonb(v))
                FROM public.v_proposal_acceptance_v3 v);
  INSERT INTO golden.scratch(fixture_id, key, value) VALUES (59, 'final', v_final);
END
$fx59$;
$fx59body$,
  'Leg 88. Proves the G12 object per family, proves the live/fixture partition in BOTH directions, and proves insufficient_evidence is distinct from fail. Plants at the 1999 pre-epoch sentinel so live_* is exercised rather than asserted-at-zero. Cleans up in-run; seq 45-47 are the residue check.',
  true,
  'passing'
);

------------------------------------------------------------------ assertions --
-- ⭐ phase_required is set EXPLICITLY on every row - it defaults to 'P0'.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
SELECT 59, t.seq, t.descr, t.sql, t.op, t.expect, true, 'P4'
FROM (VALUES

-- A. structure: the object always speaks about all five families
(1,'the view returns exactly five families, always - an empty queue must render as zero-proposals-ever, not vanish',
 $q$SELECT count(*)::text FROM public.v_proposal_acceptance_v3$q$,'eq','5'),
(2,'exactly the two miner-fed queues carry in_g12_scope; the three P3 proposer queues are reported, not graded',
 $q$SELECT string_agg(family, ',' ORDER BY family) FROM public.v_proposal_acceptance_v3 WHERE in_g12_scope$q$,'eq','feedback_pins,picker_weights'),
(3,'every family accounts for every one of its rows (the object detects its own miscount)',
 $q$SELECT bool_and(bucket_sum_ok)::text FROM public.v_proposal_acceptance_v3$q$,'eq','true'),
(4,'no status anywhere falls through to the unmapped bucket - the five vocabularies are fully covered',
 $q$SELECT (sum(live_unmapped) + sum(fixture_unmapped))::text FROM public.v_proposal_acceptance_v3$q$,'eq','0'),

-- B. baseline: today the live side is empty and ALL evidence is fixture residue
(5,'BEFORE: feedback_pins has zero live proposals',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='before') -> 'feedback_pins' ->> 'live_rows'$q$,'eq','0'),
(6,'BEFORE: feedback_pins holds 8 fixture rows',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='before') -> 'feedback_pins' ->> 'fixture_rows'$q$,'eq','8'),
(7,'BEFORE: with no live evidence the verdict is insufficient_evidence - NOT fail',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='before') -> 'feedback_pins' ->> 'live_verdict'$q$,'eq','insufficient_evidence'),
(8,'BEFORE: the 75% that a naive acceptance view would have headlined is quarantined in the fixture column, where it belongs',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='before') -> 'feedback_pins' ->> 'fixture_acceptance_pct'$q$,'eq','75.00'),
(9,'BEFORE: picker_weights fixture rows are undecided, so they yield no acceptance rate at all',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='before') -> 'picker_weights' ->> 'fixture_acceptance_pct'$q$,'is_null',NULL),

-- C. THE PARTITION - the core claim, asserted in both directions
(10,'AFTER: the 8 planted pre-epoch rows land in live_rows',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'feedback_pins' ->> 'live_rows'$q$,'eq','8'),
(11,'AFTER: and the fixture side is UNMOVED at 8 - planting live rows must not disturb the fixture population',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'feedback_pins' ->> 'fixture_rows'$q$,'eq','8'),
(12,'AFTER: total_rows is the sum of both populations, never one of them',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'feedback_pins' ->> 'total_rows'$q$,'eq','16'),
(13,'AFTER: the fixture acceptance rate is UNMOVED at 75.00 while the live rate is something else entirely',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'feedback_pins' ->> 'fixture_acceptance_pct'$q$,'eq','75.00'),
(14,'AFTER: picker_weights picks up its 5 planted live rows',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'picker_weights' ->> 'live_rows'$q$,'eq','5'),
(15,'AFTER: and its fixture side is UNMOVED at 2',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'picker_weights' ->> 'fixture_rows'$q$,'eq','2'),
(16,'AFTER: a family nobody planted into stays at zero live rows - families do not leak into each other',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'rotation' ->> 'live_rows'$q$,'eq','0'),
(17,'AFTER: and that family still reports its own 25 fixture rows',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'rotation' ->> 'fixture_rows'$q$,'eq','25'),

-- D. bucket mapping - every member of every confusable difference
(18,'approved maps to accepted',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'feedback_pins' ->> 'live_accepted'$q$,'eq','4'),
(19,'rejected maps to rejected',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'feedback_pins' ->> 'live_rejected'$q$,'eq','1'),
(20,'pending maps to undecided',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'feedback_pins' ->> 'live_undecided'$q$,'eq','2'),
(21,'S-139 member-of-the-difference: superseded maps to withdrawn, NOT to rejected',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'feedback_pins' ->> 'live_withdrawn'$q$,'eq','1'),
(22,'and withdrawn is therefore EXCLUDED from the denominator: 8 rows, 5 decided',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'feedback_pins' ->> 'live_decided'$q$,'eq','5'),
(23,'S-139 member-of-the-difference: applied maps to accepted, not to a fourth state',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'picker_weights' ->> 'live_accepted'$q$,'eq','1'),
(24,'picker_weights rejected count',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'picker_weights' ->> 'live_rejected'$q$,'eq','4'),
(25,'S-139 member-of-the-difference: unclaimed maps to unmatched - an offer that found no target was never put to CS',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'reallocation' ->> 'fixture_unmatched'$q$,'eq','18'),
(26,'and those 18 unmatched rows are NOT counted as undecided, which holds only the 6 proposed ones',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'reallocation' ->> 'fixture_undecided'$q$,'eq','6'),

-- E. the three verdicts, all reached for real through the view
(27,'AFTER: 4 accepted of 5 decided is 80.00%',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'feedback_pins' ->> 'live_acceptance_pct'$q$,'eq','80.00'),
(28,'AFTER: 80% clears the 60% bar - pass',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'feedback_pins' ->> 'live_verdict'$q$,'eq','pass'),
(29,'AFTER: 1 accepted of 5 decided is 20.00%',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'picker_weights' ->> 'live_acceptance_pct'$q$,'eq','20.00'),
(30,'AFTER: 20% with enough evidence to judge is a real fail - the miner IS noise on this showing',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'picker_weights' ->> 'live_verdict'$q$,'eq','fail'),
(31,'⛔ THE DISTINCTION THAT PROTECTS A WORKING MINER: no decided proposals is insufficient_evidence, never fail',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'rotation' ->> 'live_verdict'$q$,'eq','insufficient_evidence'),
(32,'and its rate is NULL rather than 0.00 - zero of zero is not zero percent',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'rotation' ->> 'live_acceptance_pct'$q$,'is_null',NULL),

-- F. the gate the object actually applied, published not hidden
(33,'the passing family sat EXACTLY on g12_min_decided - the boundary is inclusive and was exercised, not stepped over',
 $q$SELECT (((SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'feedback_pins' ->> 'live_decided')
   = ((SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after') -> 'feedback_pins' ->> 'g12_min_decided'))::text$q$,'eq','true'),
(34,'the view publishes the bar it applied',
 $q$SELECT g12_bar_pct::text FROM public.v_proposal_acceptance_v3 LIMIT 1$q$,'eq','60.00'),

-- G. helper branches, data-free, so the verdict logic is falsifiable on its own
(35,'helper: zero decided is insufficient_evidence',
 $q$SELECT public.g12_verdict_v3(0,0,5,60.00)$q$,'eq','insufficient_evidence'),
(36,'helper: below min_decided is insufficient_evidence even at 100%',
 $q$SELECT public.g12_verdict_v3(4,4,5,60.00)$q$,'eq','insufficient_evidence'),
(37,'helper: exactly at min_decided and exactly at the bar is a pass (S-137 - own the boundary)',
 $q$SELECT public.g12_verdict_v3(3,5,5,60.00)$q$,'eq','pass'),
(38,'helper: 59.9% fails',
 $q$SELECT public.g12_verdict_v3(599,1000,5,60.00)$q$,'eq','fail'),
(39,'helper: 60.1% passes',
 $q$SELECT public.g12_verdict_v3(601,1000,5,60.00)$q$,'eq','pass'),
(40,'helper: all-rejected with enough evidence is a real fail, distinct from no evidence',
 $q$SELECT public.g12_verdict_v3(0,9,5,60.00)$q$,'eq','fail'),
(41,'⛔ CODY leg 88: a NULL bar must NOT read as fail. (100.0*a/d) >= NULL is NULL, so a bare ELSE would have rendered a missing threshold as "the miner is noise". S-126.',
 $q$SELECT public.g12_verdict_v3(9,9,5,NULL)$q$,'eq','insufficient_evidence'),
(42,'helper: a NULL min_decided is likewise insufficient_evidence, not a silent pass',
 $q$SELECT public.g12_verdict_v3(9,9,NULL,60.00)$q$,'eq','insufficient_evidence'),
(43,'helper: accepted > decided is reported as incoherent',
 $q$SELECT public.g12_verdict_v3(10,9,5,60.00)$q$,'eq','incoherent'),
(44,'S-137: and an incoherent input is REPORTED, never raised - a correct invariant that throws inside a view is a crash path for every consumer',
 $q$SELECT public.g12_verdict_v3(-1,9,5,60.00)$q$,'eq','incoherent'),

-- H. no live-looking residue outlives this fixture
(45,'FINAL: the planted feedback rows are gone',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='final') -> 'feedback_pins' ->> 'live_rows'$q$,'eq','0'),
(46,'FINAL: the planted picker_weight rows are gone',
 $q$SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='final') -> 'picker_weights' ->> 'live_rows'$q$,'eq','0'),
(47,'FINAL: and nothing sits on the 1999 sentinel date in either queue',
 $q$SELECT ((SELECT count(*) FROM public.feedback_proposals_v3 WHERE plan_date = DATE '1999-01-01')
        + (SELECT count(*) FROM public.picker_weight_proposals_v3 WHERE window_start = DATE '1999-01-01'))::text$q$,'eq','0'),
(48,'⛔ fixture 58 stays runnable: this fixture leaves NO pending picker_weight_proposals_v3 row behind',
 $q$SELECT count(*)::text FROM public.picker_weight_proposals_v3 WHERE status='pending' AND window_start = DATE '1999-01-01'$q$,'eq','0'),

-- I. object shape
(49,'S-140: the view grants authenticated SELECT only - the Supabase default-privileges trap applies to views and to authenticated, not just functions and anon',
 $q$SELECT array_to_string(relacl,',') FROM pg_class WHERE relname='v_proposal_acceptance_v3'$q$,'eq','postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres,authenticated=r/postgres'),
(50,'the verdict helper has exactly one overload',
 $q$SELECT count(*)::text FROM pg_proc WHERE proname='g12_verdict_v3'$q$,'eq','1')

) AS t(seq, descr, sql, op, expect);
