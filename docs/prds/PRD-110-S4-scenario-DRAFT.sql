-- PRD-110 STEP 7 · S4 "pipeline chaos" — scenario DRAFT (leg 109)
--
-- ⛔ THIS IS A DRAFT. IT HAS **NOT** BEEN DRY-PROVEN.
-- Leg 107's fixture-9 equivalent carried the word DRYPROVEN because it had actually
-- been executed. This one has not: it was authored while S7 held the database, and
-- running it would have written to the very tables S7 was measuring for determinism.
-- The next leg MUST dry-test it (DO block alone, ending in RAISE EXCEPTION carrying
-- the payload — RAISE WARNING does not come back through the API) BEFORE shipping it
-- as a fixture. Treat every number below as a hypothesis.
--
-- GOAL (goal command STEP 7): "S4 pipeline chaos: re-run every engine 3x same date —
-- idempotent, no dup lines."
--
-- WHAT THE INVARIANT ACTUALLY IS (S-199, measured leg 109):
--   The shadow tables are run_id-keyed and engine_add_pod_v3 mints
--   `v_run_id := gen_random_uuid()` per call with NO delete and NO ON CONFLICT.
--   So three runs legitimately produce THREE generations. "Idempotent" therefore means
--   CONTENT equality per run_id — same inputs, same plan — NOT row-count stability.
--   Asserting "row count unchanged" would go RED against correct behaviour.
--
-- MANDATORY GUARDS BAKED IN BELOW:
--   * p_settle_limit => 0 — STEP 3 of run_nightly_shadow_v3 loops other dates
--     (WHERE plan_date <> v_pd); any other value makes S4 non-hermetic.
--   * non-vacuity — run 1 must produce > 0 lines, or three "no_picks" summaries are
--     trivially "identical" and S4 becomes S-132 all over again.
--   * clean-on-entry — the harness convention (fixture 105). pod_refills_shadow has no
--     delete of its own, so without this the run_id count grows every re-run.
--   * the ADR-shadow-plan-tables §8 obligation-3 tripwire: live pod_refills and
--     pod_refill_plan counts must not move at all (ABSOLUTE, not scoped to plan_date).

SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);

DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- Clean on entry (NOT on exit) — harness convention, and required here because
-- engine_add_pod_v3 never deletes its own prior generations.
DELETE FROM public.pod_refills_shadow      WHERE plan_date = {{plan_date}};
DELETE FROM public.pod_refill_plan_shadow  WHERE plan_date = {{plan_date}};
DELETE FROM public.shadow_runner_log_v3    WHERE plan_date = {{plan_date}};
DELETE FROM public.blocked_demand          WHERE plan_date = {{plan_date}};
DELETE FROM public.machines_to_visit       WHERE plan_date = {{plan_date}};

-- The ABSOLUTE live tripwire, captured before anything v3 runs.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'live_before', jsonb_build_object(
         'pod_refills',      (SELECT count(*) FROM public.pod_refills),
         'pod_refill_plan',  (SELECT count(*) FROM public.pod_refill_plan),
         'rpo',              (SELECT count(*) FROM public.refill_plan_output));

-- Plant picks so the engine has scope. Same three machines fixture 105 uses.
INSERT INTO public.machines_to_visit
 (plan_date, machine_id, official_name, status, add_source, is_included, service_track,
  picked_reasons, active_intent_count, is_ramping, priority_score, picked_at, picked_by,
  venue_group, location_type, confirmed_at, confirmed_by)
SELECT {{plan_date}}, machine_id, official_name, 'picked', 'operator', true,
       CASE WHEN venue_group='VOX' THEN 'vox' ELSE 'main' END,
       ARRAY['golden_fixture_{{fixture_id}}']::text[], 0, false, 100, now(),
       '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid, venue_group, location_type,
       now(), 'golden_fixture_{{fixture_id}}'
