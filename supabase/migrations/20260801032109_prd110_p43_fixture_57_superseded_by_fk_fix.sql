SET LOCAL statement_timeout = '120s';

-- PRD-110 fixture 57 fix. plan_edits_v3.superseded_by is a FK to another EDIT,
-- not to a user, and it is DEFERRABLE INITIALLY DEFERRED - so the violation was
-- invisible to the rolled-back dry run (the constraint is only checked at
-- COMMIT, which a dry run never reaches). chk_plan_edits_v3_supersede
-- explicitly permits superseded_at set with superseded_by NULL, which is the
-- honest shape: the harness retired the row, there is no successor edit.
--
-- ⭐ Landmine for later legs: a `BEGIN; ...; ROLLBACK;` dry run does NOT check
--    DEFERRED constraints. Anything touching a deferrable FK needs a committed
--    probe, not just a dry run.
DO $fix$
DECLARE v_sql text; v_n int;
BEGIN
  SELECT scenario_sql INTO v_sql FROM golden.fixtures WHERE fixture_id = 57;
  IF v_sql IS NULL THEN
    RAISE EXCEPTION 'fixture 57 has no scenario to amend';
  END IF;

  v_n := (length(v_sql) - length(replace(v_sql, 'superseded_by = admin_uuid', ''))) / length('superseded_by = admin_uuid');
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'expected the anchor exactly twice, found % - refusing to substitute blind', v_n;
  END IF;

  v_sql := replace(v_sql, 'superseded_by = admin_uuid', 'superseded_by = NULL');

  IF v_sql LIKE '%superseded_by = admin_uuid%' THEN
    RAISE EXCEPTION 'substitution left the bad anchor behind';
  END IF;

  UPDATE golden.fixtures SET scenario_sql = v_sql WHERE fixture_id = 57;
END $fix$;
