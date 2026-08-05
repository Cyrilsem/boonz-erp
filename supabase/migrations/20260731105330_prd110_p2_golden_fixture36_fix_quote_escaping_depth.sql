-- Quote-escaping depth bug in fixture 36 seq 13-17 + 30.
--
-- A check_sql that calls golden.probe_scalar() has TWO nesting levels, and they need
-- DIFFERENT amounts of quote doubling:
--   * text INSIDE the probe_scalar argument  -> two levels ('''' in the migration)
--   * text in the OUTER check_sql itself     -> one level  (''   in the migration)
-- The outer golden.scratch lookups were given the inner treatment, so the stored SQL read
-- `value->>''n_series''` and died with "syntax error at or near ''". Six assertions failed as
-- ERRORS rather than as clean FAILUREs, which is exactly the RED-proves-nothing trap that
-- golden.probe_scalar was introduced to eliminate. Fixed, then verified by EXECUTION below.

BEGIN;

UPDATE golden.assertions SET
  check_sql = 'SELECT CASE WHEN golden.probe_scalar(''SELECT count(*)::text FROM public.engine_forecast_error_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''''') IS NOT DISTINCT FROM (SELECT value->>''n_series'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''truth_real'') THEN ''match'' ELSE ''mismatch'' END'
WHERE fixture_id = 36 AND seq IN (13, 30);

UPDATE golden.assertions SET
  check_sql = 'SELECT CASE WHEN golden.probe_scalar(''SELECT round(sum(forecast_units),4)::text FROM public.engine_forecast_error_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''''') IS NOT DISTINCT FROM (SELECT value->>''fc'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''truth_real'') THEN ''match'' ELSE ''mismatch'' END'
WHERE fixture_id = 36 AND seq = 14;

UPDATE golden.assertions SET
  check_sql = 'SELECT CASE WHEN golden.probe_scalar(''SELECT round(sum(actual_units),4)::text FROM public.engine_forecast_error_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''''') IS NOT DISTINCT FROM (SELECT value->>''act'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''truth_real'') THEN ''match'' ELSE ''mismatch'' END'
WHERE fixture_id = 36 AND seq = 15;

UPDATE golden.assertions SET
  check_sql = 'SELECT CASE WHEN golden.probe_scalar(''SELECT round(sum(abs_error),4)::text FROM public.engine_forecast_error_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''''') IS NOT DISTINCT FROM (SELECT value->>''abs_err'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''truth_real'') THEN ''match'' ELSE ''mismatch'' END'
WHERE fixture_id = 36 AND seq = 16;

UPDATE golden.assertions SET
  check_sql = 'SELECT CASE WHEN golden.probe_scalar(''SELECT wmape::text FROM public.v_engine_wmape_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''''') IS NOT DISTINCT FROM (SELECT value->>''wmape'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''truth_real'') THEN ''match'' ELSE ''mismatch'' END'
WHERE fixture_id = 36 AND seq = 17;

-- PROOF, not assumption: execute every fixture-36 check_sql exactly as the runner renders it.
-- Any assertion that raises is a broken assertion, whether or not its object exists yet —
-- probe_scalar guarantees a missing object yields a sentinel STRING, never an exception.
DO $$
DECLARE r record; v_out text; v_err int := 0;
BEGIN
  FOR r IN SELECT seq, check_sql FROM golden.assertions WHERE fixture_id = 36 ORDER BY seq LOOP
    BEGIN
      EXECUTE golden.render(r.check_sql, 36) INTO v_out;
    EXCEPTION WHEN OTHERS THEN
      v_err := v_err + 1;
      RAISE WARNING 'fixture 36 seq % still raises: %', r.seq, SQLERRM;
    END;
  END LOOP;
  IF v_err > 0 THEN
    RAISE EXCEPTION '% fixture-36 assertion(s) raise instead of returning a value', v_err;
  END IF;
END $$;

COMMIT;
