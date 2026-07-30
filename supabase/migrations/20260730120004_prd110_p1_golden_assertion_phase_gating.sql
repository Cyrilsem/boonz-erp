-- PRD-110 STEP 1 — per-assertion phase gating.
-- Applied via MCP as `prd110_p1_golden_assertion_phase_gating` 2026-07-30.
-- GOLDEN-FIXTURES.md: "remainder with their phases (phase_required column enforces)".
-- A fixture can now carry assertions belonging to a LATER phase without holding the current
-- phase's gate red — the difference between an honest red and a fake green.

ALTER TABLE golden.assertions
  ADD COLUMN IF NOT EXISTS phase_required text NOT NULL DEFAULT 'P0'
    CHECK (phase_required IN ('P0','P1','P2','P3','P4','P5'));

CREATE TABLE IF NOT EXISTS golden.config (
  id            int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  current_phase text NOT NULL DEFAULT 'P0'
                  CHECK (current_phase IN ('P0','P1','P2','P3','P4','P5')),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  note          text
);
ALTER TABLE golden.config ENABLE ROW LEVEL SECURITY;
INSERT INTO golden.config (id, current_phase, note)
VALUES (1, 'P0', 'PRD-110 loop build phase. Assertions above this phase are reported as skipped, not failed.')
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION golden.phase_rank(p text) RETURNS int
LANGUAGE sql IMMUTABLE AS $$ SELECT array_position(ARRAY['P0','P1','P2','P3','P4','P5'], p) $$;

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
BEGIN
  SELECT * INTO v_fx FROM golden.fixtures WHERE fixture_id = p_fixture_id;
  IF v_fx.fixture_id IS NULL THEN
    RAISE EXCEPTION 'golden.run_fixture: no fixture %', p_fixture_id;
  END IF;

  v_phase := COALESCE(p_max_phase, (SELECT current_phase FROM golden.config WHERE id = 1), 'P0');

  INSERT INTO golden.runs (fixture_id, note) VALUES (p_fixture_id, p_note) RETURNING run_id INTO v_run_id;

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
     SET finished_at = now(), passed = (v_fail = 0), n_pass = v_pass, n_fail = v_fail,
         detail = v_detail || jsonb_build_object('skipped_count', v_skipped, 'phase', v_phase)
   WHERE run_id = v_run_id;
END $$;

CREATE OR REPLACE FUNCTION golden.run_all(p_phase text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS TABLE (fixture_id int, name text, phase_required text,
               n_pass int, n_fail int, passed boolean)
LANGUAGE plpgsql AS $$
DECLARE v_fx record;
BEGIN
  FOR v_fx IN
    SELECT f.fixture_id, f.name, f.phase_required FROM golden.fixtures f
    WHERE f.enabled AND (p_phase IS NULL OR f.phase_required = p_phase)
    ORDER BY f.fixture_id
  LOOP
    PERFORM golden.run_fixture(v_fx.fixture_id, p_note);
    RETURN QUERY SELECT v_fx.fixture_id, v_fx.name, v_fx.phase_required, r.n_pass, r.n_fail, r.passed
      FROM golden.runs r WHERE r.fixture_id = v_fx.fixture_id
      ORDER BY r.started_at DESC LIMIT 1;
  END LOOP;
END $$;

UPDATE golden.assertions SET phase_required = 'P2' WHERE fixture_id = 3 AND seq IN (1, 4);
UPDATE golden.assertions SET enabled = true      WHERE fixture_id = 3 AND seq = 4;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA golden FROM PUBLIC;
REVOKE ALL ON ALL TABLES    IN SCHEMA golden FROM PUBLIC;
