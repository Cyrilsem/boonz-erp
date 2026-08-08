-- PRD-110 leg 165 · D-34 (3 of 4) · S-331 #2: the pipeline learns all four refusals
--
-- THE DEFECT. run_pipeline_v3 classified the engine's exception with:
--     CASE WHEN SQLERRM LIKE '%Gate 0 not passed%' THEN 'blocked_gate0' ELSE 'error' END
-- It knows TWO of the four. 'skipped_calendar' and 'no_picks' both arise from
-- '%no picked/cs_added machines%' and are told apart only by is_refill_planning_day_v3 --
-- so both collapsed into 'error'.
--
-- That was harmless while nothing read the receipt. D-34 makes the runner read it
-- (the pipeline catches the engine's exception and NEVER re-raises, so the runner's own
-- EXCEPTION block can no longer classify anything). Without this migration, D-34 turns
-- every deliberate Saturday no-op into a logged fault and S-112 dies quietly.
--
-- ⭐ The classifier is now byte-identical to run_nightly_shadow_v3's, deliberately: two
--    functions that must agree about what a refusal is should not paraphrase each other.
--
-- ALSO FIXED IN PASSING (S-313 class, since the unit restates the body anyway):
--    'live_effect' claimed "The live cutover is parked (D-34)." The cutover is DR-1/DR-1b.
--    D-34 is this runner wiring. A stale attribution inside the very function D-34
--    rewrites is the one place it will mislead.
--
-- ⛔ Signature, volatility, security and search_path are byte-identical to the shipped
--    function. Only the engine-exception CASE and the live_effect string change.

