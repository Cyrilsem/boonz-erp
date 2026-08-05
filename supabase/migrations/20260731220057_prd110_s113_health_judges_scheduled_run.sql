-- PRD-110 · S-113 · health is judged on the SCHEDULED run, not on any run
--
-- RED baseline: golden fixture 53 seq 15, 16, 17.
--
-- On 2026-07-31 the scheduled runner failed at every step and the health view said
-- verdict='ok', is_healthy=true. Both signals were pure recency over ANY row, and
-- last_ok_at had been satisfied by an unrelated MANUAL run at 13:20Z. So a night the
-- cron failed outright was indistinguishable from a healthy one, provided somebody
-- had run the engine by hand that day. That is the whole defect: the view was
-- answering "did anything happen recently" when the question is "did the SCHEDULE do
-- its job".
--
-- Identifying the scheduled run needs a mark only the schedule can make. The cron
-- command now tags itself p_note => 'cron'; a human calling the runner by hand does
-- not, and NULL cannot serve as the mark because that is precisely what the masking
-- manual run carried.
--
-- ⚠ IMMEDIATE AND EXPECTED CONSEQUENCE: no cron-tagged row exists yet, so until job
-- 45's next fire the live verdict reads 'no_scheduled_run_ever__cron_untagged_or_dead'.
-- That is the honest answer -- no scheduled run has ever been identifiable as one --
-- and it self-heals on the next fire. It is not a new fault.
--
-- ⛔ WHAT THIS MIGRATION DELIBERATELY DOES NOT DO: change cron 45's SCHEDULE.
-- Leg 71 proposed cron.alter_job(45, schedule => '45 16 * * *') on the premise that
-- job 45 "asks for a plan date Stage 1 has not prepared". Measured, that premise is
-- false. resolve_refill_plan_date() flips at 18:00 Dubai, so cron 13 at 16:00Z
-- (20:00 Dubai) and cron 45 at 21:22Z (01:22 Dubai next day) resolve the SAME date --
-- both returned 2026-08-01 on 07-31. The schedules already agree. Moving job 45 to
-- 16:45Z would also sample the plan 45 minutes after Stage 1 and therefore BEFORE the
-- overnight human cs_added/cs_dropped edits, which the pick timestamps show landing
-- between 20:00 and ~06:00 Dubai. The current 01:22 Dubai slot captures them. The
-- schedule is correct and stays untouched.

BEGIN;

