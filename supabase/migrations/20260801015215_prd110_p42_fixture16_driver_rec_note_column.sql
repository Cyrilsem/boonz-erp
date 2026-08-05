-- PRD-110 P4.2 — fixture 16 correction: driver_recommendations.note, not .notes.
--
-- Caught by the fixture's OWN first run, which is the point of running it red before the
-- engine exists: the scenario aborted at seq 0 with 42703 and every assertion reported
-- empty, so the failure was legible immediately rather than hiding behind a plausible red.
--
-- ⛔ The column is `note` (singular). Everything else in the chain was verified live in the
--    same probe: the driver wrap fires (1 driver_recommendations row), the ledger row leaves
--    'open' on citation, the minted pin matches machine/shelf/product/kind/value/mode, and
--    fixture 17's two-kind perpetual pair reports mode=perpetual, is_time_boxed=false,
--    days_remaining=NULL.
--
-- Surgical replace + a guard that REFUSES to leave the fixture unpatched, because a silent
-- no-op UPDATE would leave the same red with a migration recorded as its fix.

SET LOCAL statement_timeout = '60s';

UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql, 'dr.notes LIKE', 'dr.note LIKE')
 WHERE fixture_id = 16;

DO $chk$
DECLARE v_bad int; v_good int;
BEGIN
  SELECT count(*) INTO v_bad  FROM golden.fixtures WHERE fixture_id = 16 AND scenario_sql LIKE '%dr.notes %';
  SELECT count(*) INTO v_good FROM golden.fixtures WHERE fixture_id = 16 AND scenario_sql LIKE '%dr.note LIKE%';
  IF v_bad <> 0 OR v_good <> 1 THEN
    RAISE EXCEPTION 'fixture 16 patch did not apply (bad=% good=%)', v_bad, v_good;
  END IF;
END $chk$;
