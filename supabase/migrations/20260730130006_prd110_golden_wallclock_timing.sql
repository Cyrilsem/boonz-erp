-- PRD-110 harness fix - golden.runs must measure WALL-CLOCK time, not transaction time.
-- Applied via Supabase MCP as `prd110_golden_wallclock_timing` 2026-07-30.
--
-- FOUND BY USE, NOT BY REVIEW: every golden.runs row reports secs = 0.00, including runs that
-- visibly took seconds. Cause: started_at DEFAULT now() and finished_at = now() are both the
-- TRANSACTION timestamp, which is frozen for the life of the transaction, so their difference is
-- identically zero by construction.
--
-- Why it matters beyond tidiness: STEP 7 stress case S1 is "full-fleet shadow run, all machines,
-- one date - runtime < 10 min", and S7 is "golden.run_all() x3 consecutive - identical results".
-- Both are timing claims. A harness that reports 0.00s for everything cannot produce that
-- evidence, and a stress suite signed off on unmeasurable timings is not evidence at all.
-- (This is the same failure mode as the golden.compare case_not_found bug: the harness lying
-- quietly. Caught the same way - by actually reading its output instead of assuming it.)
--
-- Also adds duration_ms to golden.runs so the number is stored, not recomputed by every reader.
-- Article 12: forward-only; run_fixture signature UNCHANGED (3 args, one default) so no overload
-- is created - the 42725 lesson from 20260730120007 applies here.

ALTER TABLE golden.runs ADD COLUMN IF NOT EXISTS duration_ms int;
COMMENT ON COLUMN golden.runs.duration_ms IS
  'Wall-clock scenario+assertion time from clock_timestamp() deltas. now() cannot be used: it is '
  'the transaction timestamp and would always yield 0.';

CREATE OR REPLACE FUNCTION golden.run_fixture(p_fixture_id int, p_note text DEFAULT NULL,
                                              p_max_phase text DEFAULT NULL)
RETURNS TABLE (seq int, description text, expect_op text, expect text,
               actual text, passed boolean, skipped boolean, err text)
LANGUAGE plpgsql AS $$
DECLARE
  v_fx golden.fixtures; v_run_id uuid; v_a record;
  v_actual text; v_passed boolean; v_err text; v_skip boolean;
  v_phase text; v_pass int := 0; v_fail int := 0; v_skipped int := 0;
  v_detail jsonb := '[]'::jsonb;
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

  UPDATE golden.runs
     SET finished_at = clock_timestamp(),
         duration_ms = (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int,
         passed = (v_fail = 0), n_pass = v_pass, n_fail = v_fail,
         detail = v_detail || jsonb_build_object('skipped_count', v_skipped, 'phase', v_phase)
   WHERE run_id = v_run_id;
END $$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA golden FROM PUBLIC;

DO $assert$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'golden' AND p.proname = 'run_fixture';
  IF n <> 1 THEN
    RAISE EXCEPTION 'golden.run_fixture must have exactly 1 signature, found % (42725 regression)', n;
  END IF;
END $assert$;
