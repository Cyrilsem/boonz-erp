-- PRD-110 DR-1b · leg 161 · fixture 75 correction — the refusal probe was testing the wrong thing
--
-- Fixture 75 step (9) proved "the promotion refuses rather than publishing an empty plan" by
-- DELETEing the shadow run and re-promoting. `pod_refills_shadow` is append-only
-- (ADR-shadow-plan-tables §5.1) and its trigger refused the DELETE, so the scenario aborted and
-- every assertion in the fixture returned NULL.
--
-- ⭐ The guard was right and the probe was wrong. Deleting shadow evidence is not a shape that
--   can occur in production, so proving the refusal that way proved nothing anyone will hit.
--   The REAL shape is a plan_date that carries an authoritative machine and no v3 run at all —
--   exactly what happens if the flip lands between cron 45 and the next nightly build. The probe
--   now uses a second synthetic date and never mutates the shadow table.

UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
$OLD$    -- (9) ⭐ IT REFUSES rather than publishing an empty plan for a flipped cluster.
    DELETE FROM public.pod_refills_shadow WHERE run_id = v_run;
    BEGIN
      PERFORM public.promote_v3_shadow_to_live_v3(v_d);
      v_refuse := 'NONE';
    EXCEPTION WHEN OTHERS THEN v_refuse := 'RAISED'; END;$OLD$,
$NEW$    -- (9) ⭐ IT REFUSES rather than publishing an empty plan for a flipped cluster.
    --     ⛔ NOT by deleting the shadow run: pod_refills_shadow is append-only
    --     (ADR-shadow-plan-tables §5.1) and its trigger refuses, which aborts the whole
    --     scenario. A second synthetic date carries the same authoritative machine and NO
    --     shadow run at all — the shape that actually occurs when a flip lands between
    --     cron 45 and the next nightly build.
    INSERT INTO public.machines_to_visit (plan_date, machine_id, official_name, status, confirmed_at)
    VALUES (DATE '2030-05-22', v_novo, 'NOVO-1023-0000-W0', 'picked', now());
    BEGIN
      PERFORM public.promote_v3_shadow_to_live_v3(DATE '2030-05-22');
      v_refuse := 'NONE';
    EXCEPTION WHEN OTHERS THEN v_refuse := 'RAISED'; END;$NEW$)
 WHERE fixture_id = 75;

-- The residue half must now also account for the second date.
UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
$OLD2$  'mtv_2030_gone',  (SELECT count(*) FROM public.machines_to_visit  WHERE plan_date = DATE '2030-05-21'),$OLD2$,
$NEW2$  'mtv_2030_gone',  (SELECT count(*) FROM public.machines_to_visit
                             WHERE plan_date IN (DATE '2030-05-21', DATE '2030-05-22')),$NEW2$)
 WHERE fixture_id = 75;

DO $guard$
DECLARE v_s text;
BEGIN
  SELECT scenario_sql INTO v_s FROM golden.fixtures WHERE fixture_id = 75;

  IF position('DELETE FROM public.pod_refills_shadow' in v_s) > 0 THEN
    RAISE EXCEPTION 'fixture 75: the append-only-violating DELETE survived the correction';
  END IF;
  IF position('2030-05-22' in v_s) = 0 THEN
    RAISE EXCEPTION 'fixture 75: the second-date refusal probe did not land';
  END IF;
  -- ⛔ The residue assertion must hunt rows that CAN exist, or it passes vacuously forever
  --    (the leg-160 lesson: a row-marker and its residue proof move TOGETHER).
  IF position('2030-05-22'')' in v_s) = 0 AND position('DATE ''2030-05-22'')' in v_s) = 0 THEN
    RAISE EXCEPTION 'fixture 75: residue check does not cover the second date';
  END IF;
  RAISE NOTICE 'fixture 75: refusal probe re-shaped, residue widened to both dates';
END $guard$;
