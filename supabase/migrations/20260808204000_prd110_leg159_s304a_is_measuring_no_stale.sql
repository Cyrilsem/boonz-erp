-- PRD-110 leg 159 - S-304a second half - is_measuring stops being satisfied by a STALE measurement.
--
-- The version shipped an hour earlier in 20260808202000 required "some real-date v3 row within
-- 8 days". That is a WINDOW, and a window keeps answering yes for a week after the runner has gone
-- blind. Live proof at the moment of writing: v3's last real-date measurement is 2026-08-04, the
-- runner has emitted nothing since, and is_measuring still read TRUE - through exactly the window
-- in which CS is being asked to judge the DR-1 cutover.
--
-- The honest test needs no tunable number: take the NEWEST scheduled summary that said 'ok' and ask
-- whether THAT night emitted v3 series for its own plan_date. 2026-08-06's run said 'ok' for
-- plan_date 2026-08-07 and emitted 46 v19 series and 0 v3 series, so the answer is no.
-- The 8-day recency clause is kept as a second, independent condition - a runner that has not said
-- 'ok' in over a week is not measuring either, whatever the last good night looked like.
--
-- LAW 1: fixture 37 seq 41/42/43 shipped RED in 20260808203000 before this file.
-- Grants survive CREATE OR REPLACE (it replaces, it does not drop); pg_class.reloptions on this
-- view is NULL and stays NULL - there is no security_invoker flag to lose, the METRICS_REGISTRY
-- claim that there was one is corrected in the same commit.

