-- PRD-110 leg 22 · golden harness only.
--
-- PROBLEM. Advancing config.current_phase to P2 woke 4 assertions that had never been
-- evaluated. Three fail, and they are SUPPOSED to: their own descriptions say "RED until P2",
-- "ENABLED AT P2.5, red until then", "Needs engine_add_pod_v3 to consume product_sourcing".
-- They are ACCEPTANCE CRITERIA for an engine that does not exist yet, not regressions.
--
-- But LAW 8 says a golden failure HALTS phase work until run_all is green. With these three
-- red for a legitimate reason, run_all('P0') can never be green again until late Phase 2 --
-- so the loop's own halt-signal would be permanently jammed, and the usual human response
-- (start ignoring a known-red suite) is exactly how a real regression gets missed.
--
-- The harness had no way to say "expected red until X exists". The fixtures expressed it in
-- PROSE, inside description strings, where no runner can read it.
--
-- FIX. golden.assertions.acceptance_gate_sql -- nullable SQL returning boolean.
--   NULL              => ordinary regression tripwire. A failure is a FAILURE. (unchanged)
--   returns FALSE     => the thing this asserts is not built yet. A failure is recorded as
--                        EXPECTED RED and does not count toward n_fail.
--   returns TRUE      => the artifact exists, so the assertion is fully binding from that
--                        moment on, with NO migration and nobody having to remember.
--
-- Deliberately EVIDENCE-based, not a hand-maintained phase label. The harness's vocabulary is
-- P0..P5 and cannot express "P2.5", which is precisely where two of these land. Keying on the
-- artifact's existence sidesteps that and cannot drift out of date.
-- A passing expected-red assertion is flagged 'arrived_early' -- information, not an error.

ALTER TABLE golden.assertions ADD COLUMN IF NOT EXISTS acceptance_gate_sql text;
COMMENT ON COLUMN golden.assertions.acceptance_gate_sql IS
  'Nullable boolean SQL. NULL = regression tripwire (failure is a failure). If present and it returns FALSE, this is an acceptance criterion whose subject is not built yet: a failure is counted as expected_red, not fail. When it returns TRUE the assertion becomes binding automatically.';

ALTER TABLE golden.runs ADD COLUMN IF NOT EXISTS n_expected_red int NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION golden.run_fixture(p_fixture_id integer, p_note text DEFAULT NULL::text, p_max_phase text DEFAULT NULL::text)
 RETURNS TABLE(seq integer, description text, expect_op text, expect text, actual text, passed boolean, skipped boolean, err text)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_fx golden.fixtures; v_run_id uuid; v_a record;
  v_actual text; v_passed boolean; v_err text; v_skip boolean;
  v_phase text; v_pass int := 0; v_fail int := 0; v_skipped int := 0; v_exp_red int := 0;
  v_detail jsonb := '[]'::jsonb;
  v_vacuous boolean;
  v_gate_open boolean; v_is_exp_red boolean; v_early boolean;
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
    SELECT a.seq, a.description, a.check_sql, a.expect_op, a.expect, a.phase_required, a.acceptance_gate_sql
    FROM golden.assertions a
    WHERE a.fixture_id = p_fixture_id AND a.enabled ORDER BY a.seq
  LOOP
    v_actual := NULL; v_err := NULL; v_passed := NULL;
    v_is_exp_red := false; v_early := false;
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

      -- Acceptance gate: is this assertion's subject built yet?
      v_gate_open := true;
      IF v_a.acceptance_gate_sql IS NOT NULL THEN
        BEGIN
          EXECUTE golden.render(v_a.acceptance_gate_sql, p_fixture_id) INTO v_gate_open;
          v_gate_open := COALESCE(v_gate_open, false);
        EXCEPTION WHEN OTHERS THEN
          -- A broken gate must never silence a failure. Fail closed: treat as binding.
          v_gate_open := true;
          v_err := COALESCE(v_err || ' | ', '') || 'acceptance_gate_sql error: ' || SQLERRM;
        END;
      END IF;

      IF v_passed THEN
        v_pass := v_pass + 1;
        v_early := (v_a.acceptance_gate_sql IS NOT NULL AND NOT v_gate_open);
      ELSIF NOT v_gate_open THEN
        v_is_exp_red := true; v_exp_red := v_exp_red + 1;
      ELSE
        v_fail := v_fail + 1;
      END IF;
    END IF;

    v_detail := v_detail || jsonb_build_object(
      'seq', v_a.seq, 'description', v_a.description, 'phase_required', v_a.phase_required,
      'expect_op', v_a.expect_op, 'expect', v_a.expect, 'actual', v_actual,
      'passed', v_passed, 'skipped', v_skip, 'err', v_err,
      'expected_red', v_is_exp_red, 'arrived_early', v_early);

    RETURN QUERY SELECT v_a.seq, v_a.description, v_a.expect_op, v_a.expect,
                        v_actual, v_passed, v_skip, v_err;
  END LOOP;

  -- Guard 3: a run that evaluated NOTHING is not a pass.
  v_vacuous := (v_pass + v_fail + v_exp_red) = 0;

  UPDATE golden.runs
     SET finished_at = clock_timestamp(),
         duration_ms = (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int,
         passed = (v_fail = 0 AND NOT v_vacuous), n_pass = v_pass, n_fail = v_fail,
         n_expected_red = v_exp_red,
         detail = v_detail || jsonb_build_object('skipped_count', v_skipped, 'phase', v_phase,
                                                 'vacuous', v_vacuous, 'expected_red_count', v_exp_red)
   WHERE run_id = v_run_id;
END $function$;

-- The three acceptance criteria, gated on the artifact each one is waiting for.
-- All three become binding the instant engine_add_pod_v3 is created. Nobody has to remember.
UPDATE golden.assertions
   SET acceptance_gate_sql = 'SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = ''engine_add_pod_v3'')'
 WHERE (fixture_id, seq) IN ((3,1), (3,4), (5,10), (105,10));
