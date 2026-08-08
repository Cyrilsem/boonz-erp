-- PRD-110 leg 159 · S-304 · fixture 37 gains the two nights that prove it (LAW 1: FIXTURE FIRST).
-- These assertions are expected to land RED. The red IS the proof:
--   * seq 35 reds because engine_add_pod_v3 excludes a picked machine whose LIVE plan is
--     already approved, so the shadow engine plans nothing on any night CS approves before
--     cron 45 fires at 21:22 UTC (2026-08-07: approved 20:54:13, v3 planned 0, log said 'ok').
--   * seq 37/38 red because a zero-line run wears the same word ('ok') as a 112-line run.
-- The fixes ship as their own Cody-reviewed units immediately after this file.
-- No engine body, no runner body and no view is touched here.

DO $mig$
DECLARE
  v_old text;
  v_app text;
BEGIN
  SELECT scenario_sql INTO v_old FROM golden.fixtures WHERE fixture_id = 37;
  IF v_old IS NULL THEN
    RAISE EXCEPTION 'leg159 M1: fixture 37 not found';
  END IF;
  -- S-298 exact-once: refuse a second apply rather than append twice.
  IF position('golden_fixture_37_s304_approved' in v_old) > 0 THEN
    RAISE EXCEPTION 'leg159 M1: fixture 37 already carries the S-304 sections; refusing to append twice';
  END IF;
  -- Pre-image guard: refuse if the scenario drifted since it was diffed offline.
  IF md5(v_old) <> '152d92add347ac62dfc1ebb884e1f7f2' THEN
    RAISE EXCEPTION 'leg159 M1: fixture 37 scenario pre-image md5 is % (expected 152d92add347ac62dfc1ebb884e1f7f2)', md5(v_old);
  END IF;

  v_app := $s304$
-- ---------------------------------------------------------------------------
-- (5) S-304b · THE APPROVED-BLIND NIGHT (leg 159).
--     v19's own output must not delete v3's input. `engine_add_pod_v3` scopes
--     itself to picked machines that have NO approved refill_plan_output row
--     for the date. That predicate protects nothing here - the engine writes
--     exactly ONE table, public.pod_refills_shadow, and never a live plan
--     table - but it makes the shadow blind on every night the live plan is
--     approved before cron 45 fires at 21:22 UTC. On 2026-08-07 the live plan
--     was approved at 20:54:13 UTC, 28 minutes before the runner, and v3
--     planned NOTHING while the runner logged 'ok'. The single non-vacuous v3
--     date in the whole evidence base (2026-08-04) survives only because that
--     night's approval landed at 21:59, 37 minutes LATE.
--     LAW 12: synthetic 2030 plan_date, never a live one.
--     ⛔ The approve->dispatch trigger is AFTER UPDATE OF operator_status ONLY
--     (verified live, leg 159), so inserting a row that is BORN 'approved'
--     cannot fire a dispatch. Never UPDATE one into 'approved' from a fixture.
-- ---------------------------------------------------------------------------
DELETE FROM public.machines_to_visit  WHERE plan_date = DATE '2030-02-11';
DELETE FROM public.refill_plan_output WHERE plan_date = DATE '2030-02-11';

INSERT INTO public.machines_to_visit
 (plan_date, machine_id, official_name, status, add_source, is_included, service_track,
  picked_reasons, active_intent_count, is_ramping, priority_score, picked_at, picked_by,
  venue_group, location_type, confirmed_at, confirmed_by)
SELECT DATE '2030-02-11', machine_id, official_name, 'picked', 'operator', true, 'main',
       ARRAY['golden_fixture_37_s304_approved']::text[], 0, false, 100, now(),
       '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid, venue_group, location_type,
       now(), 'golden_fixture_37'
FROM public.machines
 WHERE official_name IN ('MPMCC-1058-0000-R0');

INSERT INTO public.refill_plan_output
 (plan_date, generated_at, machine_name, machine_id, shelf_code, pod_product_name,
  boonz_product_name, action, quantity, operator_status, reviewed_at, comment, source_origin)
SELECT DATE '2030-02-11', now(), m.official_name, m.machine_id, 'A01',
       'golden_fixture_37_s304', 'golden_fixture_37_s304', 'Refill', 1,
       'approved', now(), 'golden_fixture_37_s304', 'warehouse'
FROM public.machines m
 WHERE m.official_name = 'MPMCC-1058-0000-R0';

