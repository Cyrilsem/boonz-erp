-- PRD-110 · S-47 follow-up · fixture 14 seq 91/92: align expect with the new COUNT form.
-- The previous migration re-expressed seq 91 and 92 from a boolean ("count = before.count") to a
-- COUNT of violating rows, but left expect_op/expect at their boolean values ('eq','true'), so both
-- compared '0' against 'true' and failed. seq 93 was already in count form ('eq','0') and was
-- unaffected. Caught by the suite on the very first run after apply, which is the harness working.
-- Forward-only correction (Article 12). Harness only.

DO $s47_fix$
DECLARE v_n int;
BEGIN
  -- PRE-GUARD: exactly the two mislabelled assertions, in exactly the state described above.
  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE fixture_id = 14 AND seq IN (91, 92)
     AND expect_op = 'eq' AND expect = 'true'
     AND check_sql LIKE '%written_by_this_txn%'
     AND check_sql LIKE '%count(*)::text%';
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'S-47 fix pre-guard: expected 2 count-form assertions still labelled eq/true, found %', v_n;
  END IF;

  UPDATE golden.assertions
     SET expect_op = 'eq', expect = '0'
   WHERE fixture_id = 14 AND seq IN (91, 92);

  -- POST-GUARD: all three tripwires now agree in shape, and the self-test is untouched.
  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE fixture_id = 14 AND seq IN (91, 92, 93)
     AND expect_op = 'eq' AND expect = '0' AND check_sql LIKE '%written_by_this_txn%';
  IF v_n <> 3 THEN
    RAISE EXCEPTION 'S-47 fix post-guard: expected 3 count-form tripwires at eq/0, found %', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE fixture_id = 14 AND seq = 100 AND expect_op = 'gt' AND expect = '0';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'S-47 fix post-guard: the seq-100 anti-vacuity self-test must remain gt/0, found %', v_n;
  END IF;
END $s47_fix$;
