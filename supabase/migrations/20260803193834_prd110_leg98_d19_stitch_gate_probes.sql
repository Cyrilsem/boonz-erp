-- PRD-110 leg 98 · D-19 pre-flip proof infrastructure.
--
-- Fixture 33 proves the preflight gate on public.commit_refill_plan. That is only
-- ONE of the two live enforcement sites the preflight_enforcement flag arms. The
-- other is public.stitch_pod_to_boonz, which the FE calls directly AND which
-- public.commit_refill_plan_atomic (the FE's only commit path) calls internally.
-- D-19 flips the flag to 'block'; nothing may be flipped before both sites are pinned.
--
-- These are golden-schema probes only. They touch no engine and no production row.

CREATE OR REPLACE FUNCTION golden.probe_stitch_under_mode(
  p_plan_date    date,
  p_mode         text,
  p_dry_run      boolean DEFAULT false,
  p_force        boolean DEFAULT false,
  p_force_reason text    DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_prev       text;
  v_row_id     bigint;
  v_res        jsonb;
  v_err        jsonb;
  v_ov_before  int;
  v_ov_after   int;
BEGIN
  IF p_mode NOT IN ('warn','block') THEN
    RAISE EXCEPTION 'golden.probe_stitch_under_mode: p_mode must be warn or block, got %', p_mode;
  END IF;

  SELECT rpp.id, COALESCE(rpp.preflight_enforcement,'warn')
    INTO v_row_id, v_prev
    FROM public.refill_policy_params rpp ORDER BY rpp.id LIMIT 1;

  SELECT count(*) INTO v_ov_before
    FROM public.preflight_override_log WHERE plan_date = p_plan_date;

  UPDATE public.refill_policy_params SET preflight_enforcement = p_mode WHERE id = v_row_id;

  BEGIN
    v_res := public.stitch_pod_to_boonz(p_plan_date, p_dry_run, p_force, p_force_reason);
  EXCEPTION WHEN OTHERS THEN
    v_err := jsonb_build_object('sqlstate', SQLSTATE, 'message', SQLERRM);
  END;

  SELECT count(*) INTO v_ov_after
    FROM public.preflight_override_log WHERE plan_date = p_plan_date;

  -- restore ALWAYS, on both the happy and the caught-exception path
  UPDATE public.refill_policy_params SET preflight_enforcement = v_prev WHERE id = v_row_id;

  RETURN jsonb_build_object(
    'mode',               p_mode,
    'prev_mode',          v_prev,
    'dry_run',            p_dry_run,
    'force',              p_force,
    'result',             COALESCE(v_res, 'null'::jsonb),
    'error',              COALESCE(v_err, 'null'::jsonb),
    'override_log_delta', v_ov_after - v_ov_before);
END
$fn$;

COMMENT ON FUNCTION golden.probe_stitch_under_mode(date,text,boolean,boolean,text) IS
  'PRD-110 leg 98. Runs stitch_pod_to_boonz under a temporarily forced preflight_enforcement '
  'mode and restores the flag on every path. Golden harness only.';

-- The transitive path. commit_refill_plan_atomic calls stitch_pod_to_boonz(date,false)
-- and RAISEs when the returned jsonb has no write_result.status='ok'. Under block mode a
-- preflight FAIL returns {'status':'preflight_failed'} with NO write_result key, so the
-- whole atomic commit aborts.
--
-- SAFETY: call this ONLY where the preflight verdict is FAIL and the mode is 'block', i.e.
-- where the call is guaranteed to abort at the gate and roll back. In any other combination
-- commit_refill_plan_atomic would run a real stitch over the fixture's synthetic rows.
CREATE OR REPLACE FUNCTION golden.probe_atomic_commit_under_mode(
  p_plan_date     date,
  p_mode          text,
  p_machine_names text[])
RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_prev            text;
  v_row_id          bigint;
  v_res             jsonb;
  v_err             jsonb;
  v_out_before      int;
  v_out_after       int;
BEGIN
  IF p_mode NOT IN ('warn','block') THEN
    RAISE EXCEPTION 'golden.probe_atomic_commit_under_mode: p_mode must be warn or block, got %', p_mode;
  END IF;

  SELECT rpp.id, COALESCE(rpp.preflight_enforcement,'warn')
    INTO v_row_id, v_prev
    FROM public.refill_policy_params rpp ORDER BY rpp.id LIMIT 1;

  SELECT count(*) INTO v_out_before
    FROM public.refill_plan_output WHERE plan_date = p_plan_date;

  UPDATE public.refill_policy_params SET preflight_enforcement = p_mode WHERE id = v_row_id;

  BEGIN
    v_res := public.commit_refill_plan_atomic(p_plan_date, p_machine_names);
  EXCEPTION WHEN OTHERS THEN
    v_err := jsonb_build_object('sqlstate', SQLSTATE, 'message', SQLERRM);
  END;

  SELECT count(*) INTO v_out_after
    FROM public.refill_plan_output WHERE plan_date = p_plan_date;

  UPDATE public.refill_policy_params SET preflight_enforcement = v_prev WHERE id = v_row_id;

  RETURN jsonb_build_object(
    'mode',              p_mode,
    'prev_mode',         v_prev,
    'result',            COALESCE(v_res, 'null'::jsonb),
    'error',             COALESCE(v_err, 'null'::jsonb),
    'plan_output_delta', v_out_after - v_out_before);
END
$fn$;

COMMENT ON FUNCTION golden.probe_atomic_commit_under_mode(date,text,text[]) IS
  'PRD-110 leg 98. Runs commit_refill_plan_atomic under a forced preflight_enforcement mode. '
  'Only safe where the call aborts at the preflight gate. Golden harness only.';
