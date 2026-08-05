SET LOCAL statement_timeout = '120s';

-- PRD-110 fixture 57: strand cleanup + make the reclaim FOLLOW an anchor move.
--
-- The reclaim hardening did exactly what it should: because machine 0a46324c
-- carries fixtures 55/56 feedback, fixture 57's anchor moved off it to
-- 0f698c26. But the 3 ledger rows + 3 proposals its earlier (machine-scoped)
-- runs had left on the OLD anchor were then unreachable - the fixture no longer
-- looks there. Counters read 15/11 instead of 12/8.
--
-- ⭐ THE GENERAL LESSON: a reclaim keyed on a DERIVED anchor leaks every time
--    the anchor moves. The fixture now records its anchor in scratch (it always
--    did) and reclaims the PREVIOUSLY RECORDED anchor as well as the current
--    one, so a future move cleans up after itself.
--
-- ⛔ Deliberately NOT reclaiming miner rows fleet-wide: once P4.3 is on a cron,
--    real miner rows on real machines are production data, and a fixture that
--    deleted them by channel alone would be far worse than the leak it fixes.

DO $cleanup$
DECLARE v_l int; v_p int; v_pins int;
BEGIN
  -- pins first (none expected - the fixture asserts the miner mints none)
  SELECT count(*) INTO v_pins FROM public.planning_pins_v3 p
   WHERE p.proposal_id IN (SELECT proposal_id FROM public.feedback_proposals_v3
                            WHERE trigger_reason LIKE 'WS-H2 recurring%'
                              AND machine_id = '0a46324c-77f0-4e8f-aa13-2716557c1e27'::uuid);
  IF v_pins <> 0 THEN
    RAISE EXCEPTION 'refusing to clean up: % pins descend from the stranded proposals', v_pins;
  END IF;

  DELETE FROM public.feedback_proposals_v3
   WHERE machine_id = '0a46324c-77f0-4e8f-aa13-2716557c1e27'::uuid
     AND trigger_reason LIKE 'WS-H2 recurring%';
  GET DIAGNOSTICS v_p = ROW_COUNT;

  DELETE FROM public.feedback_ledger_v3
   WHERE machine_id = '0a46324c-77f0-4e8f-aa13-2716557c1e27'::uuid
     AND channel = 'miner';
  GET DIAGNOSTICS v_l = ROW_COUNT;

  IF v_p <> 3 OR v_l <> 3 THEN
    RAISE EXCEPTION 'expected exactly 3 stranded proposals and 3 stranded ledger rows, removed % and %', v_p, v_l;
  END IF;
END $cleanup$;

DO $amend$
DECLARE v_sql text; v_old text; v_new text; v_n int;
BEGIN
  SELECT scenario_sql INTO v_sql FROM golden.fixtures WHERE fixture_id = 57;

  -- 1. a variable to hold the previously recorded anchor
  v_old := '  mA uuid; mB uuid;';
  v_new := '  mA uuid; mB uuid; mPrev uuid;';
  v_n := (length(v_sql) - length(replace(v_sql, v_old, ''))) / length(v_old);
  IF v_n <> 1 THEN RAISE EXCEPTION 'declare anchor matched % times, expected 1', v_n; END IF;
  v_sql := replace(v_sql, v_old, v_new);

  -- 2. reclaim the previous anchor too, reading it BEFORE scratch is cleared
  v_old := '  DELETE FROM golden.scratch WHERE fixture_id = 57;';
  v_new :=
    '  -- ⭐ follow an anchor move: reclaim where the LAST run actually wrote.' || E'\n' ||
    '  SELECT (value #>> ''{}'')::uuid INTO mPrev FROM golden.scratch' || E'\n' ||
    '   WHERE fixture_id = 57 AND key = ''mA'';' || E'\n' ||
    '  IF mPrev IS NOT NULL AND mPrev <> mA THEN' || E'\n' ||
    '    DELETE FROM public.feedback_proposals_v3' || E'\n' ||
    '     WHERE machine_id = mPrev AND trigger_reason LIKE ''WS-H2 recurring%'';' || E'\n' ||
    '    DELETE FROM public.feedback_ledger_v3' || E'\n' ||
    '     WHERE machine_id = mPrev AND channel = ''miner'';' || E'\n' ||
    '  END IF;' || E'\n' ||
    '  DELETE FROM golden.scratch WHERE fixture_id = 57;';
  v_n := (length(v_sql) - length(replace(v_sql, v_old, ''))) / length(v_old);
  IF v_n <> 1 THEN RAISE EXCEPTION 'scratch-clear anchor matched % times, expected 1', v_n; END IF;
  v_sql := replace(v_sql, v_old, v_new);

  UPDATE golden.fixtures SET scenario_sql = v_sql WHERE fixture_id = 57;
END $amend$;
