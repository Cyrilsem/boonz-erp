-- PRD-110 · S-112 / S-113 · golden fixture 53
--
-- THE INCIDENT (measured live, leg 72, 2026-07-31 21:22Z)
-- ------------------------------------------------------
-- Cron 45 (the nightly shadow runner) fired for the first time and its run was
-- recorded as status='error':
--     engine_add_pod_v3: no picked/cs_added machines for 2026-08-01; run Stage 1 first
--
-- Leg 71's pointer diagnosed this as a SCHEDULE bug -- "job 45 asks for a plan date
-- Stage 1 has not prepared, every night, forever" -- and proposed
-- cron.alter_job(45, schedule => '45 16 * * *').
--
-- THAT DIAGNOSIS IS REFUTED BY MEASUREMENT. resolve_refill_plan_date() flips at
-- 18:00 Dubai:
--     cron 13 @ 16:00Z on 07-31 = 20:00 Dubai -> resolves 2026-08-01
--     cron 45 @ 21:22Z on 07-31 = 01:22 Dubai -> resolves 2026-08-01   <- IDENTICAL
-- The two crons already agree on the date. The schedule is correct.
--
-- The real reason 2026-08-01 had no picks: it is a SATURDAY, and PRD-035 WS-E makes
-- Saturday a delivery day with no refill plan. _build_draft_core_v3 returns
-- status='skipped_saturday' and writes nothing. Verified across every Saturday in the
-- window -- 07-11, 07-18, 07-25, 08-01 all have exactly 0 picked/cs_added machines.
--
-- So the defect is NOT the schedule. It is that a deliberate business-calendar no-op
-- is logged as an ERROR, which is what makes the runner look permanently broken and
-- trains everyone to ignore its log. Same for a plannable night on which nobody
-- picked (07-13, 07-26, 07-27 in the same window).
--
-- S-113: on that same night v_shadow_runner_health_v3 returned verdict='ok',
-- is_healthy=true, because is_healthy is pure recency over ANY run and last_ok_at was
-- satisfied by an unrelated MANUAL run at 13:20Z. A failed scheduled night is
-- indistinguishable from a healthy one as long as somebody ran the engine by hand.
--
-- This fixture is the RED baseline for both. It is deliberately carried on
-- plan_date 2030-02-23, which golden.render derives as DATE '2030-01-01' + 53 and
-- which is itself a SATURDAY -- the incident's own shape, not a paraphrase of it.

BEGIN;