-- ---------------------------------------------------------------------------
-- (1) The view.
--
--     CREATE OR REPLACE VIEW may only APPEND columns, so the nine incumbent
--     columns keep their names, types and order. Two of them change MEANING and
--     that is the point of the migration:
--       is_healthy   was "any run within 30h" -> now "the SCHEDULE ran within 30h
--                    and its night did not error"
--       is_measuring was "any ok within 30h"  -> now "a SCHEDULED night produced a
--                    measurable plan recently", on an 8-day window because the
--                    calendar itself guarantees gaps (every Saturday is skipped,
--                    and no-pick nights are legitimate under manual Gate 0)
--     The old "is the log alive at all" signal does not disappear -- it moves to a
--     column that says what it means, log_is_alive, which is what fixture 37's
--     absence detection was always really asserting.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_shadow_runner_health_v3 AS
WITH a AS (
  SELECT count(*) AS log_rows,
         max(l.run_started_at) AS last_run_at
    FROM public.shadow_runner_log_v3 l
), o AS (
  SELECT max(l.run_started_at) AS last_ok_at
    FROM public.shadow_runner_log_v3 l
   WHERE l.step = 'summary' AND l.status = 'ok'
), sl AS (
  -- the most recent SCHEDULED night, whatever it did
  SELECT l.run_started_at AS last_scheduled_at,
         l.status         AS last_scheduled_status,
         l.plan_date      AS last_scheduled_plan_date
    FROM public.shadow_runner_log_v3 l
   WHERE l.step = 'summary' AND l.note = 'cron'
   ORDER BY l.run_started_at DESC, l.id DESC
   LIMIT 1
), so AS (
  -- the most recent SCHEDULED night that actually produced a plan to measure
  SELECT max(l.run_started_at) AS last_scheduled_ok_at
    FROM public.shadow_runner_log_v3 l
   WHERE l.step = 'summary' AND l.status = 'ok' AND l.note = 'cron'
), g AS (
  SELECT count(*) AS gate0_nights
    FROM public.shadow_runner_log_v3 l
   WHERE l.step = 'summary' AND l.status = 'blocked_gate0'
     AND l.run_started_at >= (now() - '14 days'::interval)
), m AS (
  SELECT count(DISTINCT e.plan_date) AS v3_measured_real_dates
    FROM public.engine_forecast_error_v3 e
   WHERE e.engine_tag = 'v3' AND e.plan_date < '2029-01-01'::date
)
SELECT
  a.log_rows,
  a.last_run_at,
  o.last_ok_at,
  g.gate0_nights,
  m.v3_measured_real_dates,
  round(EXTRACT(epoch FROM now() - a.last_run_at) / 3600.0, 2) AS hours_since_last_run,

  -- S-113: judged on the SCHEDULE.
  (sl.last_scheduled_at IS NOT NULL
     AND sl.last_scheduled_at >= (now() - '30:00:00'::interval)
     AND sl.last_scheduled_status <> 'error')                        AS is_healthy,

  (so.last_scheduled_ok_at IS NOT NULL
     AND so.last_scheduled_ok_at >= (now() - '8 days'::interval))     AS is_measuring,

  CASE
    WHEN a.log_rows = 0
      THEN 'no_runs_ever__schedule_may_be_dead'::text
    WHEN sl.last_scheduled_at IS NULL
      THEN 'no_scheduled_run_ever__cron_untagged_or_dead'::text
    WHEN sl.last_scheduled_at < (now() - '30:00:00'::interval)
      THEN 'stale__no_scheduled_run_in_30h'::text
    WHEN sl.last_scheduled_status = 'error'
      THEN 'last_scheduled_night_errored'::text
    WHEN sl.last_scheduled_status = 'blocked_gate0'
      THEN 'ok__blocked_gate0'::text
    WHEN sl.last_scheduled_status = 'skipped_calendar'
      THEN 'ok__calendar_skip'::text
    WHEN sl.last_scheduled_status = 'no_picks'
      THEN 'ok__no_picks'::text
    WHEN so.last_scheduled_ok_at IS NULL
      OR so.last_scheduled_ok_at < (now() - '8 days'::interval)
      THEN 'ok__running_but_not_measuring'::text
    ELSE 'ok'::text
  END AS verdict,

  -- appended columns
  (a.log_rows > 0 AND a.last_run_at >= (now() - '30:00:00'::interval))  AS log_is_alive,
  sl.last_scheduled_at,
  COALESCE(sl.last_scheduled_status, 'none')                            AS last_scheduled_status,
  sl.last_scheduled_plan_date,
  round(EXTRACT(epoch FROM now() - sl.last_scheduled_at) / 3600.0, 2)   AS hours_since_last_scheduled,
  so.last_scheduled_ok_at
FROM a
CROSS JOIN o
CROSS JOIN g
CROSS JOIN m
LEFT JOIN sl ON true
LEFT JOIN so ON true;

COMMENT ON VIEW public.v_shadow_runner_health_v3 IS
  'PRD-110 P2.7 / S-113. Health of the NIGHTLY SHADOW RUNNER, judged on the scheduled '
  'run only (shadow_runner_log_v3.note = ''cron'', which cron job 45 sets and a human '
  'calling the runner by hand does not). is_healthy and verdict answer "did the '
  'schedule do its job"; log_is_alive answers the weaker "did anything run at all" and '
  'is the dead-schedule absence detector. A calendar skip or a no-pick night is not a '
  'failure and does not make the runner unhealthy.';

