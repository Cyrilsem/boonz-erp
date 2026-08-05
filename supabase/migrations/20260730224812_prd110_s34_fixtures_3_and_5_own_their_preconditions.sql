-- PRD-110 · S-34 · relay leg 28
-- Fixtures 3 and 5 OWN the shelf state they assert on.
--
-- R27-D6 measured five P0 assertions flipping red with no engine change, because the
-- production WEIMI ingest (~22:00:40 UTC) moved live fleet stock and both fixtures assert
-- on that stock through a live engine_add_pod call. Legs 7-26 all happened to run before
-- 22:00, which is the only reason "218 pass / 0 fail" ever looked like a stable baseline.
--
-- FIX (leg-27 precedent, golden.arrange_shelf): the fixture pins every shelf on its own
-- machines to empty, plans, and restores -- all inside the run's single transaction, so no
-- other session can observe the pin. An empty shelf is the one input state under which the
-- engine's behaviour is a pure function of slot_lifecycle coverage, which is what these
-- fixtures actually exist to prove.
--
-- Two assertions are additionally re-expressed because they asserted a NUMBER where the
-- invariant was the point (the S-04 house pattern; original text preserved in notes):
--   seq 5  ">= 9 lines"        -> "a line for EVERY shelf carrying a live WEIMI slot"
--   seq 12 "G2 fleet-wide = 0" -> "no shelf is PERMANENTLY blind" (see S-35: production
--          reopens the G2 gap nightly at 22:15 UTC and the canonical seeder closes it at
--          15:30 UTC, so an instantaneous fleet-wide 0 is not a property of a correct system)

-- ---------------------------------------------------------------------------------- fx 3
UPDATE golden.fixtures SET scenario_sql = $scn$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'df_open_before',
       jsonb_build_object('n', (SELECT count(*) FROM public.driver_feedback WHERE resolved = false));
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'weimi_fp_before',
       jsonb_build_object('fp', (SELECT md5(string_agg(si.shelf_code||':'||si.current_stock, ',' ORDER BY si.shelf_code))
                                   FROM public.v_shelf_slot_identity si
                                   JOIN public.shelf_configurations sc ON sc.shelf_id = si.shelf_id
                                   JOIN public.machines m ON m.machine_id = sc.machine_id
                                  WHERE m.official_name = 'MPMCC-1058-0000-R0' AND sc.is_phantom = false));
DELETE FROM public.machines_to_visit WHERE plan_date = {{plan_date}};
INSERT INTO public.machines_to_visit
 (plan_date, machine_id, official_name, status, add_source, is_included, service_track,
  picked_reasons, active_intent_count, is_ramping, priority_score, picked_at, picked_by,
  venue_group, location_type, confirmed_at, confirmed_by)
SELECT {{plan_date}}, machine_id, official_name, 'picked', 'operator', true,
       CASE WHEN venue_group='VOX' THEN 'vox' ELSE 'main' END,
       ARRAY['golden_fixture_3']::text[], 0, false, 100, now(),
       '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid, venue_group, location_type,
       now(), 'golden_fixture_3'
FROM public.machines WHERE official_name = 'MPMCC-1058-0000-R0';
DO $fx3$
DECLARE v_m uuid;
BEGIN
  SELECT machine_id INTO v_m FROM public.machines WHERE official_name = 'MPMCC-1058-0000-R0';
  -- S-34: own the precondition. Pin -> plan -> restore, same transaction (MVCC-invisible).
  PERFORM golden.pin_machine_stock(v_m, 0);
  PERFORM public.engine_add_pod({{plan_date}}, 7);
  PERFORM golden.restore_machine_stock(v_m);
END $fx3$;
$scn$
WHERE fixture_id = 3;

-- seq 5 -- re-expressed from a live-state COUNT to the coverage INVARIANT.
UPDATE golden.assertions SET
  description = 'Blindness is gone: with every shelf pinned empty, the engine emits a line for EVERY shelf carrying a live WEIMI slot (0 uncovered). Pre-P0.2 only 1 of MPMCC-1058''s 16 shelves had a slot_lifecycle row, so 15 were invisible and the engine emitted 0 lines.',
  check_sql = $q$
SELECT ((SELECT count(*) FROM public.shelf_configurations sc
           JOIN public.machines m ON m.machine_id = sc.machine_id
           JOIN public.v_shelf_slot_identity si ON si.shelf_id = sc.shelf_id
          WHERE m.official_name = 'MPMCC-1058-0000-R0' AND sc.is_phantom = false)
      - (SELECT count(DISTINCT pr.shelf_id) FROM public.pod_refills pr
           JOIN public.machines m ON m.machine_id = pr.machine_id
          WHERE pr.plan_date = {{plan_date}} AND m.official_name = 'MPMCC-1058-0000-R0'))::text
