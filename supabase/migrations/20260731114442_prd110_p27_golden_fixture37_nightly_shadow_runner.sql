-- PRD-110 P2.7 · golden fixture 37 — nightly shadow runner: a failed or missing night is VISIBLE
-- LAW 1: this fixture is applied and run RED before any P2.7 object exists.
-- plan_date anchor = DATE '2030-01-01' + 37 = 2030-02-07 (free; 2030-02-06 is fixture 36).

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes,
   enabled, baseline_status)
VALUES (
  37,
  'Nightly shadow runner — a failed or MISSING night is visible (P2.7)',
  'PRD-110 D-12 runner: v3 had zero measurements on any real date, so the Phase-2 gate read no_v3_measurement forever.',
  'P2',
  DATE '2030-02-07',
$SCEN$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);

DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- Baseline FIRST, before this fixture writes anything. LAW 12 witness on the LIVE plan table.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'before', jsonb_build_object(
  't0',   clock_timestamp()::text,
  'prp',  (SELECT count(*) FROM public.pod_refills),
  'prps', (SELECT count(*) FROM public.pod_refills_shadow),
  'fce_real_settled', (SELECT count(*) FROM public.engine_forecast_error_v3
                        WHERE plan_date = DATE '2026-06-26' AND actuals_settled));

-- ---------------------------------------------------------------------------
-- (1) HAPPY NIGHT. Machines picked AND confirmed => Gate 0 satisfied.
-- ---------------------------------------------------------------------------
DELETE FROM public.machines_to_visit WHERE plan_date = {{plan_date}};
INSERT INTO public.machines_to_visit
 (plan_date, machine_id, official_name, status, add_source, is_included, service_track,
  picked_reasons, active_intent_count, is_ramping, priority_score, picked_at, picked_by,
  venue_group, location_type, confirmed_at, confirmed_by)
SELECT {{plan_date}}, machine_id, official_name, 'picked', 'operator', true,
       CASE WHEN venue_group='VOX' THEN 'vox' ELSE 'main' END,
       ARRAY['golden_fixture_37']::text[], 0, false, 100, now(),
       '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid, venue_group, location_type,
       now(), 'golden_fixture_37'
FROM public.machines
 WHERE official_name IN ('MPMCC-1058-0000-R0','AMZ-1046-2406-O1');

-- Guarded so a pre-existence baseline is a clean RED, never a scenario ERROR.
DO $do$
DECLARE v jsonb;
BEGIN
  IF to_regprocedure('public.run_nightly_shadow_v3(date,integer,integer,text)') IS NULL THEN
    RETURN;
  END IF;
  EXECUTE format('SELECT public.run_nightly_shadow_v3(%L::date, 7, 3, %L)',
                 DATE '2030-02-07', 'golden_fixture_37_happy') INTO v;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (37, 'runner_happy', v);
END $do$;

-- ---------------------------------------------------------------------------
-- (2) THE NORMAL REAL NIGHT under LAW 11: cron 13 picked, CS has NOT confirmed.
--     engine_add_pod_v3 -> _assert_gate_zero RAISES check_violation. The runner
--     must SURVIVE it, classify it as blocked_gate0 (not error), and stay visible.
--     Auto-confirming here would be exactly the auto-fallback LAW 11 forbids.
-- ---------------------------------------------------------------------------
DELETE FROM public.machines_to_visit WHERE plan_date = DATE '2030-02-08';
INSERT INTO public.machines_to_visit
 (plan_date, machine_id, official_name, status, add_source, is_included, service_track,
  picked_reasons, active_intent_count, is_ramping, priority_score, picked_at, picked_by,
  venue_group, location_type, confirmed_at, confirmed_by)
SELECT DATE '2030-02-08', machine_id, official_name, 'picked', 'operator', true, 'main',
       ARRAY['golden_fixture_37_unconfirmed']::text[], 0, false, 100, now(),
       '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid, venue_group, location_type,
       NULL, NULL
FROM public.machines
 WHERE official_name IN ('MPMCC-1058-0000-R0');

DO $do$
DECLARE v jsonb;
BEGIN
  IF to_regprocedure('public.run_nightly_shadow_v3(date,integer,integer,text)') IS NULL THEN
    RETURN;
  END IF;
  -- If this propagates instead of returning, the fixture fails on seq 11 by absence.
  EXECUTE format('SELECT public.run_nightly_shadow_v3(%L::date, 7, 3, %L)',
                 DATE '2030-02-08', 'golden_fixture_37_gate0') INTO v;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (37, 'runner_gate0', v);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (37, 'runner_gate0', jsonb_build_object('PROPAGATED', SQLERRM, 'sqlstate', SQLSTATE));
END $do$;

