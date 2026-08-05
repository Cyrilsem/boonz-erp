-- See prior migration for rationale. This retry fixes only the quote-depth arithmetic on
-- seq 21's concatenated probe: the fragment that injects the multi-shelf key needs 6 then 8
-- quotes (matching the form already proven in the baseline migration), not 8 then 10.
-- Both statements are re-verified by execution before COMMIT.

BEGIN;

UPDATE golden.assertions SET
  description = 'GRAIN: that collapsed row records n_shelves > 1, so the collapse is visible rather than silent',
  check_sql = 'SELECT golden.probe_scalar(''SELECT (n_shelves > 1)::text FROM public.engine_forecast_error_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''' AND machine_id::text||''''|''''||pod_product_id::text = '''''' || (SELECT value->>''multi_key'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''truth_real'') || '''''''')',
  expect_op = 'eq',
  expect = 'true'
WHERE fixture_id = 36 AND seq = 21;

UPDATE golden.assertions SET
  description = 'SYNTHETIC DATE: the GATE view returns UNKNOWN (NULL) on a vacuous date — never a verdict',
  check_sql = 'SELECT golden.probe_scalar(''SELECT COALESCE(v3_meets_gate::text, ''''unknown'''') FROM public.v_engine_wmape_v3_gate WHERE plan_date=DATE ''''2030-02-06'''''')',
  expect_op = 'eq',
  expect = 'unknown'
WHERE fixture_id = 36 AND seq = 28;

DO $$
DECLARE r record; v_out text; v_err int := 0; v_trap int := 0;
BEGIN
  FOR r IN SELECT seq, check_sql FROM golden.assertions WHERE fixture_id = 36 ORDER BY seq LOOP
    BEGIN
      EXECUTE golden.render(r.check_sql, 36) INTO v_out;
    EXCEPTION WHEN OTHERS THEN
      v_err := v_err + 1;
      RAISE WARNING 'fixture 36 seq % raises: %', r.seq, SQLERRM;
    END;
  END LOOP;

  SELECT count(*) INTO v_trap FROM golden.assertions
   WHERE fixture_id = 36 AND check_sql LIKE '%probe_scalar%'
     AND expect_op IN ('gt','gte','lt','lte');

  IF v_err  > 0 THEN RAISE EXCEPTION '% fixture-36 assertion(s) raise', v_err; END IF;
  IF v_trap > 0 THEN RAISE EXCEPTION '% fixture-36 assertion(s) order-compare a probe_scalar sentinel', v_trap; END IF;
END $$;

COMMIT;