$q$,
  expect_op = 'eq', expect = '0'
WHERE fixture_id = 3 AND seq = 5;

-- seq 12 -- re-expressed: the durable invariant is that no shelf is PERMANENTLY blind.
UPDATE golden.assertions SET
  description = 'G2 fleet-wide (S-35): every in-scope shelf lacking a current slot_lifecycle row is CLAIMED by the canonical seeder, i.e. no shelf is permanently blind. An instantaneous fleet-wide 0 is NOT assertable: cron 7 (evaluate-lifecycle, 22:15 UTC) archives rotated shelves without provisioning a replacement, and cron 42 (seed_missing_slot_lifecycle, 15:30 UTC) closes the gap ~17h later.',
  check_sql = $q$
WITH claims AS MATERIALIZED (
  SELECT r.value->>'machine' AS machine_name, r.value->>'shelf_code' AS shelf_code
    FROM jsonb_array_elements((public.seed_missing_slot_lifecycle(true, NULL))->'rows') r
), offenders AS (
  SELECT s.machine_name, s.shelf_code
    FROM public.v_shelf_state s
   WHERE s.pod_product_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.slot_lifecycle sl
                      WHERE sl.shelf_id = s.shelf_id AND sl.archived = false AND sl.is_current = true)
)
SELECT count(*)::text FROM offenders o
 WHERE NOT EXISTS (SELECT 1 FROM claims c
                    WHERE c.machine_name = o.machine_name AND c.shelf_code = o.shelf_code)
$q$,
  expect_op = 'eq', expect = '0'
WHERE fixture_id = 3 AND seq = 12;

-- ---------------------------------------------------------------------------------- fx 5
UPDATE golden.fixtures SET scenario_sql = $scn$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'df_open_before',
       jsonb_build_object('n', (SELECT count(*) FROM public.driver_feedback WHERE resolved = false));
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'weimi_fp_before',
       jsonb_build_object('fp', (SELECT md5(string_agg(m.official_name||'/'||si.shelf_code||':'||si.current_stock, ',' ORDER BY m.official_name, si.shelf_code))
                                   FROM public.v_shelf_slot_identity si
                                   JOIN public.shelf_configurations sc ON sc.shelf_id = si.shelf_id
                                   JOIN public.machines m ON m.machine_id = sc.machine_id
                                  WHERE m.official_name IN ('VOXMCC-1005-0201-B0','ACTIVATE-2005-0000-W0','ACTIVATEMCC-1037-0000-L0')
                                    AND sc.is_phantom = false));
DELETE FROM public.machines_to_visit WHERE plan_date = {{plan_date}};
INSERT INTO public.machines_to_visit
 (plan_date, machine_id, official_name, status, add_source, is_included, service_track,
  picked_reasons, active_intent_count, is_ramping, priority_score, picked_at, picked_by,
  venue_group, location_type, confirmed_at, confirmed_by)
SELECT {{plan_date}}, machine_id, official_name, 'picked', 'operator', true,
       CASE WHEN venue_group='VOX' THEN 'vox' ELSE 'main' END,
       ARRAY['golden_fixture_5']::text[], 0, false, 100, now(),
       '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid, venue_group, location_type,
       now(), 'golden_fixture_5'
FROM public.machines
WHERE official_name IN ('VOXMCC-1005-0201-B0','ACTIVATE-2005-0000-W0','ACTIVATEMCC-1037-0000-L0');
DO $fx5$
DECLARE r record;
BEGIN
  -- S-34: own the precondition. Fade Fit shelves drift between at-capacity (no line) and
  -- sub-capacity-but-rounding-to-zero (S-05 silent drop); pinning them empty makes the
  -- venue-sourcing claim a function of sourcing, not of today's shelf level.
  FOR r IN SELECT machine_id FROM public.machines
            WHERE official_name IN ('VOXMCC-1005-0201-B0','ACTIVATE-2005-0000-W0','ACTIVATEMCC-1037-0000-L0')
  LOOP PERFORM golden.pin_machine_stock(r.machine_id, 0); END LOOP;

  PERFORM public.engine_add_pod({{plan_date}}, 7);
  PERFORM public.record_blocked_demand_v3({{plan_date}});

  FOR r IN SELECT machine_id FROM public.machines
            WHERE official_name IN ('VOXMCC-1005-0201-B0','ACTIVATE-2005-0000-W0','ACTIVATEMCC-1037-0000-L0')
  LOOP PERFORM golden.restore_machine_stock(r.machine_id); END LOOP;
END $fx5$;
$scn$
WHERE fixture_id = 5;

