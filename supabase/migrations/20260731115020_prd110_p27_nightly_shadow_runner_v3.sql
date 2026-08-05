-- PRD-110 P2.7 — nightly shadow runner for engine_add_pod_v3 + WMAPE settle-up.
-- Proven by golden fixture 37 (applied and run RED first, LAW 1).
--
-- WHY THIS EXISTS: v3 has never run on a real plan_date, so v_engine_wmape_v3_gate
-- reads vacuous_reason='no_v3_measurement' forever and the Phase-2 gate can never be
-- scored. This schedules v3 into SHADOW on real dates and settles the actuals.
--
-- LAW 12 is structurally inapplicable to the engine (leg 52, re-verified): every DML
-- target across engine_add_pod_v3's 30,534-char body is public.pod_refills_shadow, and
-- its only volatile public callee (_assert_gate_zero) writes nothing.
--
-- LAW 11: on a normal night cron 13 picks and CS has not yet confirmed, so
-- _assert_gate_zero RAISES check_violation. That is the EXPECTED pre-confirm state, not
-- a fault. It is classified 'blocked_gate0' — distinct from 'error' — so that a real
-- failure is never buried in a stream of normal nights. The runner NEVER auto-confirms:
-- that would be exactly the auto-fallback CS decision #1 forbids.

