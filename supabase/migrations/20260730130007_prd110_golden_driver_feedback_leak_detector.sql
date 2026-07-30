-- PRD-110 harness safety - detect the engine's driver_feedback side effect leaking into live data.
-- Applied via Supabase MCP as `prd110_golden_driver_feedback_leak_detector` 2026-07-30.
--
-- THE LEAK. engine_add_pod's tail contains:
--
--   UPDATE public.driver_feedback df SET resolved = true, resolved_at = now(),
--          resolved_by_engine = 'engine_add_pod_v19_base_stock'
--    WHERE df.resolved = false
--      AND df.feedback_id IN (SELECT unnest(dfd.feedback_ids)
--            FROM public.v_driver_feedback_demand dfd
--            JOIN public.pod_refills pr ON pr.machine_id = dfd.machine_id
--                                     AND pr.pod_product_id = dfd.pod_product_id
--                                     AND pr.plan_date = p_plan_date AND pr.qty > 0);
--
-- The pod_refills join IS scoped to p_plan_date, but the driver_feedback match is on
-- (machine_id, pod_product_id) ONLY - feedback carries no plan_date. So any golden fixture that
-- plans a real machine on a synthetic 2030 date will resolve REAL, OPEN driver feedback for that
-- machine+pod, stamped as though the nightly engine had actioned it. A test run silently closing
-- a driver's open request is exactly the class of harm the harness exists to catch.
--
-- MEASURED, NOT ASSUMED: at the time of writing v_driver_feedback_demand returns 0 rows and 0
-- feedback rows were resolved on 2026-07-30, so the fixture runs so far did NO damage. The
-- exposure is latent, not historical: it arms itself the moment a driver files feedback on
-- MPMCC-1058, MPMCC-1054, ACTIVATEMCC-1037 or any machine a future fixture plans.
--
-- WHY A DETECTOR AND NOT A FIX, TODAY: the clean fix is inside engine_add_pod (scope the feedback
-- match to the plan being built), and the engine is frozen (WAVE1-2-UNBLOCK + LAW 3). The
-- alternative - having the harness snapshot and restore driver_feedback around each engine call -
-- means the test harness writing to live business data, which needs its own Dara/Cody pass. So
-- this migration installs the tripwire: both engine-calling fixtures now record the open-feedback
-- count before the engine runs and assert it is unchanged after. Under LAW 8 a red assertion
-- HALTS phase work, which is the correct response to a live-data leak. The engine-side fix is
-- parked in PARKING-LOT as the durable remedy.

-- Fixture 3: capture the pre-count. (Its scenario did not use scratch before; the DELETE keeps
-- re-runs clean.)
UPDATE golden.fixtures
   SET scenario_sql = $scenario$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'df_open_before',
       jsonb_build_object('n', (SELECT count(*) FROM public.driver_feedback WHERE resolved = false));
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
SELECT public.engine_add_pod({{plan_date}}, 7);
$scenario$
 WHERE fixture_id = 3;

-- Fixture 105: same capture, inserted before the engine call.
UPDATE golden.fixtures
   SET scenario_sql = replace(
         scenario_sql,
         'DELETE FROM public.blocked_demand   WHERE plan_date  = {{plan_date}};',
         'INSERT INTO golden.scratch (fixture_id, key, value)' || E'\n' ||
         'SELECT {{fixture_id}}, ''df_open_before'', jsonb_build_object(''n'', (SELECT count(*) FROM public.driver_feedback WHERE resolved = false));' || E'\n' ||
         'DELETE FROM public.blocked_demand   WHERE plan_date  = {{plan_date}};')
 WHERE fixture_id = 105
   AND scenario_sql NOT LIKE '%df_open_before%';

-- The tripwire itself, on both fixtures. seq 90 is reserved for harness-hygiene assertions so it
-- never collides with a fixture's own numbering.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required)
SELECT f.fixture_id, 90,
  'HARNESS SAFETY: the fixture resolved no live driver_feedback (engine tail leaks past the plan_date scope)',
  $sql$SELECT (SELECT count(*)::int FROM public.driver_feedback WHERE resolved = false)
            - (SELECT (value->>'n')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'df_open_before')$sql$,
  'eq', '0', 'P0'
  FROM golden.fixtures f WHERE f.fixture_id IN (3, 105)
ON CONFLICT (fixture_id, seq) DO UPDATE
  SET description = EXCLUDED.description,
      check_sql   = EXCLUDED.check_sql,
      expect_op   = EXCLUDED.expect_op,
      expect      = EXCLUDED.expect;
