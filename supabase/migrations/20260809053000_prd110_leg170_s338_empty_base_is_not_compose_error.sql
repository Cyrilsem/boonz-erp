-- PRD-110 leg 170 · S-338 · a BLANK night is not a compose_error
--
-- Found by fixture 37 seq 37/38 going 43/0 -> 41/2 RED the moment D-34 landed. The
-- assertion was NOT loosened (S-322): it still demands 'ok_no_shadow_rows' and the
-- code was moved to meet it.
--
-- ⛔ THE DEFECT. run_pipeline_v3 hands the engine's run_id to
--    compose_plan_with_edits_v3 as p_source_run_id. That function looks the run up in
--    pod_refills_shadow and RAISEs if it finds no rows. On a healthy blank night --
--    LVLUP-2015-0000-R0 is Active and carries no pod-bearing shelf, so the engine runs
--    clean and writes nothing -- the run_id is non-NULL but has zero rows, so compose
--    RAISEs, the pipeline catches it as status 'error' with compose non-ok, and the
--    D-34 runner classifies the night 'compose_error'.
--
-- ⛔ WHY IT MATTERS BEYOND THE FIXTURE. 'compose_error' propagates to the summary row,
--    and v_shadow_runner_health_v3 judges the summary (S-113) -- so a fleet night where
--    the engine correctly had nothing to do would read as UNHEALTHY. It is S-304a's
--    blindness inverted: leg 159 stopped a blank night wearing a healthy night's word;
--    D-34 made a blank night wear a broken night's word.
--
-- ⭐ THE FIX is to skip compose and stitch when the base is empty and stay 'ok', so the
--    runner's own S-304a branch (lines_written = 0 -> 'ok_no_shadow_rows') names it.
--    The signal was already computed and sitting unused: v_lines_b.
--
-- ⛔ 'composed_empty' is NOT this case and is left exactly as it was: it means a base
--    that HAD lines and composed down to none (P3.6 refusing to resurrect dropped
--    lines). Conflating the two would hide a real revert behind a blank night.
--
-- ⛔ Blocked-demand promotion is skipped too: with no planned run there is nothing to
--    promote, and pre-D-34 a blank night promoted nothing at all. Conservative.
-- ⛔ Signature, volatility, security and search_path byte-identical to the shipped
--    function. LAW 4 unaffected: shadow tables only.

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
  v_empty_base boolean := false;
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

    -- ⛔⛔ S-338. THE BASE EXISTS BUT IS EMPTY, AND THAT IS A HEALTHY NIGHT.
    --    The engine opens a run_id before it knows whether it will write anything, so
    --    a machine with no pod-bearing shelf yields a NON-NULL run with ZERO rows --
    --    the exact 2026-08-07 shape S-304a was built to name. 'no_base' above cannot
    --    see it (the run_id is not null), and compose_plan_with_edits_v3 RAISES on it
    --    ('source run % has no rows on plan_date %') because that guard exists to catch
    --    a caller passing a WRONG run_id and cannot tell that from a legitimately empty
    --    one. Caught, the raise became 'compose_error': a clean night reported as a
    --    fault, and routed through v_shadow_runner_health_v3 as unhealthy.
    -- ⭐ There is nothing to compose and nothing to stitch. Skip both, stay 'ok', and
    --    let the RUNNER's own S-304a branch (lines_written = 0 -> 'ok_no_shadow_rows')
    --    do the naming it was built for. ⛔ NOT the same as 'composed_empty', which
    --    means a base that HAD lines and composed down to none (P3.6's deliberate
    --    refusal to resurrect dropped lines). Both keep their distinct meanings.
    IF v_lines_b = 0 THEN
      v_empty_base := true;
    END IF;
  END IF;

  ------------------------------------------------------------------ STEP 2
  -- COMPOSE. ⭐ ALWAYS, even on a date with no edits. One pipeline means one
  -- SHAPE: the plan CS approves is always a compose_v3 run, so "which run did
  -- stitch consume?" never has two possible answers. The cost is one extra
  -- shadow run per night; the benefit is that the question stops being asked.
  --------------------------------------------------------------------------
  IF v_status = 'ok' AND NOT v_empty_base THEN
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

  -- S-338. An empty base skips compose and stitch: name it on the receipt rather
  -- than leaving two silent holes in v_steps.
  IF v_empty_base THEN
    v_compose := jsonb_build_object('status','skipped',
      'why','base run is empty (engine banked zero lines); nothing to compose');
    v_stitch  := jsonb_build_object('status','skipped',
      'why','base run is empty (engine banked zero lines); nothing to stitch');
    v_steps := v_steps
      || jsonb_build_object('step','compose','status','skipped')
      || jsonb_build_object('step','stitch', 'status','skipped');
  END IF;

  ------------------------------------------------------------------ STEP 3
  -- STITCH, over the PLANNED run, passed explicitly. This is the pin.
  --------------------------------------------------------------------------
  IF v_status = 'ok' AND NOT v_empty_base THEN
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
  IF v_status = 'ok' AND NOT v_empty_base AND p_promote_blocked THEN
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