DELETE FROM golden.assertions WHERE fixture_id = 53;
DELETE FROM golden.fixtures   WHERE fixture_id = 53;

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql)
VALUES (
  53,
  'Nightly shadow runner — a deliberate skip is not an error, and health judges the SCHEDULED run (S-112/S-113)',
  'cron 45 first fire 2026-07-31 21:22Z logged status=error for Saturday 2026-08-01, while v_shadow_runner_health_v3 called the same night ok',
  'P2',
  DATE '2030-02-23',
$fx$
-- S-107: a THROWN scenario leaves the previous run's scratch. Start clean.
DELETE FROM golden.scratch WHERE fixture_id = 53;

-- ---------------------------------------------------------------------------
-- (0) GUARD. A throwing check_sql aborts the whole fixture, so every probe is
--     gated on the object existing and falls back to a DISTINCT sentinel that
--     would itself fail the assertion (S-111).
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
VALUES (53, 'guard', jsonb_build_object(
  'runner', CASE WHEN to_regprocedure('public.run_nightly_shadow_v3(date,integer,integer,text)') IS NULL
                 THEN 'absent' ELSE 'present' END,
  'health', CASE WHEN to_regclass('public.v_shadow_runner_health_v3') IS NULL
                 THEN 'absent' ELSE 'present' END));

-- ---------------------------------------------------------------------------
-- (1) PREMISE. The date really is a Saturday, really has no picks, and Stage 1
--     really refuses it on purpose. Without this the fixture could go green for
--     the wrong reason (the vacuous-green lesson).
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_draft text;
BEGIN
  BEGIN
    v_draft := public.build_draft_for_confirmed_v3({{plan_date}})->>'status';
  EXCEPTION WHEN OTHERS THEN
    v_draft := 'threw:' || SQLSTATE;
  END;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (53, 'premise', jsonb_build_object(
    'dow_saturday',   EXTRACT(DOW FROM {{plan_date}})::int,
    'dow_friday',     EXTRACT(DOW FROM ({{plan_date}} - 1))::int,
    'picks_saturday', (SELECT count(*) FROM public.machines_to_visit
                        WHERE plan_date = {{plan_date}} AND status IN ('picked','cs_added')),
    'picks_friday',   (SELECT count(*) FROM public.machines_to_visit
                        WHERE plan_date = ({{plan_date}} - 1) AND status IN ('picked','cs_added')),
    'stage1_status',  v_draft));
END $do$;

-- ---------------------------------------------------------------------------
-- (2) THE INCIDENT, on the calendar-skipped night. p_settle_limit => 0 because
--     RISK 88 makes each settle ~2.75s and this fixture is not measuring settle.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb;
BEGIN
  IF to_regprocedure('public.run_nightly_shadow_v3(date,integer,integer,text)') IS NULL THEN
    INSERT INTO golden.scratch (fixture_id, key, value)
    VALUES (53, 'sat_run', jsonb_build_object('status','no_runner'));
    RETURN;
  END IF;

  BEGIN
    v := public.run_nightly_shadow_v3({{plan_date}}, 7, 0, 'golden_fixture_53_saturday');
  EXCEPTION WHEN OTHERS THEN
    v := jsonb_build_object('status','THREW','sqlstate',SQLSTATE,'message',SQLERRM);
  END;

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (53, 'sat_run', v);
END $do$;

INSERT INTO golden.scratch (fixture_id, key, value)
VALUES (53, 'sat_log', jsonb_build_object(
  'summary_status', COALESCE((SELECT status FROM public.shadow_runner_log_v3
                               WHERE note = 'golden_fixture_53_saturday' AND step = 'summary'
                               ORDER BY id DESC LIMIT 1), 'no_row'),
  'engine_status',  COALESCE((SELECT status FROM public.shadow_runner_log_v3
                               WHERE note = 'golden_fixture_53_saturday' AND step = 'engine'
                               ORDER BY id DESC LIMIT 1), 'no_row'),
  'engine_message', COALESCE((SELECT left(message,160) FROM public.shadow_runner_log_v3
                               WHERE note = 'golden_fixture_53_saturday' AND step = 'engine'
                               ORDER BY id DESC LIMIT 1), 'no_row')));

-- ---------------------------------------------------------------------------
-- (3) THE OTHER SHAPE: a PLANNABLE night on which nobody picked. Friday
--     2030-02-22 is not calendar-skipped, so it must classify differently from
--     the Saturday -- "nobody picked" and "we never plan Saturdays" are not the
--     same fact and must not collapse into one status.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb;
BEGIN
  IF to_regprocedure('public.run_nightly_shadow_v3(date,integer,integer,text)') IS NULL THEN
    INSERT INTO golden.scratch (fixture_id, key, value)
    VALUES (53, 'fri_run', jsonb_build_object('status','no_runner'));
    RETURN;
  END IF;

  BEGIN
    v := public.run_nightly_shadow_v3({{plan_date}} - 1, 7, 0, 'golden_fixture_53_friday');
  EXCEPTION WHEN OTHERS THEN
    v := jsonb_build_object('status','THREW','sqlstate',SQLSTATE,'message',SQLERRM);
  END;

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (53, 'fri_run', v);
END $do$;

INSERT INTO golden.scratch (fixture_id, key, value)
VALUES (53, 'fri_log', jsonb_build_object(
  'summary_status', COALESCE((SELECT status FROM public.shadow_runner_log_v3
                               WHERE note = 'golden_fixture_53_friday' AND step = 'summary'
                               ORDER BY id DESC LIMIT 1), 'no_row')));

-- ---------------------------------------------------------------------------
-- (4) S-113, THE MASKING PROBE. A SCHEDULED night that failed outright, plus a
--     MANUAL run that succeeded an hour later -- exactly 2026-07-31. Health must
--     report the scheduled failure and must not be rescued by the manual run.
--
--     Uses fixture 31/37's forced-rollback idiom: the measurement survives in
--     PL/pgSQL variables, the rows do not.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_verdict text; v_healthy text; v_sched text;
  v_before int; v_after int;
BEGIN
  IF to_regclass('public.v_shadow_runner_health_v3') IS NULL THEN
    INSERT INTO golden.scratch (fixture_id, key, value)
    VALUES (53, 'mask', jsonb_build_object('verdict','no_health_view'));
    RETURN;
  END IF;

  SELECT count(*) INTO v_before FROM public.shadow_runner_log_v3;

  BEGIN
    -- the SCHEDULED night, and it failed outright
    INSERT INTO public.shadow_runner_log_v3
      (run_started_at, plan_date, step, step_target, status, note)
    VALUES (now() - interval '2 hours', {{plan_date}}, 'summary', {{plan_date}}, 'error', 'cron');

    -- and the MANUAL run that succeeded the same day -- the mask
    INSERT INTO public.shadow_runner_log_v3
      (run_started_at, plan_date, step, step_target, status, note)
    VALUES (now() - interval '1 hour', {{plan_date}}, 'summary', {{plan_date}}, 'ok',
            'golden_fixture_53_manual_mask');

    SELECT h.verdict, h.is_healthy::text
      INTO v_verdict, v_healthy
      FROM public.v_shadow_runner_health_v3 h;

    BEGIN
      SELECT h.last_scheduled_status INTO v_sched FROM public.v_shadow_runner_health_v3 h;
    EXCEPTION WHEN undefined_column THEN
      v_sched := 'column_absent';
    END;

    RAISE EXCEPTION 'golden_fixture_53_forced_rollback';
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- the measurements survive the rollback; the two rows do not.
  END;

  SELECT count(*) INTO v_after FROM public.shadow_runner_log_v3;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (53, 'mask', jsonb_build_object(
    'verdict',               COALESCE(v_verdict, 'not_measured'),
    'is_healthy',            COALESCE(v_healthy, 'not_measured'),
    'last_scheduled_status', COALESCE(v_sched,   'not_measured'),
    'rows_before',           v_before,
    'rows_after',            v_after,
    'non_destructive',       (v_before = v_after)));
END $do$;
$fx$
);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required) VALUES

