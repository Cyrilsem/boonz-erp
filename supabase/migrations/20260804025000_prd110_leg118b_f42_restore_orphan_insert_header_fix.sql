-- PRD-110 leg 118b - CORRECTIVE: fixture 42 scenario_sql, orphaned INSERT header before the
-- restore block. Forward-only fix for leg 118 (Article 12: never edit the applied migration).
--
-- THE DEFECT, MEASURED. Leg 118's restore replacement used this needle:
--     SELECT {{fixture_id}}, 'mtv_after', to_jsonb((SELECT count(*) FROM public.machines_to_visit));
-- and its payload re-emitted the full statement, INCLUDING a fresh
--     INSERT INTO golden.scratch (fixture_id, key, value)
-- header. But the needle matched only the SELECT line, so the ORIGINAL header was left dangling
-- immediately in front of the injected DO block:
--     INSERT INTO golden.scratch (fixture_id, key, value)
--     -- ── RESTORE the two banked cadence params ...
--     DO $fx42restore$ ...
-- which Postgres rejects with `syntax error at or near "DO"`.
--
-- ⭐ THE FAIL-LOUD DESIGN WORKED EXACTLY AS BUILT AND IS WHY THIS WAS UNAMBIGUOUS. run_fixture
-- caught the scenario error, banked it as `scenario_error`, and the run came back in 279 ms
-- instead of the usual ~107 s. The nine new sensors read `-1` / `MISSING` / `false` - i.e. seq 68
-- said "the plant never ran", precisely the reading its own description prescribes ("read it as
-- 'no precondition', not as 'the picker regressed'"). ⛔ NOTHING was diagnosed from seq 60 being
-- false; the sensors named the cause. That is the whole point of leg 118's remedy, demonstrated
-- on its own first run.
--
-- ⛔ THE TOOL LESSON, STATED FOR THE NEXT LEG (extends the leg 112/113/115 replace() rule):
-- when a replace() payload re-emits a multi-line statement, the NEEDLE MUST COVER EVERY LINE the
-- payload re-emits. Matching the tail of a statement and re-emitting the whole of it silently
-- duplicates the head. The leg-118 guard caught two real errors (a quoted 'breach' in a comment,
-- and a miscounted picker mention) but could not catch this one, because the fixture's SHAPE was
-- correct - plant present once, restore present once, order right. Only EXECUTION reveals it.
-- ⭐ The guard added below closes exactly that gap: it asserts no scratch INSERT header is
-- followed by anything other than SELECT/VALUES, which is a SYNTAX invariant, not a shape one.
--
-- SCOPE: golden.* only. One replace() on one fixture's scenario_sql. No assertion is added,
-- removed or altered (leg 118's 68-76 stand as applied). No protected entity, no DEFINER, no
-- RLS, no engine, no flag, no cron. Cody: same class as leg 118 itself, already reviewed.

UPDATE golden.fixtures
   SET scenario_sql = replace(
         scenario_sql,
         E'INSERT INTO golden.scratch (fixture_id, key, value)\n-- ── RESTORE the two banked cadence params',
         E'-- ── RESTORE the two banked cadence params')
 WHERE fixture_id = 42;

-- ── FAIL-LOUD GUARD: the SYNTAX invariant the leg-118 shape guard could not express ─────────
DO $guard118b$
DECLARE
  v_s text;
  v_hdr text := 'INSERT INTO golden.scratch (fixture_id, key, value)';
  v_orphans int;
  v_headers int;
BEGIN
  SELECT scenario_sql INTO v_s FROM golden.fixtures WHERE fixture_id = 42;

  -- ⛔ THE REAL INVARIANT: every scratch INSERT header is immediately followed by SELECT or
  -- VALUES. A header followed by a comment or a DO block is the leg-118 defect, and it is a
  -- syntax error the moment the scenario runs.
  -- ⛔ Deliberately NOT a regex: the header contains parentheses, and escaping them by hand is
  -- how this guard failed on its first apply. Split on the literal header instead and inspect
  -- what each following fragment actually begins with - no escaping surface at all.
  SELECT count(*) INTO v_orphans
    FROM unnest(string_to_array(v_s, v_hdr)) WITH ORDINALITY AS f(frag, i)
   WHERE i > 1
     AND left(ltrim(f.frag, E' \t\r\n'), 6) NOT IN ('SELECT', 'VALUES');
  IF v_orphans <> 0 THEN
    RAISE EXCEPTION 'leg118b: % orphaned golden.scratch INSERT header(s) remain', v_orphans;
  END IF;

  v_headers := (length(v_s) - length(replace(v_s, v_hdr, ''))) / length(v_hdr);
  IF v_headers <> 8 THEN
    RAISE EXCEPTION 'leg118b: expected 8 scratch INSERT headers (indep/pop/breach/plant/out/out_again/out_limit3/mtv_after), found %', v_headers;
  END IF;

  -- leg 118's structural guarantees must all still hold after this edit
  IF position('$fx42plant$'   in v_s) = 0 THEN RAISE EXCEPTION 'leg118b: plant block lost';   END IF;
  IF position('$fx42restore$' in v_s) = 0 THEN RAISE EXCEPTION 'leg118b: restore block lost'; END IF;
  IF (length(v_s) - length(replace(v_s, '$fx42restore$', ''))) / length('$fx42restore$') <> 2 THEN
    RAISE EXCEPTION 'leg118b: restore block is not present exactly once';
  END IF;
  IF NOT (position('''pop''' in v_s) < position('$fx42plant$' in v_s)
          AND position('$fx42plant$' in v_s) < position('''breach''' in v_s)
          AND position('''breach''' in v_s) < position('FROM public.rank_machines_by_value_at_risk_v3(' in v_s)
          AND position('FROM public.rank_machines_by_value_at_risk_v3(' in v_s) < position('$fx42restore$' in v_s)) THEN
    RAISE EXCEPTION 'leg118b: pop/plant/breach/picker/restore order was disturbed';
  END IF;
  -- and mtv_after must still be written exactly once, AFTER the restore (seq 48, LAW 11 pin)
  IF (length(v_s) - length(replace(v_s, '''mtv_after''', ''))) / length('''mtv_after''') <> 1 THEN
    RAISE EXCEPTION 'leg118b: mtv_after is not written exactly once';
  END IF;
  IF NOT (position('$fx42restore$' in v_s) < position('''mtv_after''' in v_s)) THEN
    RAISE EXCEPTION 'leg118b: mtv_after is no longer written after the restore';
  END IF;
END
$guard118b$;