CREATE OR REPLACE FUNCTION public.run_pipeline_v3(
  p_plan_date date,
  p_days_cover integer DEFAULT 14,
  p_base_run_id uuid DEFAULT NULL::uuid,
  p_promote_blocked boolean DEFAULT false,
  p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id   uuid;
  v_pd        date;
  v_t0        timestamptz := clock_timestamp();
  v_started   timestamptz := clock_timestamp();
  v_steps     jsonb := '[]'::jsonb;
  v_engine    jsonb;
  v_compose   jsonb;
  v_stitch    jsonb;
  v_blocked   jsonb;
  v_base_src  text;
  v_base_run  uuid;
  v_planned   uuid;
  v_stitch_rn uuid;
  v_lines_b   integer := 0;
  v_units_b   integer := 0;
  v_status    text := 'ok';
  v_id        uuid := gen_random_uuid();
  v_tag       text;
BEGIN
  PERFORM set_config('app.via_rpc',  'true',             true);
  PERFORM set_config('app.rpc_name', 'run_pipeline_v3',  true);

  -- Role gate, identical in shape to compose_plan_with_edits_v3. A NULL uid is
  -- the trusted server-side caller (cron), matching the fleet convention.
  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_user_id AND up.role IN ('operator_admin','superadmin')
  ) THEN
    RAISE EXCEPTION 'run_pipeline_v3: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_days_cover IS NULL OR p_days_cover < 1 OR p_days_cover > 60 THEN
    RAISE EXCEPTION 'run_pipeline_v3: p_days_cover must be 1..60, got %', p_days_cover;
  END IF;

  v_pd := COALESCE(p_plan_date, public.resolve_refill_plan_date());

  ------------------------------------------------------------------ STEP 1
  -- BASE. Either the engine produces it, or the caller supplies one that
  -- already exists. ⛔ A composed run may never be used as a base: composing
  -- over a composed run applies the overlay to its own output and every soft
  -- edit reads as fresh forever.
  --------------------------------------------------------------------------
  IF p_base_run_id IS NOT NULL THEN
    SELECT s.engine_tag INTO v_tag
      FROM public.pod_refills_shadow s
     WHERE s.run_id = p_base_run_id AND s.plan_date = v_pd
     LIMIT 1;
    IF v_tag IS NULL THEN
      RAISE EXCEPTION 'run_pipeline_v3: supplied base run % has no rows on plan_date %',
        p_base_run_id, v_pd;
    END IF;
    IF v_tag = 'compose_v3' THEN
      RAISE EXCEPTION 'run_pipeline_v3: run % is a composed run and may not be used as a base',
        p_base_run_id;
    END IF;
    v_base_run := p_base_run_id;
    v_base_src := 'supplied';
    v_engine   := jsonb_build_object('status','skipped','why','base run supplied by caller',
                                     'run_id', v_base_run, 'engine_tag', v_tag);
  ELSE
    v_base_src := 'engine';
    v_t0 := clock_timestamp();
    BEGIN
      v_engine   := public.engine_add_pod_v3(v_pd, p_days_cover);
      v_base_run := (v_engine->>'run_id')::uuid;
    EXCEPTION WHEN OTHERS THEN
      -- S-331 #2 / S-112. "The engine refused" is not one fact, it is four. This CASE is
      -- deliberately byte-identical to run_nightly_shadow_v3's: D-34 makes the runner
      -- classify from THIS receipt, so a coarser map here would silently re-flatten a
      -- deliberate calendar no-op into a fault.
      v_engine := jsonb_build_object(
        'status', CASE
                    WHEN SQLERRM LIKE '%Gate 0 not passed%'
                      THEN 'blocked_gate0'
                    WHEN SQLERRM LIKE '%no picked/cs_added machines%'
                     AND NOT public.is_refill_planning_day_v3(v_pd)
                      THEN 'skipped_calendar'
                    WHEN SQLERRM LIKE '%no picked/cs_added machines%'
                      THEN 'no_picks'
                    ELSE 'error'
                  END,
        'sqlstate', SQLSTATE, 'message', SQLERRM);
    END;
    v_steps := v_steps || jsonb_build_object('step','engine','status',
                 COALESCE(v_engine->>'status','ok'),
                 'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int);
  END IF;

  IF v_base_run IS NULL THEN
    v_status := 'no_base';
  ELSE
    SELECT count(*), COALESCE(SUM(qty),0) INTO v_lines_b, v_units_b
      FROM public.pod_refills_shadow WHERE run_id = v_base_run;
  END IF;

  ------------------------------------------------------------------ STEP 2
  -- COMPOSE. ⭐ ALWAYS, even on a date with no edits. One pipeline means one
  -- SHAPE: the plan CS approves is always a compose_v3 run, so "which run did
  -- stitch consume?" never has two possible answers. The cost is one extra
  -- shadow run per night; the benefit is that the question stops being asked.
  --------------------------------------------------------------------------
  IF v_status = 'ok' THEN
    v_t0 := clock_timestamp();
    BEGIN
      v_compose := public.compose_plan_with_edits_v3(v_pd, v_base_run);
      IF COALESCE(v_compose->>'status','') <> 'ok' THEN
        v_status := 'error';
      ELSE
        v_planned := (v_compose->>'run_id')::uuid;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_compose := jsonb_build_object('status','error','sqlstate',SQLSTATE,'message',SQLERRM);
      v_status  := 'error';
    END;
    v_steps := v_steps || jsonb_build_object('step','compose','status',
                 COALESCE(v_compose->>'status','error'),
                 'run_id', v_compose->>'run_id',
                 'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int);

    -- ⛔ A composed plan with no lines is NOT an invitation to fall back to the
    --    base. Falling back would resurrect every dropped line -- exactly the
    --    silent revert P3.6 exists to prevent. Stop, and say so.
    IF v_status = 'ok' AND COALESCE((v_compose->>'lines_out')::int, 0) = 0 THEN
      v_status := 'composed_empty';
    END IF;
  END IF;

  ------------------------------------------------------------------ STEP 3
  -- STITCH, over the PLANNED run, passed explicitly. This is the pin.
  --------------------------------------------------------------------------
  IF v_status = 'ok' THEN
    v_t0 := clock_timestamp();
    BEGIN
      v_stitch := public.stitch_v3(v_pd, v_planned);
      IF COALESCE(v_stitch->>'status','') <> 'ok' THEN
        v_status := 'error';
      ELSE
        v_stitch_rn := (v_stitch->>'run_id')::uuid;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_stitch := jsonb_build_object('status','error','sqlstate',SQLSTATE,'message',SQLERRM);
      v_status := 'error';
    END;
    v_steps := v_steps || jsonb_build_object('step','stitch','status',
                 COALESCE(v_stitch->>'status','error'),
                 'run_id', v_stitch->>'run_id',
                 'source_run_id', v_stitch->>'source_run_id',
                 'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int);

    -- ⛔ Belt and braces on the pin: if stitch ever reports a source other than
    --    the run we handed it, the pipeline is lying about what it planned.
    IF v_status = 'ok'
       AND (v_stitch->>'source_run_id')::uuid IS DISTINCT FROM v_planned THEN
      RAISE EXCEPTION 'run_pipeline_v3: stitch consumed % but the pipeline planned %',
        v_stitch->>'source_run_id', v_planned;
    END IF;
  END IF;

  ------------------------------------------------------------------ STEP 4
  -- BLOCKED-DEMAND PROMOTION. ⛔ OFF by default: D-29 parks auto-promotion as
  -- a CS flag. The step exists so that flipping it is one boolean, not a build.
  --------------------------------------------------------------------------
  IF v_status = 'ok' AND p_promote_blocked THEN
    v_t0 := clock_timestamp();
    BEGIN
      v_blocked := public.record_blocked_demand_v3(v_pd, 'stitch');
    EXCEPTION WHEN OTHERS THEN
      v_blocked := jsonb_build_object('status','error','sqlstate',SQLSTATE,'message',SQLERRM);
    END;
    v_steps := v_steps || jsonb_build_object('step','blocked_demand','status',
                 COALESCE(v_blocked->>'status','ok'),
                 'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int);
  ELSE
    v_blocked := jsonb_build_object('status','skipped',
      'why','auto-promotion into blocked_demand is parked as CS decision D-29; pass p_promote_blocked => true to run it');
    v_steps := v_steps || jsonb_build_object('step','blocked_demand','status','skipped');
  END IF;

  ------------------------------------------------------------------ RECEIPT
  INSERT INTO public.pipeline_runs_v3
    (pipeline_run_id, plan_date, days_cover, base_source, base_run_id,
     composed_run_id, planned_run_id, stitch_run_id,
     edits_considered, edits_applied, edits_yielded,
     lines_base, units_base, lines_planned, units_planned,
     rows_stitched, units_placed, units_blocked, blocked_rows,
     status, steps, note, started_at, finished_at, duration_ms, created_by)
  VALUES
    (v_id, v_pd, p_days_cover, v_base_src, v_base_run,
     (v_compose->>'run_id')::uuid, v_planned, v_stitch_rn,
     COALESCE((v_compose->>'edits_considered')::int, 0),
     COALESCE((v_compose->>'edits_applied')::int, 0),
     COALESCE((v_compose->>'edits_yielded')::int, 0),
     v_lines_b, v_units_b,
     COALESCE((v_compose->>'lines_out')::int, 0),
     COALESCE((v_compose->>'units_out')::int, 0),
     COALESCE((v_stitch->>'rows_out')::int, 0),
     COALESCE((v_stitch->>'units_placed')::int, 0),
     COALESCE((v_stitch->>'units_blocked')::int, 0),
     COALESCE((v_stitch->>'blocked_rows')::int, 0),
     v_status, v_steps, p_note, v_started, clock_timestamp(),
     (EXTRACT(EPOCH FROM (clock_timestamp() - v_started)) * 1000)::int, v_user_id);

  RETURN jsonb_build_object(
    'status',          v_status,
    'pipeline_run_id', v_id,
    'plan_date',       v_pd,
    'days_cover',      p_days_cover,
    'base_source',     v_base_src,
    'base_run_id',     v_base_run,
    'planned_run_id',  v_planned,
    'engine',          v_engine,
    'compose',         v_compose,
    'stitch',          v_stitch,
    'blocked',         v_blocked,
    'steps',           v_steps,
    'approval',        'a pipeline run is born UNAPPROVED; approve_pipeline_run_v3 is the single approve verb',
    -- S-313 class: the cutover is DR-1/DR-1b (engine_cutover_authority_v3, 0 of 10
    -- clusters authoritative). D-34 is the nightly-runner wiring, not the cutover.
    'live_effect',     'none: LAW 4, shadow tables only. The per-cluster live cutover is parked as DR-1/DR-1b.',
    'duration_ms',     (EXTRACT(EPOCH FROM (clock_timestamp() - v_started)) * 1000)::int);
END
$function$;
