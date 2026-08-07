-- PRD-110 leg 144 - D-44b: the two D-24 universals that D-44 deliberately breaks.
--
-- `20260807160000` shipped the picker change and restated seq 42 correctly, but it under-scoped
-- the D-24 ranking contract. Fixture 42 came back 82/84 and named both misses precisely:
--
--   seq 31  actual 2   - "every BREACHED machine ranks above every non-breached - 0 inversions".
--                        D-44 creates exactly K such inversions BY RULING. The 2 is not a defect,
--                        it is the reservation working: VOXMCC-1005-0201-B0 (931.72 AED) and
--                        VOXMCC-1011-0101-B0 (289.66 AED) now outrank breached NOVO-1023-0000-W0
--                        (0.00 AED). That is the D-44 ask, verbatim.
--   seq 35  actual 0   - MY OWN DEFECT, not a policy question: `20260807160000` rewrote the
--                        check_sql to return a COUNT but left expect_op/expect at eq/'true'.
--                        The assertion was comparing '0' to 'true' and could never have passed.
--
-- ⛔ THE LESSON, RECORDED BECAUSE IT WILL RECUR: S-103 says restate `expect` AND `description`
-- together. It needs a third clause - when a restatement changes the SHAPE of what check_sql
-- returns (boolean -> count), `expect_op`/`expect` must move WITH it. A restatement that changes
-- only the SQL and the prose leaves an assertion that cannot pass in either direction, and it
-- reads in the diff as a thoughtful rewrite.
--
-- ⭐ AND THE MISS WAS FOUND THE RIGHT WAY. seq 31 was not in the set `20260807160000` reasoned
-- about, because that set was built by grepping for `selection_reason` and reading the assertions
-- the D-44 prose named. seq 31 mentions neither. THE FIXTURE FOUND IT, which is what fixture-first
-- is for: the blast radius of a ranking change is every assertion about ORDER, not every assertion
-- that mentions the words in the ruling.

-- ⛔ NO EXPLICIT BEGIN/COMMIT - the shim wraps the body in one transaction (S-215).

-- ---------------------------------------------------------------------------------------------
-- GUARD 0: this migration only makes sense on top of the D-44 picker.
-- ---------------------------------------------------------------------------------------------
DO $g0$
DECLARE v_md5 text; v_k int;
BEGIN
  SELECT substr(md5(prosrc),1,8) INTO v_md5
    FROM pg_proc WHERE proname='rank_machines_by_value_at_risk_v3';
  IF v_md5 <> '754532ac' THEN
    RAISE EXCEPTION 'expected the D-44 picker 754532ac, found %', v_md5;
  END IF;
  SELECT var_money_reserved_slots INTO v_k FROM public.refill_policy_params LIMIT 1;
  IF v_k IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'expected K=2, found %', v_k;
  END IF;
END $g0$;

-- ---------------------------------------------------------------------------------------------
-- GUARD 1: seq 60 stays untouchable (the CS D-24 acceptance test).
-- ---------------------------------------------------------------------------------------------
DO $g1$
DECLARE v_md5 text;
BEGIN
  SELECT md5(check_sql || '|' || expect_op || '|' || expect) INTO v_md5
    FROM golden.assertions WHERE fixture_id=42 AND seq=60;
  IF v_md5 IS NULL THEN RAISE EXCEPTION 'fixture 42 seq 60 is MISSING'; END IF;
  PERFORM set_config('prd110.d44b_seq60_md5', v_md5, true);
END $g1$;

