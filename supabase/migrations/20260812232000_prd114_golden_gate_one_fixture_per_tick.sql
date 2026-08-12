-- PRD-114 acceptance 5 - the golden gate, rebuilt one-fixture-per-tick.
--
-- PRD-003 G-3 established why this cannot be a DO block over N fixtures and
-- cannot be driven from a shell:
--   * set_config(..., is_local => true) is TRANSACTION-scoped. Batching fixtures
--     into one transaction leaks a GUC set by one fixture into every fixture that
--     follows it, which manufactured a false RED on fixture 18 and could just as
--     easily manufacture a false GREEN on any fixture that asserts a GUC IS set.
--   * The Supabase Management API sits behind a ~100 s Cloudflare ceiling and
--     CANCELS the statement on gateway disconnect. Six fixtures exceed 90 s.
-- pg_cron gives each invocation its own transaction, which is the exact isolation
-- the historical PRD-110 sweep had.
--
-- Scheduled as job `prd114_golden_gate` at '* * * * *' with
--   SET statement_timeout='300000'; SELECT public.prd114_golden_gate_tick('PRD-114 gate');
-- and UNSCHEDULED once the sweep completed. The job is not recreated by this
-- migration on purpose: with every fixture claimed it would return immediately
-- forever, which is the litter PRD-003 cleaned up after itself.

CREATE OR REPLACE FUNCTION public.prd114_golden_gate_tick(p_tag text DEFAULT 'PRD-114 gate')
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'golden', 'pg_temp'
AS $function$
DECLARE
  v_fx    int;
  v_cfg   text := COALESCE((SELECT current_phase FROM golden.config WHERE id = 1), 'P0');
  v_req   text;
  v_gate  text;
BEGIN
  -- Overlap guard: a fixture that runs longer than the tick interval must not be
  -- joined by the next tick. Session-scoped, so a crashed tick releases it.
  IF NOT pg_try_advisory_lock(114114) THEN
    RETURN;
  END IF;

  -- cron 44 (prd110_p14_composition_estimator_hourly) rewrites shelf_composition
  -- at :40 every hour. Fixtures 2, 19, 20, 21, 22 and 27 compare a snapshot taken
  -- at fixture start against live values at fixture end, so a straddle is a red
  -- that means nothing. Stand down across the window.
  IF EXTRACT(minute FROM (now() AT TIME ZONE 'UTC')) BETWEEN 39 AND 42 THEN
    PERFORM pg_advisory_unlock(114114);
    RETURN;
  END IF;

  -- Next enabled fixture this sweep has not claimed. run_fixture INSERTs its run
  -- row before executing, so a fixture is claimed the moment it starts.
  SELECT f.fixture_id, f.phase_required INTO v_fx, v_req
  FROM golden.fixtures f
  WHERE f.enabled
    AND NOT EXISTS (
      SELECT 1 FROM golden.runs r
      WHERE r.fixture_id = f.fixture_id AND r.note = p_tag)
  ORDER BY f.fixture_id
  LIMIT 1;

  IF v_fx IS NULL THEN
    PERFORM pg_advisory_unlock(114114);
    RETURN;
  END IF;

  -- Byte-for-byte the gate golden.run_all computes. Do not simplify to 'P0':
  -- config.current_phase is 'P4' live and fixture 1 is a P3 fixture whose 59
  -- assertions are all at that phase, so a 'P0' run SKIPS every one of them and
  -- run_fixture's Guard 3 (a run that evaluated NOTHING is not a pass) reports
  -- 0/0/false. The first cut of this function did exactly that.
  v_gate := GREATEST('P0', v_cfg, COALESCE(v_req, 'P0'));

  PERFORM golden.run_fixture(v_fx, p_tag, v_gate);
  PERFORM pg_advisory_unlock(114114);
END
$function$;

COMMENT ON FUNCTION public.prd114_golden_gate_tick(text) IS
  'PRD-114 acceptance 5. Runs ONE golden fixture per invocation, so pg_cron gives each fixture its own transaction and no GUC leaks across the fixture boundary (PRD-003 G-3). Phase gate is GREATEST(P0, golden.config.current_phase, fixture.phase_required) - the same expression golden.run_all uses; hard-coding P0 skips every assertion in a P3/P4 fixture and produces a vacuous run. Carries the advisory-lock overlap guard and the cron-44 straddle guard. UNSCHEDULE the job when the sweep completes - with every fixture claimed it returns immediately forever.';

REVOKE ALL ON FUNCTION public.prd114_golden_gate_tick(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.prd114_golden_gate_tick(text) FROM anon;
REVOKE ALL ON FUNCTION public.prd114_golden_gate_tick(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.prd114_golden_gate_tick(text) TO service_role;
