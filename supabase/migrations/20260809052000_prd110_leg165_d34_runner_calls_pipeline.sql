-- PRD-110 leg 165 · D-34 (4 of 4) · the nightly runner runs the ONE PIPELINE
--
-- CS RULING (D-34): "YES: nightly shadow runner -> run_pipeline_v3 with
-- p_promote_blocked => true (per D-29 scoping), after S-112 is fixed."
--
-- S-331 proved the naive one-line swap destroys S-112 and S-304a in one edit. All four
-- traps are handled here:
--
--  1. ⛔ THE PIPELINE SWALLOWS THE ENGINE'S EXCEPTION and never re-raises. This
--        function's EXCEPTION block would therefore never fire again for a refusal, and
--        every blocked_gate0 night would return normally and log as a success. The
--        runner now classifies from the RECEIPT. The EXCEPTION block is KEPT, because
--        the pipeline still has genuine throws of its own (the planned-vs-consumed
--        mismatch RAISE, the role gate, input validation) -- it just no longer carries
--        the four-way distinction alone.
--  2. ⛔ THE PIPELINE'S CLASSIFIER WAS COARSER (two of four). Fixed in its own migration
--        (20260809051500), byte-identical CASE, so the receipt this function reads is
--        trustworthy.
--  3. ⛔ THE S-304a SENSOR: lines_written is NESTED at res->'engine'->>'lines_written'.
--        Read from the top level it is NULL -> 0 -> every night logs ok_no_shadow_rows,
--        exactly the blindness leg 159 shipped a migration to remove.
--  4. ⛔ THE PIPELINE HAS FAILURE MODES THIS RUNNER HAS NEVER SEEN: no_base,
--        composed_empty, compose/stitch errors, and a failed D-29 promotion. Each gets
--        its own word (migration 20260809050500) and each is classified in
--        v_shadow_runner_health_v3 (migration 20260809051000, S-332) -- otherwise they
--        arrive as 'error', or worse, read as healthy.
--
-- ⭐ p_promote_blocked => true is safe: D-29 scoped record_blocked_demand_v3 by cluster
--    authority, so promotion touches only flipped clusters. At 0 of 10 authoritative it
--    is inert -- which is the flag-off proof, not a reason to skip the wiring.
--
-- ⛔ LAW 4 UNAFFECTED: the pipeline writes pod_refills_shadow and pipeline_runs_v3 only.
-- ⛔ Signature, volatility, security, search_path byte-identical to the shipped function.

