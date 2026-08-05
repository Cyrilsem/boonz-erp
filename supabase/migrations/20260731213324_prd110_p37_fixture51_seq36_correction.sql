-- PRD-110 P3.7 — fixture 51, seq 36 correction (found by the BEHAVIOUR dry run).
-- ⛔ The assertion expected TWO persisted pipeline runs, but its probe is taken
--    immediately after the FIRST pipeline call -- the second has not run yet.
--    The engine was right and the assertion was wrong. Corrected to state what
--    that moment can actually prove: the receipt EXISTS, rather than having been
--    merely returned to the caller. The two-runs-per-date fact is already proven
--    at seq 44, where both runs exist.
-- 📌 S-103: an assertion edit is more than one field. Both `expect` and the
--    description move here, and the check_sql stays.

UPDATE golden.assertions
   SET expect = '1',
       description = 'the pipeline run is ON RECORD for the date, not merely returned to the caller'
 WHERE fixture_id = 51 AND seq = 36;