-- ---------------------------------------------------------------------------------------------
-- seq 31. RESTATED AS THE AMENDED UNIVERSAL, NOT SCOPED AWAY.
--
-- The naive fix would have been "assert the property over the non-reserved population only".
-- That is weaker than it looks: it would stop constraining the reserved machines entirely, so a
-- regression that reserved SIX machines, or reserved a machine ranked 40th, would pass.
--
-- The restatement below keeps the universal over ALL machines and names the single licensed
-- exception: a non-breached machine may outrank a breached one ONLY IF it holds a reserved money
-- slot. Every other inversion is still a defect. This is strictly stronger than the original on
-- the reserved rows and identical to it everywhere else.
-- ---------------------------------------------------------------------------------------------
UPDATE golden.assertions SET
  check_sql = $c31$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key='out') THEN 'NO_PICKER_OUTPUT' ELSE (SELECT count(*)::text FROM
    (SELECT (e->>'rank')::int rk, (e->>'cadence_floor_due')::boolean due,
            (e->'reasoning'->'money_reservation'->>'is_money_reserved')::boolean res
       FROM golden.scratch s, jsonb_array_elements(s.value) e
      WHERE s.fixture_id=42 AND s.key='out') a
    JOIN
    (SELECT (e->>'rank')::int rk, (e->>'cadence_floor_due')::boolean due,
            (e->'reasoning'->'money_reservation'->>'is_money_reserved')::boolean res
       FROM golden.scratch s, jsonb_array_elements(s.value) e
      WHERE s.fixture_id=42 AND s.key='out') b
    ON a.due AND NOT b.due AND a.rk > b.rk AND NOT b.res) END$c31$,
  description = 'THE BREACHED FLOOR IS STILL A FLOOR, WITH EXACTLY ONE LICENSED EXCEPTION: a '
             || 'non-breached machine may outrank a BREACHED one only if it holds a D-44 reserved '
             || 'money slot - 0 unlicensed inversions. ⛔ NOT scoped to the non-reserved '
             || 'population, deliberately: that weaker form would stop constraining the reserved '
             || 'rows and would pass a regression that reserved six machines or reserved a '
             || 'machine ranked 40th. The universal still covers every machine; only the '
             || 'exception is named. This assertion read 2 inversions the moment D-44 shipped, '
             || 'and those 2 were the ruling working (VOXMCC-1005 at 931.72 AED and VOXMCC-1011 '
             || 'at 289.66 AED jumping breached NOVO-1023 at 0.00 AED). S-103 restatement.'
WHERE fixture_id=42 AND seq=31;

-- ---------------------------------------------------------------------------------------------
-- seq 35. RE-POINTED AT THE CS PAIR IT WAS ALWAYS ABOUT.
--
-- `20260807160000` replaced this pair with a universal - but seq 31 is already the universal, so
-- that left the build with two copies of one claim and NO assertion on the specific pair D-24 and
-- D-44 were both argued over. This restores the pair and states what D-44 makes true of it:
-- M_TOP now outranks M_CAD, and it does so BECAUSE it holds a reserved slot, not by accident.
-- ⭐ `expect` stays 'true' - the shape of the claim is a boolean again, matching expect_op.
-- ---------------------------------------------------------------------------------------------
UPDATE golden.assertions SET
  check_sql = $c35$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key='out') THEN 'NO_PICKER_OUTPUT' ELSE (
    SELECT (m_top.rk < m_cad.rk AND m_top.res AND NOT m_cad.res)::text
      FROM (SELECT (e->>'rank')::int rk,
                   (e->'reasoning'->'money_reservation'->>'is_money_reserved')::boolean res
              FROM golden.scratch s, jsonb_array_elements(s.value) e
             WHERE s.fixture_id=42 AND s.key='out'
               AND e->>'machine_id'='148c4fcf-b794-43f0-a2a8-e6f17605b045') m_top,
           (SELECT (e->>'rank')::int rk,
                   (e->'reasoning'->'money_reservation'->>'is_money_reserved')::boolean res
              FROM golden.scratch s, jsonb_array_elements(s.value) e
             WHERE s.fixture_id=42 AND s.key='out'
               AND e->>'machine_id'='0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04') m_cad) END$c35$,
  description = 'CS D-44 ON THE EXACT PAIR D-24 WAS ARGUED OVER: M_TOP (VOXMCC-1005-0201-B0) now '
             || 'outranks M_CAD, AND it does so because it holds a reserved money slot while '
             || 'M_CAD does not. ⛔ THE POLARITY OF THIS ASSERTION IS INVERTED FROM ITS D-24 '
             || 'FORM ON PURPOSE - it used to assert M_CAD < M_TOP ("the breached floor beats '
             || 'money"), which CS overruled in D-44 for K=2 slots. The claim is not weakened: it '
             || 'now pins BOTH the new order AND its cause, so a run where M_TOP wins for any '
             || 'reason other than the reservation goes red. The general breached-beats-money '
             || 'contract lives on in seq 31. S-103 restatement.'
WHERE fixture_id=42 AND seq=35;