CREATE OR REPLACE FUNCTION public.run_nightly_shadow_v3(
  p_plan_date date DEFAULT NULL::date,
  p_days_cover integer DEFAULT 7,
  p_settle_limit integer DEFAULT 3,
  p_note text DEFAULT NULL::text)
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
  v_pipe    jsonb;
  v_eng_st  text;
  v_pipe_st text;
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

  ------------------------------------------------------- STEP 1: the pipeline
  -- D-34. Was engine_add_pod_v3 alone; now the whole pipeline
  -- (engine -> compose -> stitch -> blocked-demand promotion) as ONE receipted unit,
  -- so the nightly shadow measures the same shape CS will eventually approve.
  -- The log step stays named 'engine' -- the step CHECK pins the vocabulary and the
  -- engine is still what this step is about.
  v_t0 := clock_timestamp();
  BEGIN
    SELECT public.run_pipeline_v3(v_pd, p_days_cover, NULL, true, p_note) INTO v_pipe;

    -- ⛔⛔ D-36's RULING, APPLIED HERE. run_pipeline_v3 does
    --     set_config('app.rpc_name','run_pipeline_v3', true) -- and the third argument is
    --     TRANSACTION-local, not call-local. Without this re-assert the name stays
    --     'run_pipeline_v3' for the rest of THIS function, so every measure/settle/summary
    --     write below is attributed to the wrong RPC in write_audit_log (Article 8).
    --     CS ruled exactly this for swap_v3: "RE-ASSERT app.rpc_name after each inner call."
    PERFORM set_config('app.rpc_name','run_nightly_shadow_v3',true);

    v_eng_res := v_pipe->'engine';
    v_eng_st  := COALESCE(v_eng_res->>'status', 'error');
    v_pipe_st := COALESCE(v_pipe->>'status',    'error');

    -- S-331 #3 / S-304a. The engine's OWN return value is the sensor, and it is NESTED.
    -- lines_written is what THIS run banked; a count of the date's whole shadow history
    -- would report a previous run's work as this run's.
    v_rows := COALESCE((v_eng_res->>'lines_written')::int, 0);
    SELECT count(*) INTO v_date_rows FROM public.pod_refills_shadow WHERE plan_date = v_pd;

    v_status := CASE
      -- ⭐ The engine's own refusal always wins: it is the most specific fact on the
      --    receipt. S-112's four-way distinction survives the swap because it is READ,
      --    not caught. (On a refusal the pipeline's top level says only 'no_base'.)
      WHEN v_eng_st IN ('blocked_gate0','skipped_calendar','no_picks')
        THEN v_eng_st
      -- the engine returned nothing classifiable and the pipeline had no base to work on
      WHEN v_pipe_st = 'no_base'        THEN 'no_base'
      -- a composed plan with zero lines: a deliberate refusal to resurrect dropped lines
      WHEN v_pipe_st = 'composed_empty' THEN 'composed_empty'
      WHEN v_pipe_st = 'error' AND COALESCE(v_pipe->'compose'->>'status','ok') <> 'ok'
        THEN 'compose_error'
      WHEN v_pipe_st = 'error' AND COALESCE(v_pipe->'stitch'->>'status','ok') <> 'ok'
        THEN 'stitch_error'
      WHEN v_pipe_st <> 'ok'            THEN 'error'
      -- the plan is fine but the D-29 promotion failed: named, not buried
      WHEN COALESCE(v_pipe->'blocked'->>'status','skipped') = 'error'
        THEN 'blocked_demand_error'
      -- S-304a: a night that banked NOTHING must not wear the same word as a night
      -- that banked 112.
      WHEN v_rows > 0                   THEN 'ok'
      ELSE 'ok_no_shadow_rows'
    END;

    INSERT INTO public.shadow_runner_log_v3
      (run_started_at, plan_date, step, step_target, status, rows_affected, duration_ms,
       detail, message, note)
    VALUES (v_started, v_pd, 'engine', v_pd, v_status, v_rows,
            (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int,
            jsonb_build_object(
              'lines_written',            v_rows,
              'shadow_rows_for_date',     v_date_rows,
              'machines_in_scope',        v_eng_res->'machines_in_scope',
              'machines_without_shelves', v_eng_res->'machines_without_shelves',
              'shelves_in_scope',         v_eng_res->'shelves_in_scope',
              'run_id',                   v_eng_res->'run_id',
              -- D-34 provenance: which pipeline run this night is, and what it planned.
              'pipeline_run_id',          v_pipe->'pipeline_run_id',
              'pipeline_status',          v_pipe_st,
              'engine_status',            v_eng_st,
              'planned_run_id',           v_pipe->'planned_run_id',
              'compose_status',           v_pipe->'compose'->>'status',
              'stitch_status',            v_pipe->'stitch'->>'status',
              'blocked_status',           v_pipe->'blocked'->>'status'),
            -- TRUTHFULNESS: reclassifying must not erase the engine's own words.
            v_eng_res->>'message',
            p_note);

    v_engine := jsonb_build_object('status', v_status,
                                   'lines_written',        v_rows,
                                   'shadow_rows_for_date', v_date_rows,
                                   'pipeline_run_id',      v_pipe->'pipeline_run_id',
                                   'pipeline_status',      v_pipe_st,
                                   'engine_status',        v_eng_st);
  EXCEPTION WHEN OTHERS THEN
    -- ⛔ Reached only by a GENUINE throw now: the pipeline's planned-vs-consumed mismatch
    --    RAISE, its role gate, or its input validation. The engine's refusals no longer
    --    arrive here -- they arrive on the receipt above. The four-way CASE is retained
    --    because the pipeline may still be bypassed or fail before it can build one.
    v_status := CASE
                  WHEN SQLERRM LIKE '%Gate 0 not passed%'
                    THEN 'blocked_gate0'
                  WHEN SQLERRM LIKE '%no picked/cs_added machines%'
                   AND NOT public.is_refill_planning_day_v3(v_pd)
                    THEN 'skipped_calendar'
                  WHEN SQLERRM LIKE '%no picked/cs_added machines%'
                    THEN 'no_picks'
                  WHEN SQLERRM LIKE '%stitch consumed%'
                    THEN 'stitch_error'
                  -- ⛔ CODY (Article 4). The two role gates DISAGREE and D-34 makes the
                  --    stricter one win. This runner admits operator_admin, superadmin,
                  --    manager and warehouse; run_pipeline_v3 admits only the first two,
                  --    and SECURITY DEFINER does not reset auth.uid(). So a manager or
                  --    warehouse caller who can run this function today is refused by the
                  --    pipeline. Verified live as warehouse bf32624e.
                  --    ⭐ NOT fixed by widening the pipeline's gate -- that is an
                  --      authorization expansion and belongs to CS (see the parking lot).
                  --      Fail-closed is the safe direction; what is NOT safe is the reason
                  --      arriving as a generic 'error'. So it gets its own word.
                  --    ⛔ Cron is unaffected: it passes a NULL uid and skips both gates.
                  WHEN SQLERRM LIKE '%lacks operator_admin role%'
                    THEN 'role_refused'
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
  -- S-112 / S-304a: a deliberate skip, a blank night, and each of D-34's pipeline
  -- failure modes all propagate their OWN name to the summary instead of being
  -- flattened into 'error' by the ELSE. v_shadow_runner_health_v3 judges the SUMMARY
  -- row (S-113), so a word that dies here is a word health can never see.
  v_status := CASE
                WHEN v_engine->>'status' IN ('ok','ok_no_shadow_rows')
                 AND v_measure->>'status' IN ('ok','skipped')
                  THEN v_engine->>'status'
                WHEN v_engine->>'status' IN ('blocked_gate0','skipped_calendar','no_picks',
                                             'no_base','composed_empty','compose_error',
                                             'stitch_error','blocked_demand_error',
                                             'role_refused')
                  THEN v_engine->>'status'
                ELSE 'error'
              END;

  INSERT INTO public.shadow_runner_log_v3
    (run_started_at, plan_date, step, step_target, status, duration_ms, detail, note)
  VALUES (v_started, v_pd, 'summary', v_pd, v_status,
          (extract(epoch FROM clock_timestamp() - v_started) * 1000)::int,
          jsonb_build_object('engine', v_engine, 'measure', v_measure, 'settle', v_settled,
                             'pipeline_run_id', v_pipe->'pipeline_run_id'),
          p_note);

  RETURN jsonb_build_object(
    'plan_date',   v_pd,
    'status',      v_status,
    'engine',      v_engine,
    'measure',     v_measure,
    'settled',     v_settled,
    'pipeline',    jsonb_build_object(
                     'pipeline_run_id', v_pipe->'pipeline_run_id',
                     'status',          v_pipe->>'status',
                     'planned_run_id',  v_pipe->'planned_run_id',
                     'promote_blocked', true),
    'days_cover',  p_days_cover,
    'ran_at',      v_started);
END $function$;
