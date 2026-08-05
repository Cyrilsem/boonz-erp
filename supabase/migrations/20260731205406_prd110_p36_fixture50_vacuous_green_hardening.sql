-- PRD-110 P3.6 — fixture 50 vacuous-green hardening.
-- The RED baseline exposed three assertions that PASSED because the composer did
-- not exist: seq 20 compared two NULLs and got "true"; seq 23 and 33 asked
-- whether a dropped shelf was absent from a row-set that was itself absent.
-- An assertion that is green before its engine is written tests nothing.
-- Each now returns the sentinel 'no_compose' when the composer never ran, so it
-- can only go green on real composed output.
-- ⛔ S-103: check_sql and expect are edited as a PAIR. expect is unchanged here
--    ('true' / 'absent'); only the no-compose path moves off those values.

UPDATE golden.assertions SET check_sql =
$c$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=50 AND key='c1')
         THEN 'no_compose'
         ELSE (( (SELECT value->>'run_id' FROM golden.scratch WHERE fixture_id=50 AND key='c1')
                 IS DISTINCT FROM
                 (SELECT value#>>'{}' FROM golden.scratch WHERE fixture_id=50 AND key='r1') ))::text
         END$c$
WHERE fixture_id=50 AND seq=20;

UPDATE golden.assertions SET check_sql =
$c$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=50 AND key='c1_rows')
         THEN 'no_compose'
         ELSE COALESCE((SELECT value->>'8539b03e-4628-4e26-bffe-6aa33c282b7a'
                          FROM golden.scratch WHERE fixture_id=50 AND key='c1_rows'), 'absent')
         END$c$
WHERE fixture_id=50 AND seq=23;

UPDATE golden.assertions SET check_sql =
$c$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=50 AND key='c2_rows')
         THEN 'no_compose'
         ELSE COALESCE((SELECT value->>'8539b03e-4628-4e26-bffe-6aa33c282b7a'
                          FROM golden.scratch WHERE fixture_id=50 AND key='c2_rows'), 'absent')
         END$c$
WHERE fixture_id=50 AND seq=33;
