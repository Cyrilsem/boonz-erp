-- PRD-110 · S-112 · the nightly shadow runner tells the truth about a skipped night
--
-- RED baseline: golden fixture 53, 13/22 (seq 10, 11, 12, 14, 19, 20 red on this half).
--
-- A deliberate business-calendar no-op was being recorded as status='error'. Two
-- distinct facts were collapsing into that one word:
--
--   skipped_calendar  PRD-035 WS-E makes Saturday a delivery day. Stage 1 returns
--                     'skipped_saturday' and writes nothing, ON PURPOSE. There is
--                     nothing to shadow and nothing is wrong.
--   no_picks          a plannable night on which nobody picked any machine. Gate 0 is
--                     manual-only in wave 1 (CS decision #1 / LAW 11), so this is a
--                     legitimate and recurring state -- 2026-07-13, 07-26, 07-27 in the
--                     last three weeks alone. Worth seeing; not a failure.
--
-- Neither is an error, and calling them one is how a log earns the right to be ignored.
-- Note what is NOT changed: the engine still RAISEs exactly as before, and its own
-- words are still written verbatim into the log's message column (fixture 53 seq 13
-- pins that). This migration changes how the runner CLASSIFIES what it caught, never
-- what it caught.
--
-- LAW 3: versioned addition, no destructive change, no protected-entity write. The
-- CHECK is widened, never narrowed, so every one of the 66 existing rows stays legal.

BEGIN;

-- ---------------------------------------------------------------------------
-- (1) The calendar rule gets ONE name.
--
--     PRD-035 WS-E currently lives as a bare EXTRACT(DOW)=6 inside
--     _build_draft_core_v3. Copying that expression into the runner would create a
--     second source of truth for a business rule -- exactly the shape the
--     DATA-SOURCE LAW exists to prevent. So it gets a name here and the runner asks
--     the name, not the number.
--
--     ⚠ KNOWN DUPLICATION, RECORDED NOT HIDDEN: _build_draft_core_v3 still carries
--     its own inline copy. Collapsing it onto this helper means editing the live
--     Stage 1 engine, which LAW 12 puts out of scope for this unit. Logged in the
--     PARKING-LOT for reconciliation.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_refill_planning_day_v3(p_plan_date date)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public', 'pg_catalog'
AS $function$
  -- PRD-035 WS-E: Saturday (DOW 6) is a delivery day, never a refill-plan day.
  SELECT p_plan_date IS NOT NULL AND EXTRACT(DOW FROM p_plan_date) <> 6;
$function$;

COMMENT ON FUNCTION public.is_refill_planning_day_v3(date) IS
  'PRD-110 S-112. Canonical name for the PRD-035 WS-E refill calendar: Saturday is a '
  'delivery day and is never planned. Read-only. _build_draft_core_v3 still carries an '
  'inline copy of this rule; reconciling the two is parked.';

REVOKE ALL ON FUNCTION public.is_refill_planning_day_v3(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_refill_planning_day_v3(date) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- (2) Widen the status vocabulary. Additive: every existing value stays legal.
-- ---------------------------------------------------------------------------
ALTER TABLE public.shadow_runner_log_v3
  DROP CONSTRAINT IF EXISTS shadow_runner_log_v3_status_check;

ALTER TABLE public.shadow_runner_log_v3
  ADD CONSTRAINT shadow_runner_log_v3_status_check
  CHECK (status = ANY (ARRAY[
    'ok'::text, 'error'::text, 'blocked_gate0'::text, 'skipped'::text,
    'skipped_calendar'::text, 'no_picks'::text]));

-- ---------------------------------------------------------------------------
-- (3) The runner. Identical to the incumbent except for the two classification
--     sites -- the engine EXCEPTION handler and the summary CASE.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.run_nightly_shadow_v3(
  p_plan_date    date    DEFAULT NULL::date,
  p_days_cover   integer DEFAULT 7,
  p_settle_limit integer DEFAULT 3,
  p_note         text    DEFAULT NULL::text)
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
    PERFORM public.engine_add_pod_v3(v_pd, p_days_cover);
    SELECT count(*) INTO v_rows FROM public.pod_refills_shadow WHERE plan_date = v_pd;
    INSERT INTO public.shadow_runner_log_v3
      (run_started_at, plan_date, step, step_target, status, rows_affected, duration_ms, note)
    VALUES (v_started, v_pd, 'engine', v_pd, 'ok', v_rows,
            (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int, p_note);
    v_engine := jsonb_build_object('status','ok','shadow_rows_for_date', v_rows);
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

COMMIT;
