-- PRD-110 leg 175 · S-348 · fixture-first pins on the measurement writer's run selection
--
-- ⛔ THE DEFECT (LAW 1: this file is the fixture, and it lands BEFORE the fix).
--    refresh_engine_forecast_error_v3 chooses which v3 run to measure with:
--        ORDER BY sh.produced_at DESC, sh.run_id LIMIT 1
--    produced_at is the TRANSACTION clock, so every shadow run banked inside one
--    transaction carries the identical timestamp and the winner is decided by an
--    arbitrary UUID sort. Leg 174 caught it as a coin flip on fixture 37 seq 20
--    (six observations, four green, two red).
--
-- ⛔ THE CAUSE IS D-34, NOT THE RE-RUN. Leg 165/170 pointed the nightly runner at
--    run_pipeline_v3, and the pipeline banks TWO shadow runs per call:
--        engine_tag = 'engine_add_pod_v3'  -- the engine run   (32 lines on this fixture)
--        engine_tag = 'compose_v3'         -- the composed run ( 6 lines on this fixture)
--    Both land in the same transaction, so from D-34 onward EVERY night ties, and the
--    measurement subject is decided by a UUID. Leg 174's "inert on live data" probe was
--    true when it was taken and expires with the first post-D-34 nightly: the 2026-08-09
--    cron row still carries planned_run_id = NULL, i.e. it ran the pre-D-34 body.
--
-- ⛔ IT IS ALREADY WRONG SOMEWHERE. 2030-02-11 is measured today on a compose_v3 run
--    (4 series) while its engine run for the same instant carries 8. No assertion reads
--    that date's measurement, which is exactly why it went unnoticed.
--
-- ⭐ RED PROVEN DETERMINISTICALLY, NOT BY WAITING FOR THE COIN. A forced-rollback probe
--    landed one LATER compose-only run on 2030-02-07 and re-measured: the writer picked
--    the compose run and reported 4 series instead of 8, residue 0 rows. Seq 46 below is
--    that probe, moved into the fixture where it belongs.
--
-- ⭐ S-322: the assertion is right and the writer is wrong. Nothing here is loosened.

-- ---------------------------------------------------------------------------------
-- The scenario gains the re-compose probe. Fixture 31's forced-rollback idiom: the
-- measurement survives in a PL/pgSQL variable, the synthetic run does not.
-- ---------------------------------------------------------------------------------
UPDATE golden.fixtures
SET scenario_sql = scenario_sql || $append$

