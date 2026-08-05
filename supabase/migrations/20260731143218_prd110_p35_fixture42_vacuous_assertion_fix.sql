-- PRD-110 P3.5 · fixture-42 corrective: eleven assertions passed VACUOUSLY in the RED baseline.
--
-- ⛔ WHAT THE RED EXPOSED (39 pass / 12 fail, and the wrong 39). Assertions of the shape
--     SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
--      WHERE s.fixture_id=42 AND s.key='out' AND <violation predicate>
-- count VIOLATIONS and expect 0. With rank_machines_by_value_at_risk_v3 absent, the 'out'
-- scratch row is never written, the FROM clause yields no rows, count(*) is 0, and the
-- assertion reports PASS. Seq 27 - labelled "THE SPINE" - passed against a function that did
-- not exist. So did 28, 29, 31, 32, 37, 38, 41, 42, 43 and 45.
--
-- ⚠️ THIS IS A GENERAL TRAP, NOT A TYPO (S-70). Every "0 violations" assertion is vacuously
-- true over an empty input, so a violation-counting assertion silently stops testing anything
-- the moment its subject is missing. It is invisible in a GREEN run - only the RED baseline
-- ever shows it, and only if you read WHICH assertions passed rather than how many.
--
-- THE FIX: make absence of output a distinct, failing value rather than zero violations.
-- Wrapping (rather than rewriting) each body keeps the eleven assertions byte-identical in
-- meaning when output IS present, so this corrective cannot quietly weaken any of them.

UPDATE golden.assertions a
SET check_sql =
  'SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key=''out'')'
  || ' THEN ''NO_PICKER_OUTPUT'' ELSE (' || a.check_sql || ') END'
WHERE a.fixture_id = 42
  AND a.seq IN (27, 28, 29, 31, 32, 37, 38, 41, 42, 43, 45);

-- Assertions 30, 33, 34, 35, 44, 46, 47 and 51 already returned NULL on absent output and
-- already failed the RED correctly; 25, 26, 36, 39 and 40 use gte/gt/eq against a positive
-- expectation and also failed correctly. They are deliberately left untouched.
