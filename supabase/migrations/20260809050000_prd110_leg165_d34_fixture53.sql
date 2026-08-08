-- PRD-110 leg 165 · D-34 · FIXTURE FIRST (LAW 1)
--
-- D-34 points the nightly shadow runner at run_pipeline_v3. S-331 proved this is NOT a
-- call swap: the pipeline swallows the engine's exception, its own classifier knows TWO
-- of the four refusals, and the S-304a line sensor goes blind on the nested receipt.
-- S-332 adds a fourth: v_shadow_runner_health_v3 blacklists exactly one bad word
-- ('error'), so every NEW status this unit introduces would read healthy with verdict 'ok'.
--
-- These probes go RED first. They are the proof the fix is real:
--   * the PIPELINE's own engine classifier must tell the four refusals apart (S-331 #2)
--   * the runner must actually go THROUGH the pipeline (non-vacuity of the swap)
--   * the status CHECK must admit the pipeline's own failure modes
--   * health must REFUSE to bless a status it does not know (S-332)
--
-- ⛔ The S-304a positive case (a night that banks rows still reads 'ok', not
--    'ok_no_shadow_rows') cannot be proven here: both of fixture 53's nights are
--    deliberate refusals. That guard is fixture 37 seq 36..40, which must stay green
--    across this unit. Fixture 37 is part of D-34's acceptance, not decoration.

UPDATE golden.fixtures
SET scenario_sql = scenario_sql || $append$