-- ---------------------------------------------------------------------------
-- 1. Run log. A failed OR missing night must be visible.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.shadow_runner_log_v3 (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_started_at timestamptz NOT NULL DEFAULT now(),
  plan_date      date,
  step           text        NOT NULL CHECK (step IN ('engine','measure','settle','summary')),
  step_target    date,
  status         text        NOT NULL CHECK (status IN ('ok','error','blocked_gate0','skipped')),
  rows_affected  integer,
  duration_ms    integer,
  sqlstate       text,
  message        text,
  detail         jsonb       NOT NULL DEFAULT '{}'::jsonb,
  note           text,
  created_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.shadow_runner_log_v3 IS
  'PRD-110 P2.7. One row per step per nightly shadow run. status blocked_gate0 = Gate 0 '
  'not yet confirmed by CS (the normal pre-confirm state under LAW 11), NOT a failure. '
  'Append-only on rewrite: a recorded night may never be edited. Proven by fixture 37.';

CREATE INDEX IF NOT EXISTS idx_srl_v3_started  ON public.shadow_runner_log_v3 (run_started_at DESC);
CREATE INDEX IF NOT EXISTS idx_srl_v3_plandate ON public.shadow_runner_log_v3 (plan_date, step);

-- Article 7: a recorded night may not be rewritten. DELETE stays available for
-- retention pruning (and is exercised only inside fixture 37's forced-rollback probe).
CREATE OR REPLACE FUNCTION public.tg_shadow_runner_log_no_update()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  RAISE EXCEPTION 'shadow_runner_log_v3 is append-only: a recorded night may not be rewritten'
    USING ERRCODE = 'check_violation';
END $fn$;

DROP TRIGGER IF EXISTS tg_srl_v3_no_update ON public.shadow_runner_log_v3;
CREATE TRIGGER tg_srl_v3_no_update
  BEFORE UPDATE ON public.shadow_runner_log_v3
  FOR EACH ROW EXECUTE FUNCTION public.tg_shadow_runner_log_no_update();

ALTER TABLE public.shadow_runner_log_v3 ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS srl_v3_select ON public.shadow_runner_log_v3;
CREATE POLICY srl_v3_select ON public.shadow_runner_log_v3
  FOR SELECT TO authenticated USING (true);

-- Article 7 at the policy layer too, mirroring pod_refills_shadow_no_update.
DROP POLICY IF EXISTS srl_v3_no_update ON public.shadow_runner_log_v3;
CREATE POLICY srl_v3_no_update ON public.shadow_runner_log_v3
  FOR UPDATE TO authenticated USING (false);

-- Article 8: the generic audit trigger, mirroring tg_audit_blocked_demand.
DROP TRIGGER IF EXISTS tg_audit_shadow_runner_log_v3 ON public.shadow_runner_log_v3;
CREATE TRIGGER tg_audit_shadow_runner_log_v3
  AFTER INSERT OR UPDATE OR DELETE ON public.shadow_runner_log_v3
  FOR EACH ROW EXECUTE FUNCTION audit_log_write('id');

-- ⛔ Deliberately SELECT-only for authenticated, matching pod_refills_shadow — NOT the
-- looser grant set engine_forecast_error_v3 carries (see leg 53 finding S-57).
REVOKE ALL ON public.shadow_runner_log_v3 FROM PUBLIC;
REVOKE ALL ON public.shadow_runner_log_v3 FROM anon;
GRANT SELECT ON public.shadow_runner_log_v3 TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. The runner.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.run_nightly_shadow_v3(
  p_plan_date    date    DEFAULT NULL,
  p_days_cover   integer DEFAULT 7,
  p_settle_limit integer DEFAULT 3,
  p_note         text    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $fn$
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
    v_status := CASE WHEN SQLERRM LIKE '%Gate 0 not passed%'
                     THEN 'blocked_gate0' ELSE 'error' END;
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
  -- loop it over all dates — p_settle_limit bounds each night to a handful.
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
  v_status := CASE
                WHEN v_engine->>'status' = 'ok' AND v_measure->>'status' IN ('ok','skipped')
                  THEN 'ok'
                WHEN v_engine->>'status' = 'blocked_gate0' THEN 'blocked_gate0'
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
END $fn$;

COMMENT ON FUNCTION public.run_nightly_shadow_v3(date,integer,integer,text) IS
  'PRD-110 P2.7. Nightly: engine_add_pod_v3 into pod_refills_shadow on a REAL plan_date, '
  'then refresh_engine_forecast_error_v3, then settle up to p_settle_limit elapsed dates. '
  'Every step logs to shadow_runner_log_v3 including its failures. Writes NO live plan '
  'table. Never auto-confirms Gate 0 (LAW 11). Proven by golden fixture 37.';

REVOKE ALL ON FUNCTION public.run_nightly_shadow_v3(date,integer,integer,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.run_nightly_shadow_v3(date,integer,integer,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.run_nightly_shadow_v3(date,integer,integer,text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Health. A DEAD SCHEDULE writes nothing at all, so the detector must fire on
--    the ABSENCE of rows (the PRD-109 INV-10 lesson: the absence IS the signal).
--    RISK 103: is_healthy is explicitly FALSE (never NULL) when the log is empty.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_shadow_runner_health_v3
WITH (security_invoker = true) AS
WITH a AS (
  SELECT count(*) AS log_rows, max(run_started_at) AS last_run_at
    FROM public.shadow_runner_log_v3
), o AS (
  SELECT max(run_started_at) AS last_ok_at
    FROM public.shadow_runner_log_v3 WHERE step = 'summary' AND status = 'ok'
), g AS (
  SELECT count(*) AS gate0_nights
    FROM public.shadow_runner_log_v3
   WHERE step = 'summary' AND status = 'blocked_gate0'
     AND run_started_at >= now() - interval '14 days'
), m AS (
  SELECT count(DISTINCT plan_date) AS v3_measured_real_dates
    FROM public.engine_forecast_error_v3
   WHERE engine_tag = 'v3' AND plan_date < DATE '2029-01-01'
)
SELECT
  a.log_rows,
  a.last_run_at,
  o.last_ok_at,
  g.gate0_nights,
  m.v3_measured_real_dates,
  round((extract(epoch FROM now() - a.last_run_at) / 3600.0)::numeric, 2) AS hours_since_last_run,
  -- Is the SCHEDULE alive? Empty log => FALSE, not NULL (false AND NULL = false).
  (a.log_rows > 0 AND a.last_run_at >= now() - interval '30 hours')      AS is_healthy,
  -- Is it actually PRODUCING measurements? A long gate0 streak is alive but sterile.
  (o.last_ok_at IS NOT NULL AND o.last_ok_at >= now() - interval '30 hours') AS is_measuring,
  CASE
    WHEN a.log_rows = 0                                    THEN 'no_runs_ever__schedule_may_be_dead'
    WHEN a.last_run_at < now() - interval '30 hours'        THEN 'stale__no_run_in_30h'
    WHEN o.last_ok_at IS NULL                               THEN 'running_but_never_succeeded'
    WHEN o.last_ok_at < now() - interval '30 hours'          THEN 'running_but_not_measuring__check_gate0'
    ELSE 'ok'
  END AS verdict
FROM a CROSS JOIN o CROSS JOIN g CROSS JOIN m;

COMMENT ON VIEW public.v_shadow_runner_health_v3 IS
  'PRD-110 P2.7. is_healthy answers "is the schedule alive" (fires on ABSENCE of rows); '
  'is_measuring answers "is it producing v3 measurements" — a long blocked_gate0 streak '
  'is alive but sterile and must not read as healthy-and-fine. Fixture 37 seq 17/18.';

REVOKE ALL ON public.v_shadow_runner_health_v3 FROM PUBLIC;
REVOKE ALL ON public.v_shadow_runner_health_v3 FROM anon;
GRANT SELECT ON public.v_shadow_runner_health_v3 TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. The schedule. Article 11: cron calls an RPC, never raw DML.
--
-- SLOT = 21:22 UTC = 01:22 Asia/Dubai (next calendar day), chosen so that:
--   * resolve_refill_plan_date() at 01:22 Dubai is < 18:00 => returns Dubai TODAY,
--     which is exactly the plan_date cron 13 targeted at 16:00 UTC (20:00 Dubai,
--     >= 18:00 => tomorrow). Both land on the SAME date. Verified, not assumed.
--   * it is ~5h after cron 13's pick, giving CS time to confirm Gate 0, so most
--     nights clear the gate instead of logging blocked_gate0.
--   * it is after cron 2 (19:59), cron 31 (20:30) and cron 5 (21:00), so fleet and
--     shelf state have settled.
--   * minute 22 collides with NO active cron: the hourly jobs sit at :00 (12, 20),
--     :15 (35), :40 (44), :50 (34) and */5 (36); hour 21 holds only cron 5 at :00.
--     Fixture 37 seq 22/23 pin both the existence and the non-collision.
-- ---------------------------------------------------------------------------
DO $c$
BEGIN
  PERFORM cron.unschedule('prd110_p27_nightly_shadow_runner_v3');
EXCEPTION WHEN OTHERS THEN
  NULL;  -- not previously scheduled
END $c$;

SELECT cron.schedule(
  'prd110_p27_nightly_shadow_runner_v3',
  '22 21 * * *',
  $cron$SET statement_timeout='1200000'; SELECT public.run_nightly_shadow_v3();$cron$
);
