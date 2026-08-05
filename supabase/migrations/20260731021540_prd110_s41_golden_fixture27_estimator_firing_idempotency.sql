-- PRD-110 · S-41/S-42 · leg 36 · FIXTURE FIRST (LAW 1)
--
-- Proves two defects in the P1.4 composition estimator, both root-caused to RISK 76
-- ("the estimator's idempotency marker is the EVENTS, so a flat shelf never skips"):
--
--   S-41  A flat shelf writes no event, so nothing marks the WEIMI snapshot as processed.
--         The whole loop body therefore re-runs on all 24 daily cron-44 firings.
--         Observed symptom: `count_above_capacity` anomalies re-raised per firing.
--         Measured live: snapshot 2026-07-30 22:00:40Z carries 20 rows over 5 shelves
--         (4 identical raises each), and `distinct (observed_qty, expected_qty)` = 1.
--
--   S-42  The loop tail SUBTRACTS `composition_decay_per_day x total_days_since_a_FIXED_anchor`
--         on every firing. That is cumulative/quadratic in time and wrong even at a
--         once-per-day cadence; combined with S-41 it runs 24x/day.
--         Lands 2026-07-31 18:40:00Z, when v_days first exceeds 1 on the burn-in machine.
--
-- THIS MIGRATION CHANGES NO BEHAVIOUR. It only adds fixture 27 and its assertions.
-- Expected on first run (the failing baseline, which is the point):
--   seq 6 = false (expect true) · seq 8 = 1 (expect 0) · seq 9 = 2 (expect 1)   -> 3 RED
--   every other seq green. If seq 6/8/9 are green BEFORE the fix, the fixture is not
--   measuring what it claims and must be rebuilt, not trusted.
--
-- NON-VACUITY IS EXPLICIT. seq 3 asserts the SECOND estimator call also did not skip, so
-- seq 6's confidence invariance can only come from a corrected decay anchor, never from the
-- call having been short-circuited. Without seq 3, a future "fix" that simply made the second
-- call skip would turn seq 6 green while leaving the 24x re-processing untouched.
--
-- RISK 80: golden.run_fixture provides NO rollback envelope, so every write here lives inside
-- an explicit rolled-back subtransaction and the measurements escape via the SQLERRM payload
-- trick (fixture 19's house pattern). seq 95/96/97 prove the rollback actually held.
-- LAW 12: no live plan table is touched; the fixture writes no plan rows at all.

BEGIN;

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, enabled, baseline_status, notes, scenario_sql)
VALUES (
  27,
  'Estimator firing idempotency',
  'S-41 / S-42 (leg 36, D-08 burn-in day 2)',
  'P1',
  '2030-01-26',
  true,
  'failing_expected',
  'Fixture 27 exists because fixture 22''s notes assert the OPPOSITE and are wrong: '
  '"The estimator can only run once per (shelf, WEIMI snapshot)". That premise is false for any '
  'shelf whose belief already equals its (clamped) count - it goes flat, writes no event, and the '
  'event-keyed idempotency guard therefore never fires. Measured on the D-08 burn-in machine: '
  'already_processed_skipped = 0 on a snapshot cron 44 had already processed four times. '
  'The fixture pins BOTH consequences: age decay must not compound across firings (S-42), and an '
  'anomaly must not be re-raised for an observation already recorded (S-41). '
  'Deterministic population: the flat sensor-lie shelves on MPMCC-1058 (current_stock > max_stock '
  'AND believed = clamped count), lowest shelf_id chosen. If that population ever empties the '
  'scenario RAISEs rather than passing vacuously.',
$sql$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'before', jsonb_build_object(
  'ev',   (SELECT count(*) FROM public.inventory_events),
  'comp', (SELECT count(*) FROM public.shelf_composition),
  'anom', (SELECT count(*) FROM public.inventory_anomalies));
DO $fx27$
DECLARE
  v_shelf   uuid;
  v_snap    timestamptz;
  v_payload jsonb;
  v_r1 jsonb; v_r2 jsonb;
  v_c1 numeric; v_c2 numeric;
  v_n0 bigint; v_nA bigint; v_nB bigint; v_nC bigint; v_nD bigint;
BEGIN
  -- Deterministic pick: flat + sensor-lie, lowest shelf_id, on the D-08 burn-in machine.
  SELECT ss.shelf_id INTO v_shelf
    FROM public.v_shelf_state ss
   WHERE ss.machine_id = '9acce2bf-0e65-48f4-bf44-cefa0326f2c5'
     AND ss.pod_product_id IS NOT NULL
     AND ss.current_stock > ss.max_stock
     AND LEAST(ss.current_stock, ss.max_stock)
         = (SELECT COALESCE(sum(sc.est_qty),0) FROM public.shelf_composition sc
             WHERE sc.shelf_id = ss.shelf_id)
   ORDER BY ss.shelf_id
   LIMIT 1;

  IF v_shelf IS NULL THEN
    RAISE EXCEPTION 'fixture 27 premise gone: no flat sensor-lie shelf on the burn-in machine. '
      'Re-derive the population before trusting any result from this fixture.';
  END IF;

  BEGIN
    -- ARRANGE: confidence 1.00 and EVERY decay anchor exactly 3 days old, so the expected
    -- decay is composition_decay_per_day x 3 = 0.06 regardless of which anchor the
    -- implementation reads. The fixture must not encode the fix's internal choice.
    UPDATE public.shelf_composition
       SET confidence        = 1.00,
           last_verified_at  = now() - interval '3 days',
           updated_at        = now() - interval '3 days',
           created_at        = now() - interval '3 days'
     WHERE shelf_id = v_shelf;

    v_n0 := (SELECT count(*) FROM public.inventory_anomalies);

    v_r1 := public.estimate_shelf_composition_v3(v_shelf, false);
    SELECT round(min(sc.confidence), 2) INTO v_c1
      FROM public.shelf_composition sc WHERE sc.shelf_id = v_shelf;
    v_nA := (SELECT count(*) FROM public.inventory_anomalies);

    -- Second firing, same WEIMI snapshot. This is exactly what cron 44 does 24x/day.
    v_r2 := public.estimate_shelf_composition_v3(v_shelf, false);
    SELECT round(min(sc.confidence), 2) INTO v_c2
      FROM public.shelf_composition sc WHERE sc.shelf_id = v_shelf;
    v_nB := (SELECT count(*) FROM public.inventory_anomalies);

    -- Synthetic dedupe probe on the raiser itself: identical (shelf, kind, snapshot) twice.
    v_snap := timestamptz '2030-01-26 00:00:00+00';
    PERFORM public.raise_inventory_anomaly_v3(v_shelf,'count_above_capacity',99,1,NULL,v_snap,
              jsonb_build_object('note','golden fixture 27 duplicate-key probe'));
    PERFORM public.raise_inventory_anomaly_v3(v_shelf,'count_above_capacity',99,1,NULL,v_snap,
              jsonb_build_object('note','golden fixture 27 duplicate-key probe'));
    v_nC := (SELECT count(*) FROM public.inventory_anomalies);

    -- OVER-DEDUP GUARD: a genuinely different observation must still be recorded.
    PERFORM public.raise_inventory_anomaly_v3(v_shelf,'count_above_capacity',99,1,NULL,
              v_snap + interval '1 hour',
              jsonb_build_object('note','golden fixture 27 new-observation probe'));
    v_nD := (SELECT count(*) FROM public.inventory_anomalies);

    v_payload := jsonb_build_object(
      'shelf',                  v_shelf::text,
      'examined',               v_r1->>'shelves_examined',
      'skipped',                v_r1->>'already_processed_skipped',
      'skipped_2',              v_r2->>'already_processed_skipped',
      'flat',                   v_r1->>'shelves_flat',
      'sensor',                 v_r1->>'sensor_above_capacity',
      'conf_after_1',           v_c1::text,
      'conf_after_2',           v_c2::text,
      'anom_from_call1',        (v_nA - v_n0)::text,
      'anom_from_call2',        (v_nB - v_nA)::text,
      'anom_dup_key_rows',      (v_nC - v_nB)::text,
      'anom_new_snapshot_rows', (v_nD - v_nC)::text);

    RAISE EXCEPTION 'GP27:%', v_payload::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'GP27:%' THEN v_payload := substring(SQLERRM from 'GP27:(.*)$')::jsonb; ELSE RAISE; END IF;
  END;

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES ({{fixture_id}}, 'obs', v_payload);
END
$fx27$;
$sql$
);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
 (27, 1, 'PREMISE: the estimator examined exactly the one shelf under test',
    $q$SELECT value->>'examined' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$,
    'eq', '1', true, 'P1'),

 (27, 2, 'PREMISE (S-41 mechanism): call 1 did NOT skip, even though cron 44 already processed this WEIMI snapshot - the event-keyed guard never fires on a flat shelf',
    $q$SELECT value->>'skipped' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$,
    'eq', '0', true, 'P1'),

 (27, 3, 'NON-VACUITY GUARD: call 2 did NOT skip either, so seq 6 measures the decay anchor and can never be satisfied by a short-circuit',
    $q$SELECT value->>'skipped_2' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$,
    'eq', '0', true, 'P1'),

 (27, 4, 'PREMISE: the shelf is FLAT (belief = clamped count), which is precisely why no event is written to mark the snapshot',
    $q$SELECT value->>'flat' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$,
    'eq', '1', true, 'P1'),

 (27, 5, 'S-42 MAGNITUDE: the first firing decays exactly composition_decay_per_day x elapsed_days, once (1.00 - 0.02x3 = 0.94)',
    $q$SELECT value->>'conf_after_1' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$,
    'eq', '0.94', true, 'P1'),

 (27, 6, 'S-41/S-42 PROOF: a SECOND firing on the same snapshot must not decay confidence again (RED before the fix: 0.88 vs 0.94)',
    $q$SELECT ((value->>'conf_after_2') = (value->>'conf_after_1'))::text FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$,
    'eq', 'true', true, 'P1'),

 (27, 7, 'PREMISE: call 1 raises the count_above_capacity anomaly exactly once - the anomaly itself is correct and must NOT be suppressed',
    $q$SELECT value->>'anom_from_call1' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$,
    'eq', '1', true, 'P1'),

 (27, 8, 'S-41 PROOF (in situ): call 2 must NOT re-raise the anomaly for an observation already recorded (RED before the fix: 1)',
    $q$SELECT value->>'anom_from_call2' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$,
    'eq', '0', true, 'P1'),

 (27, 9, 'S-41 PROOF (mechanism): raising an identical (shelf, kind, weimi_snapshot_at) twice inserts ONE row (RED before the fix: 2)',
    $q$SELECT value->>'anom_dup_key_rows' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$,
    'eq', '1', true, 'P1'),

 (27, 10, 'OVER-DEDUP GUARD: a genuinely NEW observation (different weimi_snapshot_at) is still recorded - the fix must dedupe, not silence',
    $q$SELECT value->>'anom_new_snapshot_rows' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$,
    'eq', '1', true, 'P1'),

 (27, 95, 'RESIDUE: inventory_events row count unchanged - the subtransaction rolled back',
    $q$SELECT ((SELECT count(*) FROM public.inventory_events) = (SELECT (value->>'ev')::bigint FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$q$,
    'eq', 'true', true, 'P1'),

 (27, 96, 'RESIDUE: shelf_composition row count unchanged (and the arrange UPDATE left no trace)',
    $q$SELECT ((SELECT count(*) FROM public.shelf_composition) = (SELECT (value->>'comp')::bigint FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$q$,
    'eq', 'true', true, 'P1'),

 (27, 97, 'RESIDUE: inventory_anomalies row count unchanged - none of the probe rows survived',
    $q$SELECT ((SELECT count(*) FROM public.inventory_anomalies) = (SELECT (value->>'anom')::bigint FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$q$,
    'eq', 'true', true, 'P1');

COMMIT;