-- PRD-110 leg 22 · golden harness only. TWO defects, found because fixture 2 reported
-- "0 pass / 0 fail / passed = true" -- a vacuous green, the most dangerous result a test
-- harness can produce.
--
-- DEFECT 1 (plumbing). golden.run_all(p_phase) filters the FIXTURE set by p_phase but then
-- calls golden.run_fixture(id, note) WITHOUT it. run_fixture falls back to
-- golden.config.current_phase ('P1'), so every P2 assertion was skipped. As shipped,
-- run_all('P2') could never evaluate a single P2 assertion.
--
-- DEFECT 2 (missing guard, one level down). The harness already refuses to call an empty
-- FIXTURE set green -- "Guard 2: an empty run is never a pass". It had no equivalent for an
-- empty ASSERTION set, so the same mistake one level down read as success. Guard 3 closes it:
-- a run that evaluated nothing is not a pass, and it says so in detail.vacuous.
--
-- Also advances golden.config.current_phase P1 -> P2. Phases 0 and 1 are CLOSED and Phase 2
-- is in progress, so this is the honest value. It wakes 4 assertions deliberately deferred to
-- P2 (fixture 3 x2, fixture 5 x1, fixture 105 x1) which have never once been evaluated.

CREATE OR REPLACE FUNCTION golden.run_fixture(p_fixture_id integer, p_note text DEFAULT NULL::text, p_max_phase text DEFAULT NULL::text)
 RETURNS TABLE(seq integer, description text, expect_op text, expect text, actual text, passed boolean, skipped boolean, err text)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_fx golden.fixtures; v_run_id uuid; v_a record;
  v_actual text; v_passed boolean; v_err text; v_skip boolean;
  v_phase text; v_pass int := 0; v_fail int := 0; v_skipped int := 0;
  v_detail jsonb := '[]'::jsonb;
  v_vacuous boolean;
  v_t0 timestamptz := clock_timestamp();
BEGIN
  SELECT * INTO v_fx FROM golden.fixtures WHERE fixture_id = p_fixture_id;
  IF v_fx.fixture_id IS NULL THEN
    RAISE EXCEPTION 'golden.run_fixture: no fixture %', p_fixture_id;
  END IF;

  v_phase := COALESCE(p_max_phase, (SELECT current_phase FROM golden.config WHERE id = 1), 'P0');

  INSERT INTO golden.runs (fixture_id, note, started_at)
  VALUES (p_fixture_id, p_note, v_t0) RETURNING run_id INTO v_run_id;

  IF v_fx.scenario_sql IS NOT NULL AND btrim(v_fx.scenario_sql) <> '' THEN
    BEGIN
      EXECUTE golden.render(v_fx.scenario_sql, p_fixture_id);
    EXCEPTION WHEN OTHERS THEN
      v_detail := v_detail || jsonb_build_object('scenario_error', SQLERRM);
      v_fail := v_fail + 1;
    END;
  END IF;

  FOR v_a IN
    SELECT a.seq, a.description, a.check_sql, a.expect_op, a.expect, a.phase_required
    FROM golden.assertions a
    WHERE a.fixture_id = p_fixture_id AND a.enabled ORDER BY a.seq
  LOOP
    v_actual := NULL; v_err := NULL; v_passed := NULL;
    v_skip := golden.phase_rank(v_a.phase_required) > golden.phase_rank(v_phase);

    IF v_skip THEN
      v_skipped := v_skipped + 1;
    ELSE
      BEGIN
        EXECUTE golden.render(v_a.check_sql, p_fixture_id) INTO v_actual;
        v_passed := golden.compare(v_actual, v_a.expect_op, v_a.expect);
      EXCEPTION WHEN OTHERS THEN
        v_err := SQLERRM; v_passed := false;
      END;
      IF v_passed THEN v_pass := v_pass + 1; ELSE v_fail := v_fail + 1; END IF;
    END IF;

    v_detail := v_detail || jsonb_build_object(
      'seq', v_a.seq, 'description', v_a.description, 'phase_required', v_a.phase_required,
      'expect_op', v_a.expect_op, 'expect', v_a.expect, 'actual', v_actual,
      'passed', v_passed, 'skipped', v_skip, 'err', v_err);

    RETURN QUERY SELECT v_a.seq, v_a.description, v_a.expect_op, v_a.expect,
                        v_actual, v_passed, v_skip, v_err;
  END LOOP;

  -- Guard 3: a run that evaluated NOTHING is not a pass. Same principle as run_all's
  -- Guard 2, one level down. Without this, any phase-gating mistake reads as green.
  v_vacuous := (v_pass + v_fail) = 0;

  UPDATE golden.runs
     SET finished_at = clock_timestamp(),
         duration_ms = (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int,
         passed = (v_fail = 0 AND NOT v_vacuous), n_pass = v_pass, n_fail = v_fail,
         detail = v_detail || jsonb_build_object('skipped_count', v_skipped, 'phase', v_phase,
                                                 'vacuous', v_vacuous)
   WHERE run_id = v_run_id;
END $function$;

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
    -- Defect 1 fix: pass the phase THROUGH. Filtering the fixture set by p_phase while
    -- letting run_fixture fall back to config.current_phase meant run_all('P2') skipped
    -- every P2 assertion and still reported green.
    PERFORM golden.run_fixture(v_fx.fixture_id, p_note,
                               GREATEST(COALESCE(p_phase, v_fx.phase_required), v_fx.phase_required));
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

UPDATE golden.config SET current_phase = 'P2', updated_at = now(),
       note = 'PRD-110 leg 22: Phase 0 and Phase 1 CLOSED, Phase 2 (P2.1 velocity objects) in progress. Advancing wakes 4 assertions deferred to P2 in fixtures 3, 5 and 105.'
 WHERE id = 1;
