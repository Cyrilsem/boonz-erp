-- PRD-110 S-46. Fixture 28 seq 3 claims a "symmetric EXCEPT, drift-proof" scope check. It is not
-- symmetric. In PostgreSQL, UNION and EXCEPT have EQUAL precedence and are LEFT-ASSOCIATIVE, so
--     (A EXCEPT B UNION ALL C EXCEPT D)   parses as   ((A EXCEPT B) UNION ALL C) EXCEPT D
-- With A=act, B=exp, C=exp, D=act that reduces to (act-exp) UNION exp, minus act - and every
-- element of (act-exp) is by definition in act, so the whole first branch is deleted again.
-- Net effect: a DROPPED machine is caught, an INVENTED one reports 0. Proven, not argued:
--     act=(1,2,99), exp=(1,2)  ->  unparenthesised 0, parenthesised 1.
--
-- This is a live hole in a P2 contract guard, so it is fixed rather than parked. Caught while
-- writing fixture 29, which was about to inherit the same shape by copying the house pattern.
--
-- L33-3 is honoured: the LIVE scenario_sql row is edited by a targeted replace. It is NOT rebuilt
-- from the migration file that created it, and the referenced-key-vs-written-key guard runs BEFORE
-- and AFTER. Fixture 28 is the ONLY fixture carrying this shape (all 13 scanned).

DO $mig$
DECLARE
  v_old  text;
  v_new  text;
  v_sql  text;
  v_hits integer;
BEGIN
  v_old := '    FROM (SELECT machine_id FROM fx28_act EXCEPT SELECT machine_id FROM fx28_exp' || E'\n'
        || '          UNION ALL' || E'\n'
        || '          SELECT machine_id FROM fx28_exp EXCEPT SELECT machine_id FROM fx28_act) q;';

  v_new := '    FROM ((SELECT machine_id FROM fx28_act EXCEPT SELECT machine_id FROM fx28_exp)' || E'\n'
        || '          UNION ALL' || E'\n'
        || '          (SELECT machine_id FROM fx28_exp EXCEPT SELECT machine_id FROM fx28_act)) q;';

  SELECT scenario_sql INTO v_sql FROM golden.fixtures WHERE fixture_id = 28;
  IF v_sql IS NULL THEN
    RAISE EXCEPTION 'S-46: fixture 28 not found';
  END IF;

  -- PRE-GUARD 1: the target text is present exactly once (never blind-replace a mutable row).
  v_hits := (length(v_sql) - length(replace(v_sql, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'S-46 pre-guard: expected exactly 1 occurrence of the unparenthesised scope check in fixture 28, found %', v_hits;
  END IF;

  -- PRE-GUARD 2: every scratch key the assertions read is written by the scenario.
  IF EXISTS (
    SELECT 1 FROM golden.assertions a
     WHERE a.fixture_id = 28
       AND a.check_sql LIKE '%key=%'
       AND position('''obs''' in a.check_sql) > 0
       AND position('''obs''' in v_sql) = 0)
  THEN
    RAISE EXCEPTION 'S-46 pre-guard: fixture 28 assertions reference a scratch key the scenario does not write';
  END IF;

  UPDATE golden.fixtures SET scenario_sql = replace(scenario_sql, v_old, v_new) WHERE fixture_id = 28;

  -- POST-GUARD: new form present, old form gone, scratch key still written.
  SELECT scenario_sql INTO v_sql FROM golden.fixtures WHERE fixture_id = 28;
  IF position(v_new in v_sql) = 0 THEN
    RAISE EXCEPTION 'S-46 post-guard: parenthesised scope check not present after UPDATE';
  END IF;
  IF position(v_old in v_sql) > 0 THEN
    RAISE EXCEPTION 'S-46 post-guard: unparenthesised form survived the UPDATE';
  END IF;
  IF position('''obs''' in v_sql) = 0 THEN
    RAISE EXCEPTION 'S-46 post-guard: scenario no longer writes the ''obs'' scratch key';
  END IF;
END
$mig$;

UPDATE golden.assertions
   SET description = 'SCOPE: exactly one row per in-scope pod-bound machine - none dropped, none invented. PARENTHESISED symmetric difference: the unparenthesised form is left-associative and silently reports 0 for an INVENTED row (S-46)'
 WHERE fixture_id = 28 AND seq = 3;
