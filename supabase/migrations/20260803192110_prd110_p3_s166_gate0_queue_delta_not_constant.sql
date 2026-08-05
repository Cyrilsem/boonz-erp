-- PRD-110 leg 97 · S-166 · P3 fixture repair.
--
-- DEFECT: fixtures 11/50/51 assert "the Gate-0 queue is untouched" as an
-- ABSOLUTE count (machines_to_visit = 1240). public.machines_to_visit grows
-- nightly via cron 13 (16:00 UTC). The table now stands at 1330, so 50 seq 46
-- and 51 seq 51 are RED from production drift alone -- green on 2026-08-01,
-- red on 2026-08-03, with nothing changed but production. 11 seq 38 carries
-- the identical shape and is green only because its scratch row is stale from
-- an older run; it goes red the moment the fixture is re-run.
--
-- FIX: express the intent -- a DELTA ("this fixture did not move the board")
-- -- as a delta. Each body captures the count BEFORE the scenario runs; the
-- existing tripwire section already captures it AFTER; the assertion subtracts
-- and expects 0. This is the shape fixture 1 seq 83 already uses in this repo.
--
-- REFUSED: bumping the constant 1240 -> 1330. That re-arms the identical decay
-- and yields an assertion that is green and meaningless.
--
-- LAW 12: this migration does not read-modify-write public.machines_to_visit
-- or any live plan table. It touches golden.fixtures and golden.assertions only.
-- Re-application is a proven no-op (marker guard on 'tripwires_before').

DO $mig$
DECLARE
  v_ids    int[] := ARRAY[11, 50, 51];
  v_id     int;
  v_anchor text := 'DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};';
  v_src    text;
  v_n      int;
  v_block  text;
  v_n_upd  int;
BEGIN
  -- Guard: already applied to all three -> no-op.
  IF (SELECT bool_and(position('tripwires_before' in scenario_sql) > 0)
        FROM golden.fixtures WHERE fixture_id = ANY(v_ids)) THEN
    RAISE NOTICE 'S-166: before-capture already present in 11/50/51; no-op.';
    RETURN;
  END IF;

  v_block := E'\n\n'
    || '-- ---------------------------------------------------------------------------' || E'\n'
    || '-- (0a) LIVE-BOARD BEFORE-CAPTURE (S-166). The Gate-0 queue grows nightly via'   || E'\n'
    || '--      cron 13, so "this fixture did not touch it" MUST be asserted as a'       || E'\n'
    || '--      same-run DELTA. Captured HERE, before any scenario work; the tripwire'   || E'\n'
    || '--      section at the foot of this body captures the same count AFTER. An'      || E'\n'
    || '--      absolute constant is a decaying tripwire: green the day it is written,'  || E'\n'
    || '--      red weeks later with nothing changed but production.'                    || E'\n'
    || '-- ---------------------------------------------------------------------------' || E'\n'
    || 'INSERT INTO golden.scratch (fixture_id, key, value)'                             || E'\n'
    || 'SELECT {{fixture_id}}, ''tripwires_before'', jsonb_build_object('                || E'\n'
    || '  ''machines_to_visit'', (SELECT count(*) FROM public.machines_to_visit));';

  FOREACH v_id IN ARRAY v_ids LOOP
    SELECT scenario_sql INTO v_src FROM golden.fixtures WHERE fixture_id = v_id;
    IF v_src IS NULL THEN
      RAISE EXCEPTION 'S-166: fixture % has no scenario_sql', v_id;
    END IF;

    -- Substitution safety: the anchor must match EXACTLY once, counted as an
    -- exact substring, BEFORE anything is replaced.
    v_n := (length(v_src) - length(replace(v_src, v_anchor, ''))) / length(v_anchor);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'S-166: anchor matched % times in fixture % (expected exactly 1)', v_n, v_id;
    END IF;

    UPDATE golden.fixtures
       SET scenario_sql = replace(v_src, v_anchor, v_anchor || v_block)
     WHERE fixture_id = v_id;
  END LOOP;

  -- Every body must now carry the before-capture exactly once.
  IF (SELECT count(*) FROM golden.fixtures
       WHERE fixture_id = ANY(v_ids)
         AND (length(scenario_sql) - length(replace(scenario_sql, 'tripwires_before', '')))
             / length('tripwires_before') = 1) <> 3 THEN
    RAISE EXCEPTION 'S-166: before-capture not present exactly once in all three bodies';
  END IF;

  -- -------------------------------------------------------------------------
  -- Cody R1: this MUST live in the same DO block as the body edits. Two blocks
  -- are two statements, and a failure here would otherwise leave bodies that
  -- carry a before-capture no assertion reads -- a half-applied migration.
  -- Rewrite the three decaying assertions as same-run deltas. COALESCE(...,
  -- 'absent') so a MISSING capture fails loudly instead of passing as NULL.
  -- -------------------------------------------------------------------------
  UPDATE golden.assertions a
     SET check_sql = format(
           'SELECT COALESCE((' || E'\n'
        || '         (SELECT (value->>''machines_to_visit'')::int FROM golden.scratch WHERE fixture_id=%s AND key=''tripwires'')' || E'\n'
        || '       - (SELECT (value->>''machines_to_visit'')::int FROM golden.scratch WHERE fixture_id=%s AND key=''tripwires_before'')' || E'\n'
        || '       )::text, ''absent'')', a.fixture_id, a.fixture_id),
         expect_op   = 'eq',
         expect      = '0',
         description = 'LAW 4/11: the Gate-0 queue is untouched - asserted as a same-run DELTA (before vs after), never as a pinned constant (S-166)'
   WHERE (a.fixture_id, a.seq) IN ((11, 38), (50, 46), (51, 51));

  GET DIAGNOSTICS v_n_upd = ROW_COUNT;
  IF v_n_upd <> 3 THEN
    RAISE EXCEPTION 'S-166: expected to rewrite 3 assertions, rewrote %', v_n_upd;
  END IF;

  -- No decaying absolute may survive on this metric.
  IF EXISTS (SELECT 1 FROM golden.assertions
              WHERE check_sql ILIKE '%machines_to_visit%'
                AND expect = '1240') THEN
    RAISE EXCEPTION 'S-166: a pinned 1240 assertion still survives';
  END IF;
END
$mig$;
