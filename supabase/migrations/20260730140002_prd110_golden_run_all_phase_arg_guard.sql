-- PRD-110 harness hygiene: golden.run_all(p_phase, p_note) silently ran ZERO fixtures when a
-- note was passed positionally as p_phase (an easy mistake - run_fixture's 2nd arg IS the note).
-- It returned an empty set, which reads exactly like "all fixtures green, no failures".
-- A harness that reports green while executing nothing is the same class of defect as the
-- golden.compare case_not_found bug and the always-zero timing bug. Fail loudly instead.
--
-- Same signature (no new arg) so no overload is created - the 42725 lesson holds.

CREATE OR REPLACE FUNCTION golden.run_all(p_phase text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS TABLE(fixture_id integer, name text, phase_required text, n_pass integer, n_fail integer, passed boolean)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_fx record;
  v_n  int := 0;
BEGIN
  -- Guard 1: p_phase must be a real phase label. Catches note-passed-as-phase.
  IF p_phase IS NOT NULL AND p_phase NOT IN ('P0','P1','P2','P3','P4','P5') THEN
    RAISE EXCEPTION 'golden.run_all: p_phase must be one of P0..P5 (got %). '
                    'Did you mean golden.run_all(NULL, %L)? p_phase is the FIRST argument.',
                    p_phase, p_phase;
  END IF;

  FOR v_fx IN
    SELECT f.fixture_id, f.name, f.phase_required FROM golden.fixtures f
    WHERE f.enabled AND (p_phase IS NULL OR f.phase_required = p_phase)
    ORDER BY f.fixture_id
  LOOP
    v_n := v_n + 1;
    PERFORM golden.run_fixture(v_fx.fixture_id, p_note);
    RETURN QUERY SELECT v_fx.fixture_id, v_fx.name, v_fx.phase_required, r.n_pass, r.n_fail, r.passed
      FROM golden.runs r WHERE r.fixture_id = v_fx.fixture_id
      ORDER BY r.started_at DESC LIMIT 1;
  END LOOP;

  -- Guard 2: an empty run is never a pass. If the filter matched nothing, say so.
  IF v_n = 0 THEN
    RAISE EXCEPTION 'golden.run_all: matched 0 enabled fixtures (p_phase=%). '
                    'An empty result set must not be mistaken for green.',
                    COALESCE(p_phase,'NULL');
  END IF;
END $function$;