-- S-104 / S-57: the v3 ACL is a fleet convention, and CREATE OR REPLACE VIEW does not
-- reset grants -- restated so the object cannot drift open by omission.
REVOKE ALL ON public.v_shadow_runner_health_v3 FROM PUBLIC, anon;
GRANT SELECT ON public.v_shadow_runner_health_v3 TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- (2) The schedule marks itself. Command only -- the cron EXPRESSION is untouched,
--     see the header for why the proposed reschedule was refuted.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_sched_before text; v_sched_after text; v_cmd text;
BEGIN
  SELECT schedule INTO v_sched_before FROM cron.job WHERE jobid = 45;
  IF v_sched_before IS NULL THEN
    RAISE EXCEPTION 's113: cron job 45 not found -- refusing to guess at its identity';
  END IF;

  PERFORM cron.alter_job(
    45,
    command => 'SET statement_timeout=''1200000''; SELECT public.run_nightly_shadow_v3(p_note => ''cron'');');

  SELECT schedule, command INTO v_sched_after, v_cmd FROM cron.job WHERE jobid = 45;

  IF v_sched_after IS DISTINCT FROM v_sched_before THEN
    RAISE EXCEPTION 's113: cron 45 schedule changed from % to % -- this migration must not touch it',
                    v_sched_before, v_sched_after;
  END IF;
  IF v_cmd NOT LIKE '%p_note => ''cron''%' THEN
    RAISE EXCEPTION 's113: cron 45 command did not take the scheduled-run tag: %', v_cmd;
  END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- (3) Fixture 37 keeps its meaning, under the name that is actually true.
--
--     Its seq 17/18 were never about "the schedule succeeded" -- they are the
--     ABSENCE detector: empty the log, the view must go dark; run a night, it must
--     light up. That is log_is_alive exactly. Re-pointed rather than deleted, and
--     the scratch keys are renamed with it so nothing reads 'is_healthy' while
--     measuring something else (S-103: an assertion edit is two fields).
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_before text; v_after text;
BEGIN
  SELECT scenario_sql INTO v_before FROM golden.fixtures WHERE fixture_id = 37;
  IF v_before IS NULL THEN
    RAISE EXCEPTION 's113: fixture 37 is missing -- refusing to silently skip its re-point';
  END IF;

  v_after := replace(v_before, 'SELECT is_healthy::text INTO', 'SELECT log_is_alive::text INTO');
  v_after := replace(v_after,  '''fresh_is_healthy'', v_fresh', '''fresh_log_alive'', v_fresh');
  v_after := replace(v_after,  '''empty_is_healthy'', v_empty', '''empty_log_alive'', v_empty');

  IF v_after = v_before THEN
    RAISE EXCEPTION 's113: fixture 37 re-point matched nothing -- the scenario text moved, edit it by hand';
  END IF;
  IF v_after LIKE '%is_healthy::text INTO%' THEN
    RAISE EXCEPTION 's113: fixture 37 still reads is_healthy into its absence probe';
  END IF;

  UPDATE golden.fixtures SET scenario_sql = v_after WHERE fixture_id = 37;
END $do$;

UPDATE golden.assertions
   SET description = 'ABSENCE DETECTION: with the log emptied, the health view reports the schedule DARK (log_is_alive false)',
       check_sql   = $a$SELECT value->>'empty_log_alive' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='health'$a$
 WHERE fixture_id = 37 AND seq = 17;

UPDATE golden.assertions
   SET description = 'ABSENCE DETECTION: and reports the schedule ALIVE immediately after a good night (log_is_alive true)',
       check_sql   = $a$SELECT value->>'fresh_log_alive' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='health'$a$
 WHERE fixture_id = 37 AND seq = 18;

DO $do$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE fixture_id = 37 AND seq IN (17,18) AND check_sql LIKE '%_log_alive%';
  IF v_n <> 2 THEN
    RAISE EXCEPTION 's113: expected 2 re-pointed fixture-37 assertions, found %', v_n;
  END IF;
END $do$;

COMMIT;