(53, 1, 'OBJECT: the nightly shadow runner exists with its 4-arg signature',
 $a$SELECT golden.probe_scalar('SELECT COALESCE(to_regprocedure(''public.run_nightly_shadow_v3(date,integer,integer,text)'')::text, ''absent'')')$a$,
 'eq', 'run_nightly_shadow_v3(date,integer,integer,text)', 'P2'),

(53, 2, 'OBJECT: the health view exists',
 $a$SELECT golden.probe_scalar('SELECT COALESCE(to_regclass(''public.v_shadow_runner_health_v3'')::text, ''absent'')')$a$,
 'eq', 'v_shadow_runner_health_v3', 'P2'),

(53, 3, 'GUARD: the scenario found a real runner, so every probe below measured something',
 $a$SELECT value->>'runner' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='guard'$a$,
 'eq', 'present', 'P2'),

(53, 4, 'PREMISE: the fixture date is genuinely a Saturday (DOW 6) — the incident''s own shape',
 $a$SELECT value->>'dow_saturday' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='premise'$a$,
 'eq', '6', 'P2'),

(53, 5, 'PREMISE: the day before it is a Friday (DOW 5) — a plannable day, so the two cases differ by calendar, not by luck',
 $a$SELECT value->>'dow_friday' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='premise'$a$,
 'eq', '5', 'P2'),

(53, 6, 'PREMISE: the Saturday has zero picked/cs_added machines',
 $a$SELECT value->>'picks_saturday' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='premise'$a$,
 'eq', '0', 'P2'),