-- ---------------------------------------------------------------------------
-- (5) S-331 #2. THE PIPELINE'S OWN ENGINE CLASSIFIER.
--     run_pipeline_v3 catches the engine's exception and never re-raises, so once
--     the runner reads a RECEIPT instead of catching a throw, the pipeline's CASE
--     becomes the only thing standing between a deliberate calendar no-op and the
--     word 'error'. It must know all four refusals, not two.
--
--     ⭐ Called with p_promote_blocked => false: this block is measuring the
--        classifier, and a refusal night never reaches the promotion step anyway.
-- ---------------------------------------------------------------------------
DO $append_do$
DECLARE v_sat jsonb; v_fri jsonb;
BEGIN
  IF to_regprocedure('public.run_pipeline_v3(date,integer,uuid,boolean,text)') IS NULL THEN
    INSERT INTO golden.scratch (fixture_id, key, value)
    VALUES (53, 'pipe', jsonb_build_object('sat_engine','no_pipeline','fri_engine','no_pipeline'));
    RETURN;
  END IF;

  BEGIN
    v_sat := public.run_pipeline_v3({{plan_date}}, 7, NULL, false, 'golden_fixture_53_pipe_sat');
  EXCEPTION WHEN OTHERS THEN
    v_sat := jsonb_build_object('status','THREW','engine',jsonb_build_object('status','THREW'));
  END;

  BEGIN
    v_fri := public.run_pipeline_v3({{plan_date}} - 1, 7, NULL, false, 'golden_fixture_53_pipe_fri');
  EXCEPTION WHEN OTHERS THEN
    v_fri := jsonb_build_object('status','THREW','engine',jsonb_build_object('status','THREW'));
  END;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (53, 'pipe', jsonb_build_object(
    -- the refusal lives in the NESTED engine receipt ...
    'sat_engine', COALESCE(v_sat->'engine'->>'status','absent'),
    'fri_engine', COALESCE(v_fri->'engine'->>'status','absent'),
    -- ... while the TOP level says only that no base was produced. Both facts are
    -- pinned so a future leg cannot confuse the two layers (S-331 #1).
    'sat_top',    COALESCE(v_sat->>'status','absent'),
    'fri_top',    COALESCE(v_fri->>'status','absent')));
END $append_do$;

-- ---------------------------------------------------------------------------
-- (6) NON-VACUITY OF THE SWAP ITSELF. If D-34 lands, the runner's nights leave a
--     pipeline receipt carrying the runner's own note. Without this a runner that
--     still called engine_add_pod_v3 directly would keep every S-112 assertion
--     green and D-34 would read as done while nothing moved.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
VALUES (53, 'swap', jsonb_build_object(
  'sat_pipeline_receipts', CASE WHEN to_regclass('public.pipeline_runs_v3') IS NULL THEN -1
    ELSE (SELECT count(*) FROM public.pipeline_runs_v3
           WHERE note = 'golden_fixture_53_saturday') END,
  'fri_pipeline_receipts', CASE WHEN to_regclass('public.pipeline_runs_v3') IS NULL THEN -1
    ELSE (SELECT count(*) FROM public.pipeline_runs_v3
           WHERE note = 'golden_fixture_53_friday') END));

-- ---------------------------------------------------------------------------
-- (7) S-332. HEALTH MUST NOT BLESS A WORD IT DOES NOT KNOW.
--     is_healthy was `last_scheduled_status <> 'error'` -- a blacklist of one. Any
--     status this unit adds would fall through the verdict CASE and land on 'ok'.
--     ⭐ This is S-327's lesson one layer up: wire the writer AND the guard in the
--        same unit, or the guard is blind by construction.
--
--     Same forced-rollback + ordered-anchor idiom as block (4) (S-259): the plant
--     must be strictly newer than every live cron row or the view judges production.
-- ---------------------------------------------------------------------------
DO $append_do$
DECLARE
  v_verdict text; v_healthy text; v_sched text;
  v_before int; v_after int; v_anchor timestamptz; v_planted text;
BEGIN
  IF to_regclass('public.v_shadow_runner_health_v3') IS NULL THEN
    INSERT INTO golden.scratch (fixture_id, key, value)
    VALUES (53, 'unknown_status', jsonb_build_object('verdict','no_health_view'));
    RETURN;
  END IF;

  SELECT count(*) INTO v_before FROM public.shadow_runner_log_v3;

  SELECT GREATEST(now(), COALESCE(max(l.run_started_at), now())) + interval '1 second'
    INTO v_anchor
    FROM public.shadow_runner_log_v3 l
   WHERE l.step = 'summary' AND l.note = 'cron';

  BEGIN
    -- 'no_base' is a REAL pipeline failure mode: the engine produced nothing and the
    -- pipeline stopped. Before this unit the CHECK constraint rejects the word outright,
    -- which is itself the red -- the measurements stay 'not_measured'.
    INSERT INTO public.shadow_runner_log_v3
      (run_started_at, plan_date, step, step_target, status, note)
    VALUES (v_anchor, {{plan_date}}, 'summary', {{plan_date}}, 'no_base', 'cron');
    v_planted := 'yes';

    SELECT h.verdict, h.is_healthy::text, h.last_scheduled_status
      INTO v_verdict, v_healthy, v_sched
      FROM public.v_shadow_runner_health_v3 h;

    RAISE EXCEPTION 'golden_fixture_53_forced_rollback_unknown';
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- measurements survive in the variables; the row does not.
  END;

  SELECT count(*) INTO v_after FROM public.shadow_runner_log_v3;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (53, 'unknown_status', jsonb_build_object(
    'planted',         COALESCE(v_planted,'refused_by_check'),
    'verdict',         COALESCE(v_verdict,'not_measured'),
    'is_healthy',      COALESCE(v_healthy,'not_measured'),
    'sched_status',    COALESCE(v_sched,'not_measured'),
    'non_destructive', (v_before = v_after)));
END $append_do$;
$append$
WHERE fixture_id = 53;

-- ---------------------------------------------------------------------------
-- ASSERTIONS. seq 24..34.
-- ---------------------------------------------------------------------------
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(53, 24, 'S-331 #2 CORE: the PIPELINE classifies a calendar-skipped night as skipped_calendar. Its shipped classifier knew only blocked_gate0 and error, so the deliberate no-op arrived as a fault the moment the runner started reading receipts.',
 'SELECT value->>''sat_engine'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pipe''',
 'eq', 'skipped_calendar', true, 'P2'),

(53, 25, 'S-331 #2 CORE: and a plannable night with no picks classifies as no_picks. Both came from the same SQLERRM and are told apart only by is_refill_planning_day_v3 -- the distinction the pipeline was missing.',
 'SELECT value->>''fri_engine'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pipe''',
 'eq', 'no_picks', true, 'P2'),

(53, 26, 'S-331 #1 SHAPE PIN: the refusal lives in the NESTED engine receipt while the pipeline TOP level reports no_base. A future leg reading the top level for the refusal reason would find the wrong word.',
 'SELECT value->>''sat_top'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pipe''',
 'eq', 'no_base', true, 'P2'),

(53, 27, 'NON-VACUITY OF D-34: the runner''s Saturday night left a pipeline receipt carrying the runner''s own note -- proof the runner really goes THROUGH run_pipeline_v3 and did not keep calling the engine directly.',
 'SELECT (value->>''sat_pipeline_receipts'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''swap''',
 'gt', '0', true, 'P2'),

(53, 28, 'NON-VACUITY OF D-34: and so did the Friday night. A refusal night still writes its pipeline receipt, so the swap is observable even when nothing is planned.',
 'SELECT (value->>''fri_pipeline_receipts'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''swap''',
 'gt', '0', true, 'P2'),

(53, 29, 'The status CHECK admits no_base, so the runner can record a pipeline that produced no base plan instead of flattening it into error.',
 'SELECT golden.probe_scalar(''SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c WHERE c.conrelid=''''public.shadow_runner_log_v3''''::regclass AND c.conname=''''shadow_runner_log_v3_status_check'''''')',
 'contains', 'no_base', true, 'P2'),

(53, 30, 'The status CHECK admits composed_empty -- a composed plan with zero lines is a deliberate refusal to fall back to the base, not a fault.',
 'SELECT golden.probe_scalar(''SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c WHERE c.conrelid=''''public.shadow_runner_log_v3''''::regclass AND c.conname=''''shadow_runner_log_v3_status_check'''''')',
 'contains', 'composed_empty', true, 'P2'),

(53, 31, 'S-332 PREMISE: the plant actually landed. Before this unit the CHECK constraint refused the word outright, so seq 32/33 would have judged nothing.',
 'SELECT value->>''planted'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''unknown_status''',
 'eq', 'yes', true, 'P2'),

(53, 32, 'S-332 CORE: a scheduled night that failed with a NEW status word makes the runner unhealthy. is_healthy was a blacklist of exactly one word (error), so every status this unit introduced would have read healthy.',
 'SELECT value->>''is_healthy'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''unknown_status''',
 'eq', 'false', true, 'P2'),

(53, 33, 'S-332 CORE: and the verdict NAMES the failure rather than falling through the CASE to ok. An unnamed status is how a broken night reads green.',
 'SELECT value->>''verdict'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''unknown_status''',
 'contains', 'no_base', true, 'P2'),

(53, 34, 'S-313 CLASS: run_pipeline_v3 no longer claims the live cutover is parked as D-34. The cutover is DR-1/DR-1b; D-34 is this runner wiring, and a stale attribution inside the very function D-34 rewrites is the one place it will mislead.',
 'SELECT golden.probe_scalar(''SELECT position(''''parked (D-34)'''' in p.prosrc)::text FROM pg_proc p WHERE p.proname=''''run_pipeline_v3'''' AND p.pronamespace=''''public''''::regnamespace'')',
 'eq', '0', true, 'P2');
