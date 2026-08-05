-- golden.render() substitutes ONLY {{fixture_id}} and {{plan_date}}. The six assertions below
-- were written against an invented {{truth_real.*}} placeholder syntax that does not exist, so
-- their `expect` would have been compared as a literal string and could never pass — a fixture
-- that is RED for the wrong reason proves nothing.
--
-- Rewritten so check_sql performs the comparison itself and yields 'match'/'mismatch'. The
-- right-hand side is still the scenario's INDEPENDENT recomputation held in golden.scratch,
-- so no assertion compares the object against itself. Text equality (not ::numeric) is used
-- deliberately: at RED probe_scalar returns a 'MISSING: …' sentinel, and a numeric cast would
-- raise an ERROR instead of producing the clean FAILURE the RED baseline needs.

BEGIN;

UPDATE golden.assertions SET
  check_sql = 'SELECT CASE WHEN golden.probe_scalar(''SELECT count(*)::text FROM public.engine_forecast_error_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''''') IS NOT DISTINCT FROM (SELECT value->>''''n_series'''' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''''truth_real'''') THEN ''match'' ELSE ''mismatch'' END',
  expect = 'match'
WHERE fixture_id = 36 AND seq = 13;

UPDATE golden.assertions SET
  check_sql = 'SELECT CASE WHEN golden.probe_scalar(''SELECT round(sum(forecast_units),4)::text FROM public.engine_forecast_error_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''''') IS NOT DISTINCT FROM (SELECT value->>''''fc'''' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''''truth_real'''') THEN ''match'' ELSE ''mismatch'' END',
  expect = 'match'
WHERE fixture_id = 36 AND seq = 14;

UPDATE golden.assertions SET
  check_sql = 'SELECT CASE WHEN golden.probe_scalar(''SELECT round(sum(actual_units),4)::text FROM public.engine_forecast_error_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''''') IS NOT DISTINCT FROM (SELECT value->>''''act'''' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''''truth_real'''') THEN ''match'' ELSE ''mismatch'' END',
  expect = 'match'
WHERE fixture_id = 36 AND seq = 15;

UPDATE golden.assertions SET
  check_sql = 'SELECT CASE WHEN golden.probe_scalar(''SELECT round(sum(abs_error),4)::text FROM public.engine_forecast_error_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''''') IS NOT DISTINCT FROM (SELECT value->>''''abs_err'''' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''''truth_real'''') THEN ''match'' ELSE ''mismatch'' END',
  expect = 'match'
WHERE fixture_id = 36 AND seq = 16;

UPDATE golden.assertions SET
  check_sql = 'SELECT CASE WHEN golden.probe_scalar(''SELECT wmape::text FROM public.v_engine_wmape_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''''') IS NOT DISTINCT FROM (SELECT value->>''''wmape'''' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''''truth_real'''') THEN ''match'' ELSE ''mismatch'' END',
  expect = 'match'
WHERE fixture_id = 36 AND seq = 17;

UPDATE golden.assertions SET
  check_sql = 'SELECT CASE WHEN golden.probe_scalar(''SELECT count(*)::text FROM public.engine_forecast_error_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''''') IS NOT DISTINCT FROM (SELECT value->>''''n_series'''' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''''truth_real'''') THEN ''match'' ELSE ''mismatch'' END',
  expect = 'match'
WHERE fixture_id = 36 AND seq = 30;

DO $$
DECLARE v_bad int;
BEGIN
  SELECT count(*) INTO v_bad FROM golden.assertions
   WHERE fixture_id = 36 AND (check_sql LIKE '%{{truth_real%' OR expect LIKE '%{{truth_real%');
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'fixture 36 still carries % non-existent {{truth_real.*}} placeholder(s)', v_bad;
  END IF;
END $$;

COMMIT;
