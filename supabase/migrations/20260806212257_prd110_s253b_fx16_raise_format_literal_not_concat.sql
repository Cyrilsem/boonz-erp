-- PRD-110 leg 137 / S-253b - forward-only fix (Article 12) to the fixture-16 rewrite applied at
-- 20260806211956. That migration's setup guard used
--     RAISE EXCEPTION 'a' || 'b' || 'c';
-- PL/pgSQL's RAISE takes a FORMAT STRING LITERAL, not an expression, so the scenario failed to
-- parse: golden.runs recorded {"scenario_error": "syntax error at or near \"||\""}.
--
-- S-254, and it is the reason this is worth a paragraph rather than a one-line fix:
-- WHEN A SCENARIO RAISES, run_fixture ROLLS BACK ITS SUBTRANSACTION - INCLUDING THE SCENARIO'S OWN
-- `DELETE FROM golden.scratch`. The assertions then evaluate against the PREVIOUS run's
-- observations, which are still sitting there. Fixture 16 therefore reported 28/6 with seq 13/15/16
-- red at EXACTLY their pre-fix values (moved 2, qb_z 1, clamp_z pin_floor) - a red that looks like
-- a faithful re-measurement of the known defect and is in fact a measurement of nothing. Only the
-- two NEW assertions, whose keys did not exist in the stale blob, read NULL and gave the lie away.
-- The lesson generalises to all 58 fixtures: a scenario_error makes the whole assertion list
-- untrustworthy, not just unavailable. ALWAYS read golden.runs.detail[0] for scenario_error before
-- believing any red.

DO $mig$
DECLARE
  v_src text;
  v_new text;
  c_old CONSTANT text :=
E'      RAISE EXCEPTION ''FX16 setup: no shelf on this machine has ZERO warehouse availability - '' ||\n'
|| E'        ''the "a pin never conjures stock" premise cannot be staged, and re-baselining seq 15/16 '' ||\n'
|| E'        ''would delete that proof rather than fix it'';\n';
  c_new CONSTANT text :=
E'      RAISE EXCEPTION ''FX16 setup: no shelf on this machine has ZERO warehouse availability - the "a pin never conjures stock" premise cannot be staged, and re-baselining seq 15/16 would delete that proof rather than fix it'';\n';
BEGIN
  SELECT scenario_sql INTO v_src FROM golden.fixtures WHERE fixture_id = 16;
  IF position(c_old IN v_src) = 0 THEN
    RAISE EXCEPTION 'S-253b: the broken RAISE was not found - has it already been fixed?';
  END IF;
  v_new := replace(v_src, c_old, c_new);

  -- The whole failure was a RAISE built by concatenation. Prove none survives anywhere.
  IF v_new ~ 'RAISE EXCEPTION[^;]*\|\|' THEN
    RAISE EXCEPTION 'S-253b: a concatenated RAISE still survives in the scenario';
  END IF;

  UPDATE golden.fixtures
     SET scenario_sql = v_new,
         notes = notes || ' | S-253b/S-254: the setup guard RAISE was built with || and did not parse; '
              || 'PL/pgSQL RAISE takes a format literal. The failed parse rolled back the scenario '
              || 'subtransaction INCLUDING its DELETE of golden.scratch, so the assertions scored the '
              || 'PREVIOUS run''s blob and reproduced the old red exactly. Read runs.detail[0] for '
              || 'scenario_error before trusting any fixture red.'
   WHERE fixture_id = 16;
END $mig$;