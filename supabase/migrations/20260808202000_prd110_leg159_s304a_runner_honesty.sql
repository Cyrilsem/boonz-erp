-- PRD-110 leg 159 - S-304a - a shadow night that planned NOTHING stops reading 'ok'.
--
-- THREE PARTS, one unit:
--   1. shadow_runner_log_v3_status_check gains 'ok_no_shadow_rows' (a WIDENING; no existing
--      row can violate it and no value is removed).
--   2. run_nightly_shadow_v3 takes the engine's OWN return value as its sensor
--      (`lines_written`, what THIS run banked) instead of counting the date's whole shadow
--      history, and names a zero-line night 'ok_no_shadow_rows' at both the engine step and
--      the summary. The S-112 named-skip statuses are untouched.
--   3. v_shadow_runner_health_v3 stops calling itself `is_measuring` on the strength of a
--      summary that said 'ok' while emitting no v3 series at all, and gains a verdict that
--      names the blindness plus the date of the last real v3 measurement.
--
-- WHY: on 2026-08-07 cron 45 ran, the engine banked ZERO shadow rows, the log said 'ok',
-- and the health view said is_measuring = true while v3_measured_real_dates sat at 1. The
-- scoping cause is fixed in 20260808201000; this file makes the SYMPTOM impossible to hide
-- again, whatever the next cause turns out to be.
--
-- LAW 1: fixture 37 seq 36/37/38/39/40 shipped RED in 20260808200000 before this file.

ALTER TABLE public.shadow_runner_log_v3 DROP CONSTRAINT shadow_runner_log_v3_status_check;
ALTER TABLE public.shadow_runner_log_v3 ADD CONSTRAINT shadow_runner_log_v3_status_check
  CHECK (status = ANY (ARRAY['ok'::text, 'ok_no_shadow_rows'::text, 'error'::text,
                             'blocked_gate0'::text, 'skipped'::text,
                             'skipped_calendar'::text, 'no_picks'::text]));

DO $guard$
DECLARE v_pre text;
BEGIN
  v_pre := md5(pg_get_functiondef('public.run_nightly_shadow_v3(date,integer,integer,text)'::regprocedure));
  IF v_pre = '37f5d8ced6f6885809df62d912df7523' THEN
    RAISE EXCEPTION 'leg159 M3: run_nightly_shadow_v3 already carries the S-304a image; refusing to re-apply';
  END IF;
  IF v_pre <> '70fe204617d3d903d7c8d520f3f35922' THEN
    RAISE EXCEPTION 'leg159 M3: run_nightly_shadow_v3 pre-image md5 is % (expected 70fe204617d3d903d7c8d520f3f35922)', v_pre;
  END IF;
END $guard$;