(53, 7, 'PREMISE: the Friday also has zero picks, so the two runs differ ONLY in calendar status',
 $a$SELECT value->>'picks_friday' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='premise'$a$,
 'eq', '0', 'P2'),

(53, 8, 'PREMISE: Stage 1 refuses the Saturday deliberately (PRD-035 WS-E), it does not fail on it',
 $a$SELECT value->>'stage1_status' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='premise'$a$,
 'eq', 'skipped_saturday', 'P2'),

(53, 9, 'The runner RETURNED on the calendar-skipped night rather than throwing',
 $a$SELECT (value->>'status' <> 'THREW')::text FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='sat_run'$a$,
 'eq', 'true', 'P2'),

(53, 10, 'S-112 CORE: the engine step on a calendar-skipped night is recorded as skipped_calendar, NOT as error',
 $a$SELECT value->>'engine_status' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='sat_log'$a$,
 'eq', 'skipped_calendar', 'P2'),

(53, 11, 'S-112 CORE: and so is the run''s summary — a deliberate no-op is not a failure',
 $a$SELECT value->>'summary_status' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='sat_log'$a$,
 'eq', 'skipped_calendar', 'P2'),

(53, 12, 'S-112: the returned receipt agrees with the log',
 $a$SELECT value->>'status' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='sat_run'$a$,
 'eq', 'skipped_calendar', 'P2'),

(53, 13, 'TRUTHFULNESS: reclassifying did not erase the reason — the engine''s own words survive in the log',
 $a$SELECT value->>'engine_message' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='sat_log'$a$,
 'contains', 'no picked/cs_added machines', 'P2'),

(53, 14, 'S-112: a PLANNABLE night with no picks classifies as no_picks — distinct from the calendar skip',
 $a$SELECT value->>'summary_status' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='fri_log'$a$,
 'eq', 'no_picks', 'P2'),

(53, 15, 'S-113 CORE: a SCHEDULED night that errored makes the runner unhealthy, even though a manual run succeeded an hour later',
 $a$SELECT value->>'is_healthy' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='mask'$a$,
 'eq', 'false', 'P2'),

(53, 16, 'S-113 CORE: and the verdict NAMES the failed scheduled night rather than saying ok',
 $a$SELECT value->>'verdict' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='mask'$a$,
 'eq', 'last_scheduled_night_errored', 'P2'),

(53, 17, 'S-113: health exposes the scheduled run''s status as a first-class column',
 $a$SELECT value->>'last_scheduled_status' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='mask'$a$,
 'eq', 'error', 'P2'),

(53, 18, 'The masking probe was NON-DESTRUCTIVE: its two rows rolled back and the log is byte-for-byte the size it was',
 $a$SELECT value->>'non_destructive' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='mask'$a$,
 'eq', 'true', 'P2'),

(53, 19, 'The status CHECK admits the new vocabulary, so the runner can record what it means',
 $a$SELECT golden.probe_scalar('SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c WHERE c.conrelid=''public.shadow_runner_log_v3''::regclass AND c.conname=''shadow_runner_log_v3_status_check''')$a$,
 'contains', 'skipped_calendar', 'P2'),

(53, 20, 'The status CHECK admits no_picks too',
 $a$SELECT golden.probe_scalar('SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c WHERE c.conrelid=''public.shadow_runner_log_v3''::regclass AND c.conname=''shadow_runner_log_v3_status_check''')$a$,
 'contains', 'no_picks', 'P2'),

(53, 21, 'ACL: anon holds NO privilege on the health view (S-104 fleet convention)',
 $a$SELECT golden.probe_scalar('SELECT count(*)::text FROM information_schema.role_table_grants WHERE grantee=''anon'' AND table_schema=''public'' AND table_name=''v_shadow_runner_health_v3''')$a$,
 'eq', '0', 'P2'),

(53, 22, 'LAW 4 TRIPWIRE: this fixture wrote no live plan rows for its own date',
 $a$SELECT golden.probe_scalar('SELECT count(*)::text FROM public.refill_plan_output WHERE plan_date = DATE ''2030-02-23''')$a$,
 'eq', '0', 'P2');

COMMIT;