FROM public.machines
WHERE official_name IN ('MPMCC-1058-0000-R0','ACTIVATEMCC-1037-0000-L0','MPMCC-1054-0000-M0');

-- THE CHAOS: the one pipeline, three times, same date, settle disabled.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'run1', public.run_nightly_shadow_v3({{plan_date}}, 7, 0, 'S4 run 1');
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'run2', public.run_nightly_shadow_v3({{plan_date}}, 7, 0, 'S4 run 2');
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'run3', public.run_nightly_shadow_v3({{plan_date}}, 7, 0, 'S4 run 3');

-- Content fingerprint per generation. THIS is the idempotency evidence: three distinct
-- run_ids whose ordered plan projections hash identically.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'fingerprints', COALESCE(jsonb_agg(f ORDER BY f->>'seen_at'), '[]'::jsonb)
FROM (
  SELECT jsonb_build_object(
           'run_id',  s.run_id,
           'lines',   count(*),
           'units',   COALESCE(sum(s.qty), 0),
           'seen_at', min(s.created_at)::text,
           'md5',     md5(string_agg(
                        s.machine_id::text||'|'||s.shelf_id::text||'|'||
                        s.pod_product_id::text||'|'||COALESCE(s.qty,0)::text,
                        E'\n' ORDER BY s.machine_id, s.shelf_id, s.pod_product_id))
         ) AS f
  FROM public.pod_refills_shadow s
  WHERE s.plan_date = {{plan_date}}
  GROUP BY s.run_id
) t;

-- ============================ ASSERTIONS THE NEXT LEG SHOULD WRITE ============================
-- ⛔ seq 1 FIRST and it is the non-vacuity gate. Everything else is decoration without it.
--   1  lines in run 1 > 0
--        SELECT (value->0->>'lines')::int FROM golden.scratch
--         WHERE fixture_id={{fixture_id}} AND key='fingerprints'      gt 0
--   2  exactly 3 distinct run_ids for the date                        eq 3
--        SELECT count(DISTINCT run_id)::text FROM public.pod_refills_shadow
--         WHERE plan_date={{plan_date}}
--   3  exactly ONE distinct md5 across the three generations          eq 1
--        SELECT count(DISTINCT (f->>'md5'))::text FROM (SELECT jsonb_array_elements(value) f
--          FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='fingerprints') x
--   4  exactly ONE distinct line-count across generations             eq 1
--   5  all three summaries report status 'ok' (NOT 'no_picks')        eq 3
--        (count over golden.scratch keys run1..run3 where value->>'status'='ok')
--   6  no duplicate semantic key WITHIN a generation                  eq 0
--        SELECT count(*)::text FROM (SELECT run_id, machine_id, shelf_id, pod_product_id
--          FROM public.pod_refills_shadow WHERE plan_date={{plan_date}}
--          GROUP BY 1,2,3,4 HAVING count(*)>1) d
--   7  shadow_runner_log_v3 has exactly 3 'summary' rows              eq 3
--        (appends by design — scoped to the LOG, never called a dup)
--   8  live pod_refills count unmoved vs scratch.live_before          eq 0 (delta)
--   9  live pod_refill_plan count unmoved  (ADR §8 obl.3, ABSOLUTE)   eq 0 (delta)
--  10  live refill_plan_output count unmoved                          eq 0 (delta)
--  11  bypass_violation_log delta 0 — and per leg 108, ONLY meaningful
--        if app.via_trigger is NOT set during the runs. Clear it after the plant.
--
-- ⚠️ EXPECTED-RED RISK the next leg must resolve BEFORE trusting seq 3/4:
--   engine_add_pod_v3 sizing reads velocity/expiry/WH state that is LIVE and mutable.
--   Three runs inside ONE fixture transaction see one snapshot, so identical md5 is
--   expected. If S4 is ever split across transactions it may legitimately differ, and
--   THAT is a finding about input stability, not an engine bug. State which one you are
--   testing. This draft tests the single-transaction form.