-- ---------------------------------------------------------------------------
-- (S-348) THE MEASUREMENT SUBJECT MUST SURVIVE A LATER COMPOSE RUN.
--     D-34 wired this runner to run_pipeline_v3, which banks an engine run AND a
--     composed run every night. The measurement writer must keep measuring the
--     ENGINE run -- that is what every historical date was measured on, and
--     changing the subject would silently re-base the WMAPE CS reads at cutover.
--     A composed run that lands later must never become the subject by default.
--     Forced-rollback probe (fixture 31's idiom): the verdict survives in a
--     variable, the synthetic run is rolled back and leaves nothing behind.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_new    uuid := gen_random_uuid();
  v_src    uuid;
  v_res    jsonb;
  v_pick   uuid;
  v_tag    text;
  v_series int;
  v_resid  int;
BEGIN
  IF to_regprocedure('public.refresh_engine_forecast_error_v3(date)') IS NULL THEN
    RETURN;
  END IF;

  SELECT run_id INTO v_src
    FROM public.pod_refills_shadow
   WHERE plan_date = DATE '2030-02-07' AND engine_tag = 'compose_v3'
   ORDER BY produced_at DESC, run_id
   LIMIT 1;
  IF v_src IS NULL THEN
    -- No composed run to clone means the pipeline did not compose this night; the
    -- probe has nothing to say and seq 45 is the sensor that catches that.
    RETURN;
  END IF;

  BEGIN
    INSERT INTO public.pod_refills_shadow
      (run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id, qty,
       current_stock, max_stock, days_cover, signal, velocity_instock, availability_basis)
    SELECT v_new, 'compose_v3', plan_date, machine_id, shelf_id, pod_product_id, qty,
           current_stock, max_stock, days_cover, signal, velocity_instock, availability_basis
      FROM public.pod_refills_shadow
     WHERE run_id = v_src;

    v_res    := public.refresh_engine_forecast_error_v3(DATE '2030-02-07');
    v_pick   := (v_res->>'v3_run_id')::uuid;
    v_series := (v_res->>'v3_series')::int;
    SELECT DISTINCT engine_tag INTO v_tag
      FROM public.pod_refills_shadow WHERE run_id = v_pick;

    RAISE EXCEPTION 'golden_fixture_37_s348_forced_rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'golden_fixture_37_s348_forced_rollback' THEN
      v_tag := 'PROPAGATED: ' || SQLERRM;
    END IF;
  END;

  SELECT count(*) INTO v_resid
    FROM public.pod_refills_shadow WHERE run_id = v_new;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (37, 's348_recompose', jsonb_build_object(
            'picked_tag',    v_tag,
            'picked_run',    v_pick,
            'v3_series',     v_series,
            'residue_rows',  v_resid));
END $do$;
$append$
WHERE fixture_id = 37;

-- ---------------------------------------------------------------------------------
-- The pins.
-- ---------------------------------------------------------------------------------
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(37, 44, 'S-348: the measured v3 subject is an ENGINE run. Every run_id this date''s v3 measurement rows point at must resolve to a pod_refills_shadow run tagged engine_add_pod_v3. Since D-34 the pipeline banks a compose_v3 run in the same transaction, tied to the microsecond, so "the most recent run" no longer identifies one run and a UUID sort decides which forecast CS is scored against.',
 'SELECT golden.probe_scalar(''SELECT count(*)::text FROM public.engine_forecast_error_v3 e WHERE e.plan_date = DATE ''''2030-02-07'''' AND e.engine_tag = ''''v3'''' AND NOT EXISTS (SELECT 1 FROM public.pod_refills_shadow s WHERE s.run_id = e.run_id AND s.engine_tag = ''''engine_add_pod_v3'''')'')',
 'eq', '0', true, 'P2'),

(37, 45, 'S-348 ANTI-VACUITY: seq 44 only has teeth if this date genuinely carries BOTH kinds of run tied at the same instant. Exactly the D-34 shape -- an engine run and a composed run banked by one pipeline call -- must be present at max(produced_at). If this ever reads 1 the pipeline stopped composing and seq 44 went vacuously green.',
 'SELECT golden.probe_scalar(''SELECT count(DISTINCT engine_tag)::text FROM public.pod_refills_shadow WHERE plan_date = DATE ''''2030-02-07'''' AND produced_at = (SELECT max(produced_at) FROM public.pod_refills_shadow WHERE plan_date = DATE ''''2030-02-07'''')'')',
 'eq', '2', true, 'P2'),

(37, 46, 'S-348 THE REAL-WORLD SHAPE, deterministic where seq 20 is a coin flip: a compose_v3 run that lands AFTER the engine run must not become the measurement subject. The scenario clones one, re-measures, reads the verdict, and rolls the clone back. Before the fix this reads compose_v3 and the date scores 4 series instead of 8.',
 'SELECT value->>''picked_tag'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''s348_recompose''',
 'eq', 'engine_add_pod_v3', true, 'P2'),

(37, 47, 'S-348 NO RESIDUE: the seq 46 probe is a forced rollback, so the synthetic compose run it plants must leave zero rows behind. pod_refills_shadow is append-only; a probe that pollutes it would corrupt every later measurement of this date.',
 'SELECT value->>''residue_rows'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''s348_recompose''',
 'eq', '0', true, 'P2');