CREATE OR REPLACE VIEW public.v_shadow_runner_health_v3 AS
 WITH a AS (
         SELECT count(*) AS log_rows,
            max(l.run_started_at) AS last_run_at
           FROM shadow_runner_log_v3 l
        ), o AS (
         SELECT max(l.run_started_at) AS last_ok_at
           FROM shadow_runner_log_v3 l
          WHERE l.step = 'summary'::text AND l.status = 'ok'::text
        ), sl AS (
         SELECT l.run_started_at AS last_scheduled_at,
            l.status AS last_scheduled_status,
            l.plan_date AS last_scheduled_plan_date
           FROM shadow_runner_log_v3 l
          WHERE l.step = 'summary'::text AND l.note = 'cron'::text
          ORDER BY l.run_started_at DESC, l.id DESC
         LIMIT 1
        ), so AS (
         -- S-304a (leg 159): the newest scheduled night that said 'ok', and the plan_date it said
         -- it about. max(run_started_at) alone could not answer "did THAT night measure anything".
         SELECT l.run_started_at AS last_scheduled_ok_at,
            l.plan_date AS last_scheduled_ok_plan_date
           FROM shadow_runner_log_v3 l
          WHERE l.step = 'summary'::text AND l.status = 'ok'::text AND l.note = 'cron'::text
          ORDER BY l.run_started_at DESC, l.id DESC
         LIMIT 1
        ), g AS (
         SELECT count(*) AS gate0_nights
           FROM shadow_runner_log_v3 l
          WHERE l.step = 'summary'::text AND l.status = 'blocked_gate0'::text AND l.run_started_at >= (now() - '14 days'::interval)
        ), m AS (
         SELECT count(DISTINCT e.plan_date) AS v3_measured_real_dates
           FROM engine_forecast_error_v3 e
          WHERE e.engine_tag = 'v3'::text AND e.plan_date < '2029-01-01'::date
        ), v3r AS (
         SELECT max(e.plan_date) AS last_v3_date
           FROM engine_forecast_error_v3 e
          WHERE e.engine_tag = 'v3'::text AND e.plan_date < '2029-01-01'::date
        )
 SELECT a.log_rows,
    a.last_run_at,
    o.last_ok_at,
    g.gate0_nights,
    m.v3_measured_real_dates,
    round(EXTRACT(epoch FROM now() - a.last_run_at) / 3600.0, 2) AS hours_since_last_run,
    sl.last_scheduled_at IS NOT NULL AND sl.last_scheduled_at >= (now() - '30:00:00'::interval) AND sl.last_scheduled_status <> 'error'::text AS is_healthy,
    so.last_scheduled_ok_at IS NOT NULL
      AND so.last_scheduled_ok_at >= (now() - '8 days'::interval)
      AND EXISTS (SELECT 1 FROM engine_forecast_error_v3 e
                   WHERE e.engine_tag = 'v3'::text
                     AND e.plan_date = so.last_scheduled_ok_plan_date) AS is_measuring,
        CASE
            WHEN a.log_rows = 0 THEN 'no_runs_ever__schedule_may_be_dead'::text
            WHEN sl.last_scheduled_at IS NULL THEN 'no_scheduled_run_ever__cron_untagged_or_dead'::text
            WHEN sl.last_scheduled_at < (now() - '30:00:00'::interval) THEN 'stale__no_scheduled_run_in_30h'::text
            WHEN sl.last_scheduled_status = 'error'::text THEN 'last_scheduled_night_errored'::text
            WHEN sl.last_scheduled_status = 'blocked_gate0'::text THEN 'ok__blocked_gate0'::text
            WHEN sl.last_scheduled_status = 'skipped_calendar'::text THEN 'ok__calendar_skip'::text
            WHEN sl.last_scheduled_status = 'no_picks'::text THEN 'ok__no_picks'::text
            WHEN sl.last_scheduled_status = 'ok_no_shadow_rows'::text THEN 'ok__last_night_planned_nothing'::text
            WHEN so.last_scheduled_ok_at IS NULL OR so.last_scheduled_ok_at < (now() - '8 days'::interval) THEN 'ok__running_but_not_measuring'::text
            WHEN NOT EXISTS (SELECT 1 FROM engine_forecast_error_v3 e
                              WHERE e.engine_tag = 'v3'::text
                                AND e.plan_date = so.last_scheduled_ok_plan_date)
              THEN 'ok__running_but_v3_blind'::text
            ELSE 'ok'::text
        END AS verdict,
    a.log_rows > 0 AND a.last_run_at >= (now() - '30:00:00'::interval) AS log_is_alive,
    sl.last_scheduled_at,
    COALESCE(sl.last_scheduled_status, 'none'::text) AS last_scheduled_status,
    sl.last_scheduled_plan_date,
    round(EXTRACT(epoch FROM now() - sl.last_scheduled_at) / 3600.0, 2) AS hours_since_last_scheduled,
    so.last_scheduled_ok_at,
    v3r.last_v3_date AS last_v3_measured_date,
    so.last_scheduled_ok_plan_date
   FROM a
     CROSS JOIN o
     CROSS JOIN g
     CROSS JOIN m
     CROSS JOIN v3r
     LEFT JOIN sl ON true
     LEFT JOIN so ON true;

DO $proof$
DECLARE v_def text; v_n int;
BEGIN
  v_def := pg_get_viewdef('public.v_shadow_runner_health_v3'::regclass, true);
  IF position('last_scheduled_ok_plan_date' in v_def) = 0 THEN
    RAISE EXCEPTION 'leg159 M5: the view does not key is_measuring on the last ok night plan_date';
  END IF;

  SELECT count(*) INTO v_n FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_shadow_runner_health_v3'
     AND column_name IN ('is_measuring','verdict','last_v3_measured_date','last_scheduled_ok_plan_date');
  IF v_n <> 4 THEN
    RAISE EXCEPTION 'leg159 M5: expected all four columns, found %', v_n;
  END IF;

  -- Non-vacuity: the readers still read. anon must still hold nothing.
  SELECT count(*) INTO v_n FROM information_schema.role_table_grants
   WHERE table_schema='public' AND table_name='v_shadow_runner_health_v3'
     AND grantee = 'anon';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'leg159 M5: anon acquired a grant on the health view';
  END IF;
  SELECT count(*) INTO v_n FROM information_schema.role_table_grants
   WHERE table_schema='public' AND table_name='v_shadow_runner_health_v3'
     AND grantee = 'authenticated' AND privilege_type = 'SELECT';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'leg159 M5: authenticated lost SELECT on the health view';
  END IF;
END $proof$;