DO $do$
DECLARE v jsonb; n_before int; n_after int; n_rpo int; v_eng text; v_rows int;
BEGIN
  IF to_regprocedure('public.run_nightly_shadow_v3(date,integer,integer,text)') IS NULL THEN
    RETURN;
  END IF;
  -- pod_refills_shadow is APPEND-ONLY (BEFORE DELETE OR UPDATE guard), so the
  -- absolute count cannot be reset between runs. Measure the DELTA (leg 54).
  SELECT count(*) INTO n_before FROM public.pod_refills_shadow WHERE plan_date = DATE '2030-02-11';
  SELECT count(*) INTO n_rpo FROM public.refill_plan_output
   WHERE plan_date = DATE '2030-02-11' AND operator_status = 'approved';

  EXECUTE format('SELECT public.run_nightly_shadow_v3(%L::date, 7, 0, %L)',
                 DATE '2030-02-11', 'golden_fixture_37_approved') INTO v;

  SELECT count(*) INTO n_after FROM public.pod_refills_shadow WHERE plan_date = DATE '2030-02-11';
  SELECT l.status, COALESCE(l.rows_affected, -1) INTO v_eng, v_rows
    FROM public.shadow_runner_log_v3 l
   WHERE l.note = 'golden_fixture_37_approved' AND l.step = 'engine'
   ORDER BY l.id DESC LIMIT 1;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (37, 'approved_night', jsonb_build_object(
    'rpo_approved',   n_rpo,
    'shadow_before',  n_before,
    'shadow_after',   n_after,
    'shadow_delta',   n_after - n_before,
    'engine_status',  COALESCE(v_eng, 'NO_ENGINE_ROW'),
    'engine_rows',    COALESCE(v_rows, -1),
    'summary_status', COALESCE(v->>'status', 'NO_RETURN')));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (37, 'approved_night', jsonb_build_object('PROPAGATED', SQLERRM, 'sqlstate', SQLSTATE));
END $do$;

-- The synthetic approved row is a premise, not residue: it leaves with the fixture.
DELETE FROM public.refill_plan_output
 WHERE plan_date = DATE '2030-02-11' AND comment = 'golden_fixture_37_s304';

-- ---------------------------------------------------------------------------
-- (6) S-304a · THE HONEST EMPTY NIGHT (leg 159).
--     A run that banks ZERO lines must not wear the same word as a run that
--     banked 112. LVLUP-2015-0000-R0 is Active and carries NO pod-bearing
--     shelf, so the engine runs clean, raises nothing, and writes nothing -
--     the exact shape 2026-08-07 wore while the log said 'ok'.
-- ---------------------------------------------------------------------------
DELETE FROM public.machines_to_visit WHERE plan_date = DATE '2030-02-12';

INSERT INTO public.machines_to_visit
 (plan_date, machine_id, official_name, status, add_source, is_included, service_track,
  picked_reasons, active_intent_count, is_ramping, priority_score, picked_at, picked_by,
  venue_group, location_type, confirmed_at, confirmed_by)
SELECT DATE '2030-02-12', machine_id, official_name, 'picked', 'operator', true, 'main',
       ARRAY['golden_fixture_37_s304_empty']::text[], 0, false, 100, now(),
       '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid, venue_group, location_type,
       now(), 'golden_fixture_37'
FROM public.machines
 WHERE official_name IN ('LVLUP-2015-0000-R0');

DO $do$
DECLARE v jsonb; n_before int; n_after int; v_eng text; v_sum text; v_rows int;
BEGIN
  IF to_regprocedure('public.run_nightly_shadow_v3(date,integer,integer,text)') IS NULL THEN
    RETURN;
  END IF;
  SELECT count(*) INTO n_before FROM public.pod_refills_shadow WHERE plan_date = DATE '2030-02-12';

  EXECUTE format('SELECT public.run_nightly_shadow_v3(%L::date, 7, 0, %L)',
                 DATE '2030-02-12', 'golden_fixture_37_empty') INTO v;

  SELECT count(*) INTO n_after FROM public.pod_refills_shadow WHERE plan_date = DATE '2030-02-12';
  SELECT l.status, COALESCE(l.rows_affected, -1) INTO v_eng, v_rows
    FROM public.shadow_runner_log_v3 l
   WHERE l.note = 'golden_fixture_37_empty' AND l.step = 'engine'
   ORDER BY l.id DESC LIMIT 1;
  SELECT l.status INTO v_sum
    FROM public.shadow_runner_log_v3 l
   WHERE l.note = 'golden_fixture_37_empty' AND l.step = 'summary'
   ORDER BY l.id DESC LIMIT 1;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (37, 'empty_night', jsonb_build_object(
    'shadow_delta',   n_after - n_before,
    'engine_status',  COALESCE(v_eng, 'NO_ENGINE_ROW'),
    'engine_rows',    COALESCE(v_rows, -1),
    'summary_status', COALESCE(v_sum, 'NO_SUMMARY_ROW'),
    'returned_status',COALESCE(v->>'status', 'NO_RETURN')));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (37, 'empty_night', jsonb_build_object('PROPAGATED', SQLERRM, 'sqlstate', SQLSTATE));