-- ---------------------------------------------------------------------------
-- (3) IDEMPOTENCE — a second happy run on the same date must not duplicate
--     measurement rows (refresh rebuilds the date wholesale).
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb; n1 int; n2 int;
BEGIN
  IF to_regprocedure('public.run_nightly_shadow_v3(date,integer,integer,text)') IS NULL THEN
    RETURN;
  END IF;
  SELECT count(*) INTO n1 FROM public.engine_forecast_error_v3 WHERE plan_date = DATE '2030-02-07';
  EXECUTE format('SELECT public.run_nightly_shadow_v3(%L::date, 7, 3, %L)',
                 DATE '2030-02-07', 'golden_fixture_37_rerun') INTO v;
  SELECT count(*) INTO n2 FROM public.engine_forecast_error_v3 WHERE plan_date = DATE '2030-02-07';
  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (37, 'idem', jsonb_build_object('fce_before', n1, 'fce_after', n2));
END $do$;

-- ---------------------------------------------------------------------------
-- (4) ABSENCE DETECTION — a DEAD SCHEDULE writes NOTHING, so the health view
--     must fire on the ABSENCE of rows, not on a bad row (the PRD-109 INV-10
--     lesson). Proven with fixture 31's forced-rollback probe idiom: the
--     measurement survives in a PL/pgSQL variable, the table is left untouched.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_empty text; v_fresh text; v_resid int;
BEGIN
  IF to_regclass('public.v_shadow_runner_health_v3') IS NULL THEN RETURN; END IF;

  SELECT is_healthy::text INTO v_fresh FROM public.v_shadow_runner_health_v3;

  BEGIN
    DELETE FROM public.shadow_runner_log_v3;
    SELECT is_healthy::text INTO v_empty FROM public.v_shadow_runner_health_v3;
    RAISE EXCEPTION 'golden_fixture_37_forced_rollback';
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- v_empty survives the rollback; the DELETE does not.
  END;

  SELECT count(*) INTO v_resid FROM public.shadow_runner_log_v3;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (37, 'health', jsonb_build_object(
    'fresh_is_healthy', v_fresh,
    'empty_is_healthy', v_empty,
    'residue_rows_after_rollback', v_resid));
END $do$;
$SCEN$,
  'P2.7 nightly shadow runner. Pins: gate0-blocked nights are visible-but-not-error; a dead schedule is caught by absence; the schedule collides with no other active cron; LAW 12 live plan untouched.',
  true,
  'unknown'
);

