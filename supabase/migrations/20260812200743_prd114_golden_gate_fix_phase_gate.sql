-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- pg_cron job 52's tick called golden.run_fixture(fx, tag, 'P0') instead of golden.run_all's GREATEST(p_phase, config.current_phase, fixture.phase_required); at P0 this skipped every P3/P4 assertion and Guard 3 ("a run that evaluated NOTHING is not a pass") reported 0/0/false. Fixed to compute the same expression. This reconstruction also carries the later same-function SECURITY INVOKER fix (a second, separate bug: SET ROLE is forbidden inside SECURITY DEFINER) since only the current live body is recoverable.

CREATE OR REPLACE FUNCTION public.prd114_golden_gate_tick(p_tag text DEFAULT 'PRD-114 gate'::text)
 RETURNS void
 LANGUAGE plpgsql
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
$function$