END $do$;

-- The happy night is re-read AFTER both new nights so the honesty change is
-- proven not to have renamed a night that really did bank lines.
DO $do$
DECLARE v_eng text; v_rows int;
BEGIN
  SELECT l.status, COALESCE(l.rows_affected, -1) INTO v_eng, v_rows
    FROM public.shadow_runner_log_v3 l
   WHERE l.note = 'golden_fixture_37_happy' AND l.step = 'engine'
   ORDER BY l.id DESC LIMIT 1;
  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (37, 'happy_night', jsonb_build_object(
    'engine_status', COALESCE(v_eng, 'NO_ENGINE_ROW'),
    'engine_rows',   COALESCE(v_rows, -1)));
END $do$;
$s304$;

  UPDATE golden.fixtures SET scenario_sql = v_old || v_app WHERE fixture_id = 37;

  -- Post-image proofs: refuse a partial apply.
  IF (SELECT position('golden_fixture_37_s304_empty' in scenario_sql)
        FROM golden.fixtures WHERE fixture_id = 37) = 0 THEN
    RAISE EXCEPTION 'leg159 M1: post-image is missing the empty-night section';
  END IF;
  IF (SELECT length(scenario_sql) FROM golden.fixtures WHERE fixture_id = 37)
     <> length(v_old) + length(v_app) THEN
    RAISE EXCEPTION 'leg159 M1: post-image length is not old+append';
  END IF;
END $mig$;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
 (37, 31, 'Drift guard: the S-304 anchor 2030-02-11 is still a refill-planning day, so a blank night there means blindness and not the calendar',
  'SELECT golden.probe_scalar(''SELECT public.is_refill_planning_day_v3(DATE ''''2030-02-11'''')::text'')',
  'eq', 'true', true, 'P2'),
 (37, 32, 'Drift guard: 2030-02-12 is a refill-planning day too - the empty night is empty because the machine carries no pod shelf, not because the day was skipped',
  'SELECT golden.probe_scalar(''SELECT public.is_refill_planning_day_v3(DATE ''''2030-02-12'''')::text'')',
  'eq', 'true', true, 'P2'),
 (37, 33, 'S-304b PREMISE: the approved-blind night really did carry an approved LIVE plan row for the picked machine when the runner ran',
  'SELECT (value->>''rpo_approved'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''approved_night''',
  'eq', '1', true, 'P2'),
 (37, 34, 'S-304b PREMISE: that night did NOT propagate - the runner returned, so a blank result is a scoping answer and not a crash',
  'SELECT (NOT (value ? ''PROPAGATED''))::text FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''approved_night''',
  'eq', 'true', true, 'P2'),
 (37, 35, 'S-304b THE DEFECT: the shadow engine must PLAN a picked machine whose LIVE plan is already approved. v19 writes only refill_plan_output and v3 writes only pod_refills_shadow, so v19 own output must never delete v3 input',
  'SELECT (value->>''shadow_delta'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''approved_night''',
  'gt', '0', true, 'P2'),
 (37, 36, 'S-304a NON-VACUITY: the empty night really did bank zero lines, so seq 37 judges a genuinely blank run and not a busy one',
  'SELECT (value->>''shadow_delta'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''empty_night''',
  'eq', '0', true, 'P2'),
 (37, 37, 'S-304a THE DEFECT: a night that banks ZERO lines must not wear the same word as a night that banked 112. The engine step is named ok_no_shadow_rows',
  'SELECT (value->>''engine_status'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''empty_night''',
  'eq', 'ok_no_shadow_rows', true, 'P2'),
 (37, 38, 'S-304a: the summary carries the same name rather than flattening a blank night into ok, because the health view judges the SUMMARY (S-113)',
  'SELECT (value->>''summary_status'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''empty_night''',
  'eq', 'ok_no_shadow_rows', true, 'P2'),
 (37, 39, 'S-304a NON-VACUITY the other way: the happy night still reads ok - the honesty change renamed no night that really did bank lines',
  'SELECT (value->>''engine_status'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''happy_night''',
  'eq', 'ok', true, 'P2'),
 (37, 40, 'S-304a: and it banked them - the happy night engine step reports a positive line count, so seq 39 is not passing on an empty run',
  'SELECT (value->>''engine_rows'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''happy_night''',
  'gt', '0', true, 'P2');