-- --------------------------------------------------------------- seq 94/95 pin tripwires
-- RISK 75: a fixture that mutates live state must PROVE it handed that state back.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
 (3, 94, 'HARNESS SAFETY (S-34): no WEIMI pin was left un-restored - golden.weimi_pin_backup is empty',
      $q$SELECT count(*)::text FROM golden.weimi_pin_backup$q$, 'eq', '0', true, 'P0'),
 (5, 94, 'HARNESS SAFETY (S-34): no WEIMI pin was left un-restored - golden.weimi_pin_backup is empty',
      $q$SELECT count(*)::text FROM golden.weimi_pin_backup$q$, 'eq', '0', true, 'P0'),
 (3, 95, 'HARNESS SAFETY (S-34): the machine''s live WEIMI stock fingerprint is byte-identical to the pre-pin capture',
      $q$
SELECT (CASE WHEN (SELECT md5(string_agg(si.shelf_code||':'||si.current_stock, ',' ORDER BY si.shelf_code))
                     FROM public.v_shelf_slot_identity si
                     JOIN public.shelf_configurations sc ON sc.shelf_id = si.shelf_id
                     JOIN public.machines m ON m.machine_id = sc.machine_id
                    WHERE m.official_name = 'MPMCC-1058-0000-R0' AND sc.is_phantom = false)
                = (SELECT value->>'fp' FROM golden.scratch
                    WHERE fixture_id = {{fixture_id}} AND key = 'weimi_fp_before')
          THEN 0 ELSE 1 END)::text
$q$, 'eq', '0', true, 'P0'),
 (5, 95, 'HARNESS SAFETY (S-34): all three machines'' live WEIMI stock fingerprints are byte-identical to the pre-pin capture',
      $q$
SELECT (CASE WHEN (SELECT md5(string_agg(m.official_name||'/'||si.shelf_code||':'||si.current_stock, ',' ORDER BY m.official_name, si.shelf_code))
                     FROM public.v_shelf_slot_identity si
                     JOIN public.shelf_configurations sc ON sc.shelf_id = si.shelf_id
                     JOIN public.machines m ON m.machine_id = sc.machine_id
                    WHERE m.official_name IN ('VOXMCC-1005-0201-B0','ACTIVATE-2005-0000-W0','ACTIVATEMCC-1037-0000-L0')
                      AND sc.is_phantom = false)
                = (SELECT value->>'fp' FROM golden.scratch
                    WHERE fixture_id = {{fixture_id}} AND key = 'weimi_fp_before')
          THEN 0 ELSE 1 END)::text
$q$, 'eq', '0', true, 'P0')
ON CONFLICT (fixture_id, seq) DO UPDATE
  SET description = EXCLUDED.description, check_sql = EXCLUDED.check_sql,
      expect_op = EXCLUDED.expect_op, expect = EXCLUDED.expect,
      enabled = EXCLUDED.enabled, phase_required = EXCLUDED.phase_required;

-- ------------------------------------------------- S-04 house pattern: preserve the text
UPDATE golden.fixtures SET notes = coalesce(notes,'') || E'\n\n'
  || '[leg 28 / S-34] SPEC CORRECTION. seq 5 originally read "Blindness is gone: engine emits '
  || '>= 9 lines (was 0 pre-P0.2; 9 = the sub-capacity shelf count)". That number tracked how '
  || 'full the machine was on the day it was written, not whether the machine was blind: the '
  || '2026-07-30 22:00:40 WEIMI ingest moved it to 8 and reddened a correct build. Measured at '
  || 'leg 28: 11 of 16 shelves sub-capacity, 8 lines, the 3 missing being S-05 silent drops '
  || '(A05 Krambals 5/6, A08 Skittles 8/10, A11 Be-kind 18/20). With every shelf pinned empty '
  || 'the engine emits 16 lines for 16 shelves and all 10 qty-0 lines carry a clamp_reason, so '
  || 'the coverage invariant is both stronger and anchor-independent. '
  || 'seq 12 originally asserted an instantaneous fleet-wide G2 = 0; see S-35.'
WHERE fixture_id = 3;

UPDATE golden.fixtures SET notes = coalesce(notes,'') || E'\n\n'
  || '[leg 28 / S-34] The scenario now pins all three machines empty before planning. seq 1/3/4 '
  || 'were unchanged - they were always the right assertions. They reddened at leg 27 close '
  || 'because VOXMCC-1005 A02 read 6/6 (at capacity, correctly no line) and A04 read 13/20 '
  || '(sub-capacity but dropped at 0.13/day, S-05). Pinned empty, the pair yields 4 Fade Fit '
  || 'lines, max qty 4, min wh_available_pod 3996, 0 blocked_no_wh, 0 blocked_demand.'
WHERE fixture_id = 5;
