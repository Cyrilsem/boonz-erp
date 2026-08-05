-- =====================================================================
-- PRD-110 P3.7 — ONE PIPELINE (WS-E3), part 2: the runner and the approver
-- =====================================================================
-- ⛔ THE PIN. Every stage receives its input run id EXPLICITLY. stitch_v3 is
--    NEVER called with a NULL source from here, because a NULL source resolves
--    by (produced_at DESC, run_id DESC) and pod_refills_shadow.produced_at
--    DEFAULTs to now() -- the TRANSACTION timestamp. Base and composed runs
--    written by one pipeline therefore TIE, and the tie-break is uuid ordering.
--    Golden fixture 51 forces that coin flip to its wrong face (a base run whose
--    run_id sorts above every random v4 uuid) and proves the pipeline is
--    unaffected.
--
-- ⛔ LAW 4: shadow only. No live plan table is read or written, and an approval
--    recorded here has no live effect -- the cutover is a parked CS flag (D-34).
-- ⛔ D-29: promoting stitch's stranded units into blocked_demand stays OFF by
--    default. The step is built and named; the parameter is the CS flag.
-- ⛔ LAW 3: additive only. No pre-existing engine object is modified.

CREATE OR REPLACE FUNCTION public.run_pipeline_v3(
  p_plan_date       date,
  p_days_cover      integer DEFAULT 14,
  p_base_run_id     uuid    DEFAULT NULL,
  p_promote_blocked boolean DEFAULT false,
  p_note            text    DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
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
      v_engine := jsonb_build_object('status', CASE WHEN SQLERRM LIKE '%Gate 0 not passed%'
                                                    THEN 'blocked_gate0' ELSE 'error' END,
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
    'live_effect',     'none: LAW 4, shadow tables only. The live cutover is parked (D-34).',
    'duration_ms',     (EXTRACT(EPOCH FROM (clock_timestamp() - v_started)) * 1000)::int);
END
$fn$;

COMMENT ON FUNCTION public.run_pipeline_v3(date,integer,uuid,boolean,text) IS
  'PRD-110 P3.7 (WS-E3). One pipeline: engine -> compose -> stitch as a single receipted unit. Every stage receives its input run id EXPLICITLY, so the plan that gets stitched is never decided by the (produced_at, run_id) tie a same-transaction pipeline creates. Writes shadow tables only.';

-- ---------------------------------------------------------------------
-- THE SINGLE APPROVE VERB.
-- ⛔ At most ONE approval stands per plan_date. Approving a different run for a
--    date that already has one RETIRES the incumbent by name -- a late edit
--    must stay approvable, but two approved plans for one night must not exist.
-- ⛔ S-105 order lesson: retire the incumbent FIRST. The partial unique index
--    ux_pipeline_runs_v3_standing_approval permits exactly one standing row,
--    so claiming before retiring raises a duplicate-key error every time.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_pipeline_run_v3(
  p_pipeline_run_id uuid,
  p_reason          text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_user_id uuid;
  v_pd      date;
  v_status  text;
  v_appr    timestamptz;
  v_prior   uuid;
  v_standing integer;
BEGIN
  PERFORM set_config('app.via_rpc',  'true',                      true);
  PERFORM set_config('app.rpc_name', 'approve_pipeline_run_v3',   true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_user_id AND up.role IN ('operator_admin','superadmin')
  ) THEN
    RAISE EXCEPTION 'approve_pipeline_run_v3: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_pipeline_run_id IS NULL THEN
    RAISE EXCEPTION 'approve_pipeline_run_v3: p_pipeline_run_id is required';
  END IF;
  IF p_reason IS NULL OR char_length(btrim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'approve_pipeline_run_v3: a reason of at least 10 characters is required';
  END IF;

  SELECT p.plan_date, p.status, p.approved_at
    INTO v_pd, v_status, v_appr
    FROM public.pipeline_runs_v3 p
   WHERE p.pipeline_run_id = p_pipeline_run_id
   FOR UPDATE;

  IF v_pd IS NULL THEN
    RAISE EXCEPTION 'approve_pipeline_run_v3: no pipeline run %', p_pipeline_run_id;
  END IF;
  IF v_status <> 'ok' THEN
    RAISE EXCEPTION 'approve_pipeline_run_v3: pipeline run % has status %, only an ok run may be approved',
      p_pipeline_run_id, v_status;
  END IF;
  IF v_appr IS NOT NULL THEN
    RAISE EXCEPTION 'approve_pipeline_run_v3: pipeline run % has already carried an approval',
      p_pipeline_run_id;
  END IF;

  -- Retire the incumbent FIRST (S-105), and name it in the return value.
  SELECT p.pipeline_run_id INTO v_prior
    FROM public.pipeline_runs_v3 p
   WHERE p.plan_date = v_pd
     AND p.approved_at IS NOT NULL
     AND p.approval_superseded_at IS NULL
   FOR UPDATE;

  IF v_prior IS NOT NULL THEN
    UPDATE public.pipeline_runs_v3
       SET approval_superseded_at = now(),
           approval_superseded_by = p_pipeline_run_id
     WHERE pipeline_run_id = v_prior;
  END IF;

  UPDATE public.pipeline_runs_v3
     SET approved_at    = now(),
         approved_by    = v_user_id,
         approve_reason = btrim(p_reason)
   WHERE pipeline_run_id = p_pipeline_run_id;

  SELECT count(*) INTO v_standing
    FROM public.pipeline_runs_v3
   WHERE plan_date = v_pd AND approved_at IS NOT NULL AND approval_superseded_at IS NULL;

  -- ⛔ The index already forbids two; this makes a zero loud too.
  IF v_standing <> 1 THEN
    RAISE EXCEPTION 'approve_pipeline_run_v3: % standing approvals for % after approving - expected exactly 1',
      v_standing, v_pd;
  END IF;

  RETURN jsonb_build_object(
    'status',                    'ok',
    'pipeline_run_id',           p_pipeline_run_id,
    'plan_date',                 v_pd,
    'approved_by',               v_user_id,
    'superseded_approval_of',    v_prior,
    'standing_approvals_on_date', v_standing,
    'live_effect', 'none: LAW 4. This marks the shadow plan CS stands behind; the live cutover is a parked flag (D-34).');
END
$fn$;

COMMENT ON FUNCTION public.approve_pipeline_run_v3(uuid,text) IS
  'PRD-110 P3.7 (WS-E3). The single approve verb. Marks one pipeline run as the plan CS stands behind for its plan_date, retiring any incumbent approval by name. Writes nothing live: the cutover is a parked CS flag (D-34).';

-- ⛔ S-104: the ACL is a fleet convention. REVOKE FROM PUBLIC does not remove
--    the EXECUTE that Supabase default privileges grant to authenticated at
--    CREATE; the line that matters is anon.
REVOKE ALL ON FUNCTION public.run_pipeline_v3(date,integer,uuid,boolean,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.approve_pipeline_run_v3(uuid,text)              FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.run_pipeline_v3(date,integer,uuid,boolean,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.approve_pipeline_run_v3(uuid,text)              TO authenticated, service_role;
