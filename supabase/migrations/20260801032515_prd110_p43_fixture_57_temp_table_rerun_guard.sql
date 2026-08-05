SET LOCAL statement_timeout = '120s';

-- PRD-110 fixture 57: the S-101 landmine, this time inside the FIXTURE.
--
-- ⛔ `ON COMMIT DROP` is not `ON RETURN DROP`. Two run_fixture(57) calls in ONE
--    transaction (golden.run_all does exactly this) collided on _fx57_single:
--    'relation "_fx57_single" already exists'.
--
-- ⛔ AND THE FAILURE MODE IS THE DANGEROUS KIND: the scenario threw, but 39 of
--    the 39 assertions still reported GREEN, because a thrown scenario leaves
--    the PREVIOUS run's scratch in place (S-107) and every assertion reads
--    scratch. Only run_fixture's own scenario_error counter (n_fail = 1 with no
--    failing seq) exposed it. ⭐ A fixture whose assertions are green while its
--    scenario threw is worse than a red one - check n_fail against the number
--    of failing seqs, not just the seq list.
DO $fix$
DECLARE v_sql text; v_old text; v_new text; v_n int;
BEGIN
  SELECT scenario_sql INTO v_sql FROM golden.fixtures WHERE fixture_id = 57;

  v_old := '  CREATE TEMP TABLE _fx57_single ON COMMIT DROP AS';
  v_new := '  DROP TABLE IF EXISTS _fx57_single;' || E'\n' ||
           '  CREATE TEMP TABLE _fx57_single ON COMMIT DROP AS';

  v_n := (length(v_sql) - length(replace(v_sql, v_old, ''))) / length(v_old);
  IF v_n <> 1 THEN RAISE EXCEPTION 'temp-table anchor matched % times, expected 1', v_n; END IF;
  IF v_sql LIKE '%DROP TABLE IF EXISTS _fx57_single;%' THEN
    RAISE EXCEPTION 'already applied';
  END IF;

  UPDATE golden.fixtures SET scenario_sql = replace(v_sql, v_old, v_new) WHERE fixture_id = 57;
END $fix$;
