-- PRD-110 · S-41 · leg 36 · fixture 27 seq 7 restated: it measured cron timing, not the fix
--
-- WHAT WENT WRONG WITH seq 7, stated plainly so this is not mistaken for moving a goalpost.
--
-- As written, seq 7 asserted `anom_from_call1 = 1` - "the fixture's own first estimator call
-- inserted an anomaly row". That is only true if the fixture's call is the FIRST to record that
-- (shelf, kind, weimi_snapshot_at) observation. Live evidence says it is not:
--
--   shelf 06c84aca / count_above_capacity / snapshot 2026-07-30 22:00:40Z  ->  4 rows already
--
-- cron 44 recorded that observation four times before the fixture ever ran. So post-fix the
-- fixture's call correctly inserts NOTHING (actual 0), and seq 7 reds - not because the fix is
-- wrong, but because the assertion was measuring ambient cron state. Pre-fix it read 1 only
-- because the pre-fix raiser inserted unconditionally. Either reading is a coin flip on when
-- cron last fired. That is the S-32 class of defect (a fixture racing the live ingest), and an
-- assertion of that shape will red a future leg at random.
--
-- WHY NOT SIMPLY ASSERT "exactly one row on record for this observation"? Because 15 duplicate
-- rows from before the fix are deliberately NOT deleted (no-destructive rule, and they are the
-- evidence for S-41). Any assertion over that key is permanently red on historical residue.
--
-- THE RESTATEMENT keeps seq 7's original intent - "the dedupe must never suppress a FIRST report"
-- - and moves it onto a key the fixture fully controls (synthetic snapshot 2030-01-26, which no
-- WEIMI ingest can ever produce). It is therefore deterministic and residue-immune:
--
--   seq 7 (new): the FIRST raise of a genuinely new observation inserts exactly one row.
--
-- ⚠️ THIS ASSERTION IS GREEN BOTH BEFORE AND AFTER THE FIX, BY DESIGN. It is a GUARD against
--    over-dedup, not a proof of the fix. The proofs are seq 6, 8 and 9, all three of which were
--    RED on the recorded pre-fix baseline and are now green. Nothing that was red has been
--    weakened, retired, or re-expected - seq 7 is the one assertion this leg got wrong, and it
--    was never one of the three that proved the defect.
--
-- No behaviour change. Fixture rows only.

BEGIN;

UPDATE golden.fixtures SET
  baseline_status = 'passing',
  notes = notes || E'\n\n[leg 36 seq-7 restatement] seq 7 originally asserted that the fixture''s '
    'own estimator call inserted an anomaly row. That is ambient-dependent: cron 44 had already '
    'recorded the same (shelf, kind, snapshot) observation 4 times, so post-fix the call correctly '
    'inserts nothing. Restated onto the synthetic 2030-01-26 snapshot, which no ingest can produce, '
    'so it is deterministic and immune to the 15 pre-fix duplicate rows that are deliberately '
    'retained. seq 7 is a GUARD (green before and after); the PROOFS are seq 6, 8, 9.',
  scenario_sql = $sql$
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
  v_n0 bigint; v_nA bigint; v_nB bigint; v_nC1 bigint; v_nC bigint; v_nD bigint;
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
       SET confidence         = 1.00,
           last_verified_at   = now() - interval '3 days',
           updated_at         = now() - interval '3 days',
           created_at         = now() - interval '3 days',
           last_age_decay_at  = now() - interval '3 days'
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

    -- Synthetic key the fixture fully controls: no WEIMI ingest can ever produce a 2030 snapshot,
    -- so these probes are immune to both cron timing and the retained pre-fix duplicate rows.
    v_snap := timestamptz '2030-01-26 00:00:00+00';

    -- FIRST raise of a genuinely new observation MUST be recorded (seq 7 - over-dedup guard).
    PERFORM public.raise_inventory_anomaly_v3(v_shelf,'count_above_capacity',99,1,NULL,v_snap,
              jsonb_build_object('note','golden fixture 27 first-raise probe'));
    v_nC1 := (SELECT count(*) FROM public.inventory_anomalies);

    -- SECOND raise of the SAME observation must add nothing (seq 9).
    PERFORM public.raise_inventory_anomaly_v3(v_shelf,'count_above_capacity',99,1,NULL,v_snap,
              jsonb_build_object('note','golden fixture 27 duplicate-key probe'));
    v_nC := (SELECT count(*) FROM public.inventory_anomalies);

    -- A genuinely DIFFERENT observation must still be recorded (seq 10).
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
      'age_decayed_1',          v_r1->>'shelves_age_decayed',
      'age_decayed_2',          v_r2->>'shelves_age_decayed',
      'conf_after_1',           v_c1::text,
      'conf_after_2',           v_c2::text,
      'anom_from_call1',        (v_nA - v_n0)::text,
      'anom_from_call2',        (v_nB - v_nA)::text,
      'anom_first_raise_rows',  (v_nC1 - v_nB)::text,
      'anom_dup_key_rows',      (v_nC - v_nC1)::text,
      'anom_new_snapshot_rows', (v_nD - v_nC)::text);

    RAISE EXCEPTION 'GP27:%', v_payload::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'GP27:%' THEN v_payload := substring(SQLERRM from 'GP27:(.*)$')::jsonb; ELSE RAISE; END IF;
  END;

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES ({{fixture_id}}, 'obs', v_payload);
END
$fx27$;
$sql$
WHERE fixture_id = 27;

UPDATE golden.assertions SET
  description = 'OVER-DEDUP GUARD: the FIRST raise of a genuinely new observation inserts exactly one row - the dedupe must never suppress a first report (restated leg 36: the original asserted the fixture won a race against cron 44)',
  check_sql   = $q$SELECT value->>'anom_first_raise_rows' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$,
  expect_op   = 'eq',
  expect      = '1'
WHERE fixture_id = 27 AND seq = 7;

-- S-42 mechanism, now directly observable from the engine's own counter rather than inferred
-- from the confidence delta alone. Additive; both are green post-fix and seq 12 was RED pre-fix
-- (the pre-fix function had no such counter and decayed on every firing).
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
 (27, 11, 'S-42 MECHANISM: the first firing reports exactly one age decay applied',
    $q$SELECT value->>'age_decayed_1' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$,
    'eq', '1', true, 'P1'),
 (27, 12, 'S-42 MECHANISM: the second firing on the same day applies NO age decay - the anchor advanced',
    $q$SELECT value->>'age_decayed_2' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$,
    'eq', '0', true, 'P1');

COMMIT;