-- PRD-110 · relay leg 27 · S-28 CLOSE, part 2 of 2 — wire fixtures 20/21/22 to golden.arrange_shelf
--
-- Part 1 (prd110_golden_arrange_shelf_d08_fleetwide_immunity) built the primitive. It changes
-- nothing until the fixtures CALL it. This is that call, and only that call: not one assertion
-- is edited. If the arrange step is right, every existing assertion is right in BOTH worlds
-- (cron 44 scoped to MPMCC-1058, and cron 44 fleet-wide), which is the proof that these
-- fixtures were always asserting the correct thing and merely borrowing preconditions they
-- did not own.
--
-- ⚠️ PLACEMENT IS LOAD-BEARING, TWICE OVER:
--   1. golden.run_fixture does NOT wrap scenario_sql in a rollback envelope. The envelope is
--      each fixture's OWN inner `BEGIN ... RAISE 'GPnn:' ... EXCEPTION` block, which is a
--      plpgsql subtransaction that aborts and rolls back. So the call must go INSIDE that
--      inner BEGIN. Placed before it, arrange_shelf's shelf_composition DELETE and its
--      weimi_device_status replay would COMMIT to production.
--   2. It must precede the fixture's own record_inventory_event_v3 loads, or the DELETE would
--      erase the very belief the fixture just seeded.
-- Both are satisfied by anchoring on the first comment line inside the inner BEGIN.
--
-- p_release_snapshot: TRUE for 20 and 22 (they call the estimator, so they need an unconsumed
-- source_ref — root cause A). FALSE for 21, which never calls the estimator and needs only the
-- belief reset — root cause B. Least action: fixture 21 appends no WEIMI row at all.
--
-- METHOD. Nothing is retyped. Each edit is one exact substitution over the LIVE scenario_sql,
-- asserted to match EXACTLY ONCE, and then a reverse substitution asserted to reproduce the
-- original byte-for-byte before the UPDATE runs — proving not merely that the edit landed but
-- that nothing else moved. Re-running the migration is a clean no-op (Article 12).

DO $wire$
DECLARE
  v_src text; v_new text; v_anchor text; v_repl text; v_n int; v_done int := 0; v_skip int := 0;
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      (20,
       E'  BEGIN\n    -- E3: sellable bucket',
       E'  BEGIN\n    -- leg 27 (S-28 root cause B): own our preconditions before asserting on\n    -- them, so this fixture reads the same whether or not cron 44 got here first.\n    PERFORM golden.arrange_shelf(v_sa, true);\n    PERFORM golden.arrange_shelf(v_sb, true);\n    -- E3: sellable bucket'),
      (21,
       E'  BEGIN\n    -- a drifted estimate:',
       E'  BEGIN\n    -- leg 27 (S-28 root cause B): reset inherited cold-start belief. No snapshot\n    -- release: this fixture never calls the estimator, so it needs no fresh source_ref.\n    PERFORM golden.arrange_shelf(v_s, false);\n    -- a drifted estimate:'),
      (22,
       E'  BEGIN\n    -- PART 1 - causation.',
       E'  BEGIN\n    -- leg 27 (S-28 root causes A+B): own our preconditions before asserting on them.\n    PERFORM golden.arrange_shelf(v_s, true);\n    -- PART 1 - causation.')
    ) AS t(fixture_id, anchor, repl)
  LOOP
    SELECT scenario_sql INTO v_src FROM golden.fixtures WHERE fixture_id = r.fixture_id;
    IF v_src IS NULL THEN
      RAISE EXCEPTION 'golden.fixtures has no fixture %', r.fixture_id;
    END IF;

    -- Article 12: idempotent. Already wired => clean no-op, not a raise.
    IF position('golden.arrange_shelf' in v_src) > 0 THEN
      v_skip := v_skip + 1;
      CONTINUE;
    END IF;

    v_anchor := r.anchor;
    v_repl   := r.repl;

    v_n := (length(v_src) - length(replace(v_src, v_anchor, ''))) / length(v_anchor);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'fixture %: anchor matched % times, expected exactly 1', r.fixture_id, v_n;
    END IF;

    v_new := replace(v_src, v_anchor, v_repl);

    -- the reverse substitution must reproduce the original byte-for-byte
    IF replace(v_new, v_repl, v_anchor) IS DISTINCT FROM v_src THEN
      RAISE EXCEPTION 'fixture %: reverse substitution did not reproduce the original', r.fixture_id;
    END IF;
    IF length(v_new) <> length(v_src) - length(v_anchor) + length(v_repl) THEN
      RAISE EXCEPTION 'fixture %: length delta is not the single expected edit', r.fixture_id;
    END IF;

    UPDATE golden.fixtures SET scenario_sql = v_new WHERE fixture_id = r.fixture_id;
    v_done := v_done + 1;
  END LOOP;

  IF v_done + v_skip <> 3 THEN
    RAISE EXCEPTION 'expected 3 fixtures handled, got % edited + % already-wired', v_done, v_skip;
  END IF;

  -- Post-condition: all three now call the primitive, and no other fixture does.
  IF (SELECT count(*) FROM golden.fixtures WHERE scenario_sql LIKE '%golden.arrange_shelf%') <> 3 THEN
    RAISE EXCEPTION 'expected exactly 3 fixtures wired to golden.arrange_shelf, got %',
      (SELECT count(*) FROM golden.fixtures WHERE scenario_sql LIKE '%golden.arrange_shelf%');
  END IF;

  RAISE NOTICE 'fixtures wired: % edited, % already wired', v_done, v_skip;
END
$wire$;
