-- PRD-110 leg 159 - S-304a second half - fixture 37 gains the is_measuring exercise (LAW 1).
-- Expected RED on seq 43: today `is_measuring` is satisfied by a WINDOW ("some real-date v3 row
-- within 8 days"), so a night that said 'ok' while measuring nothing still reads as measuring.
-- The fix ships in the next file.

DO $mig$
DECLARE
  v_old text;
  v_app text;
BEGIN
  SELECT scenario_sql INTO v_old FROM golden.fixtures WHERE fixture_id = 37;
  IF v_old IS NULL THEN
    RAISE EXCEPTION 'leg159 M4: fixture 37 not found';
  END IF;
  IF position('s304a_blind_night' in v_old) > 0 THEN
    RAISE EXCEPTION 'leg159 M4: fixture 37 already carries the is_measuring exercise';
  END IF;
  IF md5(v_old) <> 'd2547d37d920cf93dac81b687d0a205c' THEN
    RAISE EXCEPTION 'leg159 M4: fixture 37 pre-image md5 is % (expected d2547d37d920cf93dac81b687d0a205c)', md5(v_old);
  END IF;

  v_app := $s304m$
-- ---------------------------------------------------------------------------
-- (7) S-304a, second half · IS_MEASURING MUST NOT BE SATISFIED BY A STALE
--     MEASUREMENT. A window ("some v3 row in the last 8 days") keeps saying yes
--     for a week after the runner has gone blind - which is exactly the week
--     DR-1 would be judged in. The honest test is about the LAST SCHEDULED
--     NIGHT THAT SAID 'ok': did THAT night emit v3 series for its own
--     plan_date?
--     Exercised, not asserted from live state (S-301): a synthetic cron summary
--     for a plan_date with no v3 series is planted inside a forced-rollback
--     subtransaction, the view is read through it, and the row never commits.
--     2030-02-13 carries no engine_forecast_error_v3 row of any tag.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_meas_live  text;
  v_meas_blind text;
  v_v3_rows    int;
  v_resid      int;
BEGIN
  IF to_regclass('public.v_shadow_runner_health_v3') IS NULL THEN RETURN; END IF;

  SELECT count(*) INTO v_v3_rows FROM public.engine_forecast_error_v3
   WHERE plan_date = DATE '2030-02-13';

  SELECT is_measuring::text INTO v_meas_live FROM public.v_shadow_runner_health_v3;

  BEGIN
    -- The newest scheduled night, and it said 'ok' while measuring nothing.
    INSERT INTO public.shadow_runner_log_v3
      (run_started_at, plan_date, step, step_target, status, duration_ms, detail, note)
    VALUES (now() + interval '1 minute', DATE '2030-02-13', 'summary', DATE '2030-02-13',
            'ok', 1, jsonb_build_object('golden_fixture_37','s304a_blind_night'), 'cron');

    SELECT is_measuring::text INTO v_meas_blind FROM public.v_shadow_runner_health_v3;
    RAISE EXCEPTION 'golden_fixture_37_s304a_forced_rollback';
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- v_meas_blind survives the rollback; the planted row does not.
  END;

  SELECT count(*) INTO v_resid FROM public.shadow_runner_log_v3
   WHERE plan_date = DATE '2030-02-13' AND note = 'cron';

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (37, 's304a_measuring', jsonb_build_object(
    'v3_rows_for_planted_date',    v_v3_rows,
    'is_measuring_before',         COALESCE(v_meas_live,  'NULL'),
    'is_measuring_on_blind_night', COALESCE(v_meas_blind, 'NULL'),
    'residue_rows_after_rollback', v_resid));
END $do$;
$s304m$;

  UPDATE golden.fixtures SET scenario_sql = v_old || v_app WHERE fixture_id = 37;

  IF (SELECT length(scenario_sql) FROM golden.fixtures WHERE fixture_id = 37)
     <> length(v_old) + length(v_app) THEN
    RAISE EXCEPTION 'leg159 M4: post-image length is not old+append';
  END IF;
END $mig$;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
 (37, 41, 'S-304a PREMISE: the planted blind night names a plan_date that really has NO v3 measurement, so seq 43 judges blindness and not a measured night',
  'SELECT (value->>''v3_rows_for_planted_date'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''s304a_measuring''',
  'eq', '0', true, 'P2'),
 (37, 42, 'S-304a: the forced-rollback probe left NOTHING behind - the planted cron summary is a measurement, never a write',
  'SELECT (value->>''residue_rows_after_rollback'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''s304a_measuring''',
  'eq', '0', true, 'P2'),
 (37, 43, 'S-304a THE DEFECT: when the NEWEST scheduled night said ok while emitting no v3 series for its own plan_date, is_measuring must read FALSE. A window over older rows lets a stale measurement certify a blind week - the exact week DR-1 would be judged in',
  'SELECT (value->>''is_measuring_on_blind_night'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''s304a_measuring''',
  'eq', 'false', true, 'P2');
