-- PRD-110 leg 165 · D-34 (2 of 4) · S-332: health stops blacklisting one word
--
-- THE DEFECT. is_healthy was `last_scheduled_status <> 'error'` and the verdict CASE
-- named five statuses explicitly, falling through to 'ok' for anything else. So every
-- status D-34 introduces -- no_base, composed_empty, compose_error, stitch_error,
-- blocked_demand_error -- would have made the runner read HEALTHY with verdict 'ok'.
-- The nightly runner would have failed in a brand-new way and the health object,
-- the one thing built to notice, would have said it was fine.
--
-- ⭐ This is S-327's lesson one layer up (an unwired term is mislabelled WITH the guard
--    green) and S-326's fix applied (classify by EQUALITY against a named set, never by
--    a count or by a single excluded literal).
--
-- THE SHAPE. The GOOD words are enumerated; everything else is a failure. A future
-- status added to the CHECK constraint without being classified here now surfaces as
-- 'unknown_scheduled_status__<word>' and is_healthy=false -- it fails LOUDLY instead of
-- reading green. That is the property S-332 is really asking for: the guard must not be
-- silently extensible.
--
-- ⛔ CREATE OR REPLACE VIEW: every column keeps its name, type and POSITION. Only the
--    is_healthy and verdict expressions change.

CREATE OR REPLACE VIEW public.v_shadow_runner_health_v3 AS
WITH a AS (
  SELECT count(*) AS log_rows, max(l.run_started_at) AS last_run_at
    FROM shadow_runner_log_v3 l
), o AS (
  SELECT max(l.run_started_at) AS last_ok_at
    FROM shadow_runner_log_v3 l
   WHERE l.step = 'summary'::text AND l.status = 'ok'::text
), sl AS (
  SELECT l.run_started_at AS last_scheduled_at,
         l.status         AS last_scheduled_status,
         l.plan_date      AS last_scheduled_plan_date
    FROM shadow_runner_log_v3 l
   WHERE l.step = 'summary'::text AND l.note = 'cron'::text
   ORDER BY l.run_started_at DESC, l.id DESC
   LIMIT 1
), so AS (
  SELECT l.run_started_at AS last_scheduled_ok_at,
         l.plan_date      AS last_scheduled_ok_plan_date
    FROM shadow_runner_log_v3 l
   WHERE l.step = 'summary'::text AND l.status = 'ok'::text AND l.note = 'cron'::text
   ORDER BY l.run_started_at DESC, l.id DESC
   LIMIT 1
), g AS (
  SELECT count(*) AS gate0_nights
    FROM shadow_runner_log_v3 l
   WHERE l.step = 'summary'::text AND l.status = 'blocked_gate0'::text
     AND l.run_started_at >= (now() - '14 days'::interval)
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

       -- S-332: a WHITELIST of the summary statuses that mean "the night behaved".
       -- Anything else -- 'error', the five D-34 pipeline failures, or a word nobody
       -- has taught this view yet -- is unhealthy.
       sl.last_scheduled_at IS NOT NULL
         AND sl.last_scheduled_at >= (now() - '30:00:00'::interval)
         AND sl.last_scheduled_status = ANY (ARRAY[
               'ok'::text, 'ok_no_shadow_rows'::text, 'blocked_gate0'::text,
               'skipped_calendar'::text, 'no_picks'::text])           AS is_healthy,

       so.last_scheduled_ok_at IS NOT NULL
         AND so.last_scheduled_ok_at >= (now() - '8 days'::interval)
         AND (EXISTS (SELECT 1 FROM engine_forecast_error_v3 e
                       WHERE e.engine_tag = 'v3'::text
                         AND e.plan_date = so.last_scheduled_ok_plan_date)) AS is_measuring,

       CASE
         WHEN a.log_rows = 0 THEN 'no_runs_ever__schedule_may_be_dead'::text
         WHEN sl.last_scheduled_at IS NULL THEN 'no_scheduled_run_ever__cron_untagged_or_dead'::text
         WHEN sl.last_scheduled_at < (now() - '30:00:00'::interval) THEN 'stale__no_scheduled_run_in_30h'::text

         -- unchanged: the word every existing assertion is anchored to
         WHEN sl.last_scheduled_status = 'error'::text THEN 'last_scheduled_night_errored'::text

         -- D-34: each pipeline failure mode names itself, so the log stays diagnosable
         WHEN sl.last_scheduled_status = ANY (ARRAY[
                'no_base'::text, 'composed_empty'::text, 'compose_error'::text,
                'stitch_error'::text, 'blocked_demand_error'::text,
                'role_refused'::text])
           THEN 'last_scheduled_night_' || sl.last_scheduled_status

         -- ⭐ S-332 CATCH-ALL. Reached only by a status that is in the CHECK constraint
         --    but has never been classified here. It must be impossible for such a word
         --    to fall through to 'ok'.
         WHEN sl.last_scheduled_status <> ALL (ARRAY[
                'ok'::text, 'ok_no_shadow_rows'::text, 'blocked_gate0'::text,
                'skipped_calendar'::text, 'no_picks'::text])
           THEN 'unknown_scheduled_status__' || sl.last_scheduled_status

         WHEN sl.last_scheduled_status = 'blocked_gate0'::text THEN 'ok__blocked_gate0'::text
         WHEN sl.last_scheduled_status = 'skipped_calendar'::text THEN 'ok__calendar_skip'::text
         WHEN sl.last_scheduled_status = 'no_picks'::text THEN 'ok__no_picks'::text
         WHEN sl.last_scheduled_status = 'ok_no_shadow_rows'::text THEN 'ok__last_night_planned_nothing'::text
         WHEN so.last_scheduled_ok_at IS NULL
           OR so.last_scheduled_ok_at < (now() - '8 days'::interval)
           THEN 'ok__running_but_not_measuring'::text
         WHEN NOT (EXISTS (SELECT 1 FROM engine_forecast_error_v3 e
                            WHERE e.engine_tag = 'v3'::text
                              AND e.plan_date = so.last_scheduled_ok_plan_date))
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