CREATE OR REPLACE FUNCTION public.run_nightly_shadow_v3(p_plan_date date DEFAULT NULL::date, p_days_cover integer DEFAULT 7, p_settle_limit integer DEFAULT 3, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid     uuid := (SELECT auth.uid());
  v_role    text;
  v_pd      date;
  v_started timestamptz := clock_timestamp();
  v_t0      timestamptz;
  v_rows    integer;
  v_engine  jsonb;
  v_eng_res jsonb;
  v_date_rows integer;
  v_measure jsonb;
  v_res     jsonb;
  v_status  text;
  v_settled jsonb := '[]'::jsonb;
  v_d       date;
  v_today   date := (now() AT TIME ZONE 'Asia/Dubai')::date;
BEGIN
  -- Article 4 role gate. NULL uid = trusted server-side caller (cron), matching the
  -- refresh_engine_forecast_error_v3 / reweight_pod_splits precedent.
  IF v_uid IS NOT NULL THEN
    SELECT up.role INTO v_role FROM public.user_profiles up WHERE up.id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager','warehouse') THEN
      RAISE EXCEPTION 'run_nightly_shadow_v3: role % may not run the shadow runner',
                      COALESCE(v_role,'<none>');
    END IF;
  END IF;

  -- Article 4: validate inputs.
  IF p_days_cover IS NULL OR p_days_cover < 1 OR p_days_cover > 60 THEN
    RAISE EXCEPTION 'run_nightly_shadow_v3: p_days_cover must be 1..60, got %', p_days_cover;
  END IF;
  IF p_settle_limit IS NULL OR p_settle_limit < 0 OR p_settle_limit > 10 THEN
    -- RISK 88 ceiling: each settle costs ~2.75s on v_sales_history_resolved.
    RAISE EXCEPTION 'run_nightly_shadow_v3: p_settle_limit must be 0..10, got %', p_settle_limit;
  END IF;

  v_pd := COALESCE(p_plan_date, public.resolve_refill_plan_date());

  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','run_nightly_shadow_v3',true);

  -------------------------------------------------------------- STEP 1: engine
  v_t0 := clock_timestamp();
  BEGIN
    -- S-304a (leg 159). The engine's OWN return value is the sensor, not a count of the
    -- date's whole shadow history: a re-run on a date that already carries rows would
    -- otherwise report the previous run's work as this run's. lines_written is what THIS
    -- run banked.
    SELECT public.engine_add_pod_v3(v_pd, p_days_cover) INTO v_eng_res;
    v_rows := COALESCE((v_eng_res->>'lines_written')::int, 0);
    SELECT count(*) INTO v_date_rows FROM public.pod_refills_shadow WHERE plan_date = v_pd;
    -- A night that banked NOTHING must not wear the same word as a night that banked 112.
    -- 2026-08-07 banked nothing, logged 'ok', and the blindness went unread for two days.
    v_status := CASE WHEN v_rows > 0 THEN 'ok' ELSE 'ok_no_shadow_rows' END;
    INSERT INTO public.shadow_runner_log_v3
      (run_started_at, plan_date, step, step_target, status, rows_affected, duration_ms,
       detail, note)
    VALUES (v_started, v_pd, 'engine', v_pd, v_status, v_rows,
            (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int,
            jsonb_build_object(
              'lines_written',            v_rows,
              'shadow_rows_for_date',     v_date_rows,
              'machines_in_scope',        v_eng_res->'machines_in_scope',
              'machines_without_shelves', v_eng_res->'machines_without_shelves',
              'shelves_in_scope',         v_eng_res->'shelves_in_scope',
              'run_id',                   v_eng_res->'run_id'),
            p_note);
    v_engine := jsonb_build_object('status', v_status,
                                   'lines_written',        v_rows,
                                   'shadow_rows_for_date', v_date_rows);
  EXCEPTION WHEN OTHERS THEN
    -- S-112. "The engine refused" is not one fact, it is four. A deliberate no-op
    -- must not wear the same word as a genuine fault, or the log stops being read.
    v_status := CASE
                  WHEN SQLERRM LIKE '%Gate 0 not passed%'
                    THEN 'blocked_gate0'
                  WHEN SQLERRM LIKE '%no picked/cs_added machines%'
                   AND NOT public.is_refill_planning_day_v3(v_pd)
                    THEN 'skipped_calendar'
                  WHEN SQLERRM LIKE '%no picked/cs_added machines%'
                    THEN 'no_picks'
                  ELSE 'error'
                END;
    INSERT INTO public.shadow_runner_log_v3
      (run_started_at, plan_date, step, step_target, status, duration_ms, sqlstate, message, note)
    VALUES (v_started, v_pd, 'engine', v_pd, v_status,
            (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int, SQLSTATE, SQLERRM, p_note);
    v_engine := jsonb_build_object('status', v_status, 'sqlstate', SQLSTATE, 'message', SQLERRM);
  END;

  ------------------------------------------------------------- STEP 2: measure
  -- Always attempted, even after a blocked engine: refresh rebuilds the date wholesale
  -- from whatever plan rows exist, so a later good run self-heals the measurement.
  v_t0 := clock_timestamp();
  BEGIN
    v_res := public.refresh_engine_forecast_error_v3(v_pd);
    v_status := CASE WHEN COALESCE((v_res->>'v19_series')::int,0)
                        + COALESCE((v_res->>'v3_series')::int,0) = 0
                     THEN 'skipped' ELSE 'ok' END;
    INSERT INTO public.shadow_runner_log_v3
      (run_started_at, plan_date, step, step_target, status, rows_affected, duration_ms,
       message, detail, note)
    VALUES (v_started, v_pd, 'measure', v_pd, v_status,
            COALESCE((v_res->>'v19_series')::int,0) + COALESCE((v_res->>'v3_series')::int,0),
            (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int,
            v_res->>'note', v_res, p_note);
    v_measure := jsonb_build_object('status', v_status,
                                    'v19_series', v_res->'v19_series',
                                    'v3_series',  v_res->'v3_series',
                                    'settled',    v_res->'settled');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO public.shadow_runner_log_v3
      (run_started_at, plan_date, step, step_target, status, duration_ms, sqlstate, message, note)
    VALUES (v_started, v_pd, 'measure', v_pd, 'error',
            (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int, SQLSTATE, SQLERRM, p_note);
    v_measure := jsonb_build_object('status','error','sqlstate',SQLSTATE,'message',SQLERRM);
  END;

  -------------------------------------------------------------- STEP 3: settle
  -- WMAPE only ever becomes a NUMBER here. Rows written before their horizon elapses
  -- carry actuals_settled=false; re-measuring that same date once the horizon has
  -- passed is what turns them into a score.
  -- RISK 88: refresh_engine_forecast_error_v3 costs ~2.75s/date because
  -- v_sales_history_resolved resolves its join key by correlated name lookup. NEVER
  -- loop it over all dates -- p_settle_limit bounds each night to a handful.
  FOR v_d IN
    SELECT DISTINCT e.plan_date
      FROM public.engine_forecast_error_v3 e
     WHERE NOT e.actuals_settled
       AND e.horizon_end <= v_today
       AND e.plan_date <> v_pd
     ORDER BY e.plan_date
     LIMIT GREATEST(COALESCE(p_settle_limit,0), 0)
  LOOP
    v_t0 := clock_timestamp();
    BEGIN
      v_res := public.refresh_engine_forecast_error_v3(v_d);
      INSERT INTO public.shadow_runner_log_v3
        (run_started_at, plan_date, step, step_target, status, rows_affected, duration_ms,
         detail, note)
      VALUES (v_started, v_pd, 'settle', v_d, 'ok',
              COALESCE((v_res->>'v19_series')::int,0) + COALESCE((v_res->>'v3_series')::int,0),
              (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int, v_res, p_note);
      v_settled := v_settled || jsonb_build_object('plan_date', v_d, 'status','ok',
                                                   'settled', v_res->'settled');
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO public.shadow_runner_log_v3
        (run_started_at, plan_date, step, step_target, status, duration_ms, sqlstate, message, note)
      VALUES (v_started, v_pd, 'settle', v_d, 'error',
              (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int, SQLSTATE, SQLERRM, p_note);
      v_settled := v_settled || jsonb_build_object('plan_date', v_d, 'status','error',
                                                   'sqlstate', SQLSTATE);
    END;
  END LOOP;

  ------------------------------------------------------------- STEP 4: summary
  -- S-112: a deliberate skip propagates its own name to the summary instead of
  -- being flattened into 'error' by the ELSE.
  v_status := CASE
                WHEN v_engine->>'status' = 'ok' AND v_measure->>'status' IN ('ok','skipped')
                  THEN 'ok'
                -- S-304a: a blank night keeps its own name all the way to the summary,
                -- because v_shadow_runner_health_v3 judges the SUMMARY row (S-113).
                WHEN v_engine->>'status' = 'ok_no_shadow_rows'
                 AND v_measure->>'status' IN ('ok','skipped')
                  THEN 'ok_no_shadow_rows'
                WHEN v_engine->>'status' IN ('blocked_gate0','skipped_calendar','no_picks')
                  THEN v_engine->>'status'
                ELSE 'error'
              END;

  INSERT INTO public.shadow_runner_log_v3
    (run_started_at, plan_date, step, step_target, status, duration_ms, detail, note)
  VALUES (v_started, v_pd, 'summary', v_pd, v_status,
          (extract(epoch FROM clock_timestamp() - v_started) * 1000)::int,
          jsonb_build_object('engine', v_engine, 'measure', v_measure, 'settle', v_settled),
          p_note);

  RETURN jsonb_build_object(
    'plan_date',   v_pd,
    'status',      v_status,
    'engine',      v_engine,
    'measure',     v_measure,
    'settled',     v_settled,
    'days_cover',  p_days_cover,
    'ran_at',      v_started);
END $function$;


-- ---------------------------------------------------------------------------
-- 3. The health view stops certifying a measurement that did not happen.
-- ---------------------------------------------------------------------------
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
         SELECT max(l.run_started_at) AS last_scheduled_ok_at
           FROM shadow_runner_log_v3 l
          WHERE l.step = 'summary'::text AND l.status = 'ok'::text AND l.note = 'cron'::text
        ), g AS (
         SELECT count(*) AS gate0_nights
           FROM shadow_runner_log_v3 l
          WHERE l.step = 'summary'::text AND l.status = 'blocked_gate0'::text AND l.run_started_at >= (now() - '14 days'::interval)
        ), m AS (
         SELECT count(DISTINCT e.plan_date) AS v3_measured_real_dates
           FROM engine_forecast_error_v3 e
          WHERE e.engine_tag = 'v3'::text AND e.plan_date < '2029-01-01'::date
        ), v3r AS (
         -- S-304a (leg 159). "The runner ran and said ok" is NOT evidence that v3 was
         -- measured: on 2026-08-07 the summary said ok and v3 emitted no series at all.
         -- The only honest witness is a real-date v3 row in engine_forecast_error_v3.
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
    so.last_scheduled_ok_at IS NOT NULL AND so.last_scheduled_ok_at >= (now() - '8 days'::interval)
      AND v3r.last_v3_date IS NOT NULL
      AND v3r.last_v3_date >= (((now() AT TIME ZONE 'Asia/Dubai'))::date - 8) AS is_measuring,
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
            WHEN v3r.last_v3_date IS NULL OR v3r.last_v3_date < (((now() AT TIME ZONE 'Asia/Dubai'))::date - 8) THEN 'ok__running_but_v3_blind'::text
            ELSE 'ok'::text
        END AS verdict,
    a.log_rows > 0 AND a.last_run_at >= (now() - '30:00:00'::interval) AS log_is_alive,
    sl.last_scheduled_at,
    COALESCE(sl.last_scheduled_status, 'none'::text) AS last_scheduled_status,
    sl.last_scheduled_plan_date,
    round(EXTRACT(epoch FROM now() - sl.last_scheduled_at) / 3600.0, 2) AS hours_since_last_scheduled,
    so.last_scheduled_ok_at,
    v3r.last_v3_date AS last_v3_measured_date
   FROM a
     CROSS JOIN o
     CROSS JOIN g
     CROSS JOIN m
     CROSS JOIN v3r
     LEFT JOIN sl ON true
     LEFT JOIN so ON true;

DO $proof$
DECLARE v_def text; v_post text; v_ok int;
BEGIN
  v_def  := pg_get_functiondef('public.run_nightly_shadow_v3(date,integer,integer,text)'::regprocedure);
  v_post := md5(v_def);
  IF v_post <> '37f5d8ced6f6885809df62d912df7523' THEN
    RAISE EXCEPTION 'leg159 M3: runner post-image md5 is % (expected 37f5d8ced6f6885809df62d912df7523) - the shipped body is not the image diffed offline', v_post;
  END IF;

  SELECT count(*) INTO v_ok FROM pg_constraint
   WHERE conrelid = 'public.shadow_runner_log_v3'::regclass
     AND conname  = 'shadow_runner_log_v3_status_check'
     AND position('ok_no_shadow_rows' in pg_get_constraintdef(oid)) > 0;
  IF v_ok <> 1 THEN
    RAISE EXCEPTION 'leg159 M3: the status CHECK does not admit ok_no_shadow_rows';
  END IF;

  -- The widening removed nothing: all six original values are still admitted.
  SELECT count(*) INTO v_ok FROM pg_constraint
   WHERE conrelid = 'public.shadow_runner_log_v3'::regclass
     AND conname  = 'shadow_runner_log_v3_status_check'
     AND position('''ok''' in pg_get_constraintdef(oid)) > 0
     AND position('''error''' in pg_get_constraintdef(oid)) > 0
     AND position('''blocked_gate0''' in pg_get_constraintdef(oid)) > 0
     AND position('''skipped''' in pg_get_constraintdef(oid)) > 0
     AND position('''skipped_calendar''' in pg_get_constraintdef(oid)) > 0
     AND position('''no_picks''' in pg_get_constraintdef(oid)) > 0;
  IF v_ok <> 1 THEN
    RAISE EXCEPTION 'leg159 M3: the widening dropped one of the six original status values';
  END IF;

  SELECT count(*) INTO v_ok FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_shadow_runner_health_v3'
     AND column_name='last_v3_measured_date';
  IF v_ok <> 1 THEN
    RAISE EXCEPTION 'leg159 M3: the health view is missing last_v3_measured_date';
  END IF;
END $proof$;