INSERT INTO golden.assertions
  (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(37, 1, 'Drift guard: {{plan_date}} still renders as the fixture-37 anchor 2030-02-07',
 'SELECT {{plan_date}}::text', 'eq', '2030-02-07', true, 'P2'),

(37, 2, 'OBJECT: the run log table exists',
 'SELECT golden.probe_scalar(''SELECT to_regclass(''''public.shadow_runner_log_v3'''')::text'')',
 'eq', 'shadow_runner_log_v3', true, 'P2'),

(37, 3, 'OBJECT: the runner RPC exists with the pinned signature',
 'SELECT golden.probe_scalar(''SELECT to_regprocedure(''''public.run_nightly_shadow_v3(date,integer,integer,text)'''')::text'')',
 'contains', 'run_nightly_shadow_v3', true, 'P2'),

(37, 4, 'OBJECT: the health view exists',
 'SELECT golden.probe_scalar(''SELECT to_regclass(''''public.v_shadow_runner_health_v3'''')::text'')',
 'eq', 'v_shadow_runner_health_v3', true, 'P2'),

(37, 5, 'NON-VACUITY: the happy run actually executed and reported its plan_date',
 'SELECT value->>''plan_date'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''runner_happy''',
 'eq', '2030-02-07', true, 'P2'),

(37, 6, 'HAPPY NIGHT: the engine step reports ok',
 'SELECT value->''engine''->>''status'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''runner_happy''',
 'eq', 'ok', true, 'P2'),

(37, 7, 'NON-VACUITY: the happy run wrote shadow rows (a runner that plans nothing proves nothing)',
 'SELECT golden.probe_scalar(''SELECT (count(*) > 0)::text FROM public.pod_refills_shadow WHERE plan_date = DATE ''''2030-02-07'''''')',
 'eq', 'true', true, 'P2'),

(37, 8, 'HAPPY NIGHT: the measure step reports ok',
 'SELECT value->''measure''->>''status'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''runner_happy''',
 'eq', 'ok', true, 'P2'),

(37, 9, 'NON-VACUITY: the measure step recorded at least one v3 series for the date',
 'SELECT golden.probe_scalar(''SELECT (count(*) > 0)::text FROM public.engine_forecast_error_v3 WHERE plan_date = DATE ''''2030-02-07'''' AND engine_tag = ''''v3'''''')',
 'eq', 'true', true, 'P2'),

(37, 10, 'RISK 102: a 2030 horizon cannot have elapsed, so every row is written UNSETTLED, never scored 0',
 'SELECT golden.probe_scalar(''SELECT count(*)::text FROM public.engine_forecast_error_v3 WHERE plan_date = DATE ''''2030-02-07'''' AND actuals_settled'')',
 'eq', '0', true, 'P2'),

(37, 11, 'FAILURE VISIBILITY: a Gate-0-blocked night RETURNS to the caller — it does not propagate',
 'SELECT (value ? ''PROPAGATED'')::text FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''runner_gate0''',
 'eq', 'false', true, 'P2'),

(37, 12, 'FAILURE VISIBILITY: the blocked night is classified blocked_gate0, NOT error and NOT ok',
 'SELECT value->''engine''->>''status'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''runner_gate0''',
 'eq', 'blocked_gate0', true, 'P2'),

(37, 13, 'FAILURE VISIBILITY: a durable log row exists for the blocked night',
 'SELECT golden.probe_scalar(''SELECT count(*)::text FROM public.shadow_runner_log_v3 WHERE note = ''''golden_fixture_37_gate0'''' AND step = ''''engine'''' AND status = ''''blocked_gate0'''''')',
 'eq', '1', true, 'P2'),

(37, 14, 'FAILURE VISIBILITY: that row carries the raising SQLSTATE (check_violation)',
 'SELECT golden.probe_scalar(''SELECT sqlstate FROM public.shadow_runner_log_v3 WHERE note = ''''golden_fixture_37_gate0'''' AND step = ''''engine'''' LIMIT 1'')',
 'eq', '23514', true, 'P2'),

(37, 15, 'FAILURE VISIBILITY: and the human-readable reason, so a night is diagnosable from the log alone',
 'SELECT golden.probe_scalar(''SELECT message FROM public.shadow_runner_log_v3 WHERE note = ''''golden_fixture_37_gate0'''' AND step = ''''engine'''' LIMIT 1'')',
 'contains', 'Gate 0', true, 'P2'),

(37, 16, 'LAW 5 / no silent qty-0: a blocked night wrote NO shadow rows for that date',
 'SELECT golden.probe_scalar(''SELECT count(*)::text FROM public.pod_refills_shadow WHERE plan_date = DATE ''''2030-02-08'''''')',
 'eq', '0', true, 'P2'),

(37, 17, 'ABSENCE DETECTION: with the log emptied, the health view reports UNHEALTHY (dead schedule)',
 'SELECT value->>''empty_is_healthy'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''health''',
 'eq', 'false', true, 'P2'),

(37, 18, 'ABSENCE DETECTION: and reports HEALTHY immediately after a good night',
 'SELECT value->>''fresh_is_healthy'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''health''',
 'eq', 'true', true, 'P2'),

(37, 19, 'The absence probe was NON-DESTRUCTIVE: its DELETE rolled back and the log survived intact',
 'SELECT (value->>''residue_rows_after_rollback'')::int > 0 FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''health''',
 'eq', 'true', true, 'P2'),

(37, 20, 'IDEMPOTENCE: a second run on the same date does not duplicate measurement rows',
 'SELECT ((value->>''fce_before'') = (value->>''fce_after''))::text FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''idem''',
 'eq', 'true', true, 'P2'),

(37, 21, 'GRAIN: no (plan_date,engine,machine,pod) key appears twice after repeated runs',
 'SELECT golden.probe_scalar(''SELECT (count(*) - count(DISTINCT (plan_date,engine_tag,machine_id,pod_product_id)))::text FROM public.engine_forecast_error_v3'')',
 'eq', '0', true, 'P2'),

(37, 22, 'SCHEDULE: exactly one ACTIVE cron runs the nightly shadow runner',
 'SELECT golden.probe_scalar(''SELECT count(*)::text FROM cron.job WHERE command ILIKE ''''%run_nightly_shadow_v3%'''' AND active'')',
 'eq', '1', true, 'P2'),

(37, 23, 'SCHEDULE: it collides with NO other active cron (same minute AND same hour field)',
 'SELECT golden.probe_scalar(''SELECT count(*)::text FROM cron.job a JOIN cron.job b ON b.jobid <> a.jobid AND b.active AND split_part(b.schedule, '''' '''', 1) = split_part(a.schedule, '''' '''', 1) AND split_part(b.schedule, '''' '''', 2) = split_part(a.schedule, '''' '''', 2) WHERE a.command ILIKE ''''%run_nightly_shadow_v3%'''' AND a.active'')',
 'eq', '0', true, 'P2'),

(37, 24, 'SETTLE-UP: the one real settled date (2026-06-26) is untouched by the runner',
 'SELECT golden.probe_scalar(''SELECT count(*)::text FROM public.engine_forecast_error_v3 WHERE plan_date = DATE ''''2026-06-26'''' AND actuals_settled'')',
 'eq', '141', true, 'P2'),

(37, 25, 'LAW 12: the LIVE plan table pod_refills is byte-untouched across the whole fixture',
 'SELECT (SELECT (value->>''prp'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''before'') = (SELECT count(*) FROM public.pod_refills)',
 'eq', 'true', true, 'P2'),

(37, 26, 'anon holds NO privilege on the run log table',
 'SELECT golden.probe_scalar(''SELECT count(*)::text FROM information_schema.role_table_grants WHERE grantee=''''anon'''' AND table_schema=''''public'''' AND table_name=''''shadow_runner_log_v3'''''')',
 'eq', '0', true, 'P2'),

(37, 27, 'anon holds NO privilege on the health view',
 'SELECT golden.probe_scalar(''SELECT count(*)::text FROM information_schema.role_table_grants WHERE grantee=''''anon'''' AND table_schema=''''public'''' AND table_name=''''v_shadow_runner_health_v3'''''')',
 'eq', '0', true, 'P2');