-- ---------------------------------------------------------------------------------------------
-- seq 85. D-44 ACTUALLY MOVED THE RANKING.
--
-- seqs 77-84 prove the reservation is well-formed; none of them proves it CHANGED anything. A
-- reservation that only ever lands on machines the D-24 order would have picked first is inert,
-- and every green above it would be green over a no-op.
--
-- ⚠️ THIS ASSERTION CAN LEGITIMATELY GO RED, and the response is to investigate the PLANT, not
-- the picker: it reads 0 on a day when every reserved machine is itself breached. That is a real
-- state, not a defect - but on this fixture the plant guarantees a non-empty breached set
-- (seq 71) and a non-empty reserved set (seq 82), so 0 here means the two sets have collapsed
-- into each other and the fixture is no longer exercising D-44 at all. Same contract as seq
-- 63/66/71: a non-vacuity assertion that demands an investigation rather than a re-baseline.
-- ---------------------------------------------------------------------------------------------
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(42, 85,
 'D-44 IS NOT A NO-OP: at least one BREACHED machine is outranked by a money-reserved '
 || 'non-breached one, i.e. the reservation actually re-ordered the day rather than blessing an '
 || 'order D-24 would have produced anyway. Read 2 at ship. ⛔ If this goes to 0, investigate the '
 || 'PLANT (have the reserved and breached sets collapsed into each other?), never the picker, '
 || 'and NEVER re-baseline it to 0 - that would make every D-44 green above it vacuous.',
 $c85$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key='out') THEN 'NO_PICKER_OUTPUT' ELSE (SELECT count(*)::text FROM
   (SELECT (e->>'rank')::int rk, (e->>'cadence_floor_due')::boolean due,
           (e->'reasoning'->'money_reservation'->>'is_money_reserved')::boolean res
      FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id=42 AND s.key='out') a
   JOIN
   (SELECT (e->>'rank')::int rk, (e->>'cadence_floor_due')::boolean due,
           (e->'reasoning'->'money_reservation'->>'is_money_reserved')::boolean res
      FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id=42 AND s.key='out') b
   ON a.due AND NOT b.due AND b.res AND a.rk > b.rk) END$c85$,
 'gt', '0', true, 'P3');

-- ---------------------------------------------------------------------------------------------
-- GUARD 2: every assertion's expect_op/expect must be SHAPE-COMPATIBLE with what its check_sql
-- returns. This is the defect this migration exists to fix, so it does not ship without a
-- tripwire: no assertion on fixture 42 may carry a boolean `expect` while its check_sql's
-- outermost projection is a `count(*)::text`.
-- ---------------------------------------------------------------------------------------------
DO $g2$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM golden.assertions
   WHERE fixture_id=42 AND enabled
     AND expect IN ('true','false')
     AND check_sql LIKE '%count(*)::text%';
  IF n > 0 THEN
    RAISE EXCEPTION 'SHAPE MISMATCH: % assertion(s) on fixture 42 compare a count to a boolean', n;
  END IF;
END $g2$;

-- ---------------------------------------------------------------------------------------------
-- GUARD 3: seq 60 unmoved.
-- ---------------------------------------------------------------------------------------------
DO $g3$
DECLARE v_before text; v_after text;
BEGIN
  v_before := current_setting('prd110.d44b_seq60_md5', true);
  SELECT md5(check_sql || '|' || expect_op || '|' || expect) INTO v_after
    FROM golden.assertions WHERE fixture_id=42 AND seq=60;
  IF v_before IS NULL OR v_after IS NULL OR v_before <> v_after THEN
    RAISE EXCEPTION 'seq 60 MOVED (before=%, after=%)', v_before, v_after;
  END IF;
END $g3$;

-- ---------------------------------------------------------------------------------------------
-- GUARD 4: +1 assertion, none dropped, and the picker body is untouched by THIS migration.
-- ---------------------------------------------------------------------------------------------
DO $g4$
DECLARE n int; v_md5 text;
BEGIN
  SELECT count(*) INTO n FROM golden.assertions WHERE fixture_id=42 AND enabled;
  IF n <> 85 THEN RAISE EXCEPTION 'fixture 42 enabled count is %, expected 85', n; END IF;
  SELECT substr(md5(prosrc),1,8) INTO v_md5
    FROM pg_proc WHERE proname='rank_machines_by_value_at_risk_v3';
  IF v_md5 <> '754532ac' THEN
    RAISE EXCEPTION 'this migration must not touch the picker (found %)', v_md5;
  END IF;
END $g4$;
