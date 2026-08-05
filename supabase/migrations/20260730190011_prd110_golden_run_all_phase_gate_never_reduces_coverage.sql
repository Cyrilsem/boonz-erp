-- PRD-110 leg 22 · forward fix to the previous migration, caught before it was trusted.
--
-- The previous pass-through used GREATEST(COALESCE(p_phase, fixture_phase), fixture_phase).
-- That is wrong in the DOWNWARD direction: run_all('P0') would have gated fixture 3 at 'P0'
-- and skipped its 9 P1 assertions, silently cutting that suite from 14 evaluated to 5 --
-- a coverage LOSS dressed as a green run. Exactly the failure class Guard 3 was just added
-- to catch, reintroduced by the fix for it.
--
-- Correct semantics, stated explicitly:
--   * p_phase selects WHICH FIXTURES run. It is a filter, not a ceiling.
--   * The assertion gate is the HIGHEST of: p_phase, config.current_phase, and the
--     fixture's own phase_required. A fixture is never gated below its own phase (that
--     would be vacuous), and a narrower fixture filter never evaluates fewer assertions.
-- The gate is therefore monotone: no argument to run_all can reduce coverage.

CREATE OR REPLACE FUNCTION golden.run_all(p_phase text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS TABLE(fixture_id integer, name text, phase_required text, n_pass integer, n_fail integer, passed boolean)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_fx    record;
  v_n     int := 0;
  v_cfg   text := COALESCE((SELECT current_phase FROM golden.config WHERE id = 1), 'P0');
  v_gate  text;
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
    -- 'P0'..'P5' sort lexicographically in rank order, so GREATEST is the rank max.
    v_gate := GREATEST(COALESCE(p_phase, 'P0'), v_cfg, v_fx.phase_required);
    PERFORM golden.run_fixture(v_fx.fixture_id, p_note, v_gate);
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
