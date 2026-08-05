-- PRD-110 P2.0b — Cody's load-bearing revision at the leg-24 review.
--
-- ADR §8 obligation 3 mandates a golden assertion that the LIVE plan is
-- unchanged across any v3 shadow run. seq 91 delivered that for exactly ONE
-- table: pod_refill_plan. But at the engine-advisory grain the tables that
-- matter are public.pod_refills (fixture 3 seq 1, fixture 14 seq 30/31/32 all
-- read it) and public.blocked_demand (fixture 105 seq 10 reads it) — and
-- blocked_demand was untripwired on EVERY Phase-2 fixture.
--
-- Without this, the new shadow's entire premise — "v3 does not touch live" —
-- is unproven for the two tables it was built to shadow. This must land BEFORE
-- engine_add_pod_v3 exists, because it is the tripwire that makes creating it safe.
--
-- Fixture 14 already carries the pod_refills half in the correct SCOPED form
-- (seq 93, leg 23: "wrote pod_refills on NO plan_date other than its own"),
-- because fixture 14 legitimately calls v19 and v19 legitimately writes that
-- table at the synthetic date. Fixture 2 is read-only and calls no engine, so
-- for it the stronger ABSOLUTE form is correct.
--
-- blocked_demand takes the ABSOLUTE form on both, and that is expected to stay
-- correct permanently: v3 writes pod_refills_shadow, and blocked demand in the
-- shadow world is a VIEW (v_blocked_demand_shadow_v3) which writes nothing at all.

-- 1. Stash the two new baselines. Each replace is fixture-scoped: fixture 14's
--    scenario also contains fixture 2's anchor string, so an unscoped replace
--    would double-apply. Verified by measurement before writing this.
UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
     '  ''prp'',     (SELECT count(*) FROM public.pod_refill_plan),',
     '  ''prp'',     (SELECT count(*) FROM public.pod_refill_plan),'||chr(10)||
     '  ''pr'',      (SELECT count(*) FROM public.pod_refills),'||chr(10)||
     '  ''bd'',      (SELECT count(*) FROM public.blocked_demand),')
 WHERE fixture_id = 2;

UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
     '  ''rpo'',     (SELECT count(*) FROM public.refill_plan_output));',
     '  ''rpo'',     (SELECT count(*) FROM public.refill_plan_output),'||chr(10)||
     '  ''bd'',      (SELECT count(*) FROM public.blocked_demand));')
 WHERE fixture_id = 14;

-- 2. The assertions. phase_required is inherited from each fixture's own seq 91
--    so the new tripwires run in exactly the phases the existing one does.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
SELECT 2, 92,
  'ADR 8.3 tripwire (extended, leg 24): pod_refills row count unchanged across this run — fixture 2 is read-only and calls no engine',
  'SELECT ((SELECT count(*) FROM public.pod_refills) = (SELECT (value->>''pr'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''before''))::text',
  'eq', 'true', true, a.phase_required
FROM golden.assertions a WHERE a.fixture_id = 2 AND a.seq = 91
ON CONFLICT (fixture_id, seq) DO NOTHING;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
SELECT 2, 93,
  'ADR 8.3 tripwire (extended, leg 24): blocked_demand row count unchanged across this run — the live ledger is never written by a shadow run',
  'SELECT ((SELECT count(*) FROM public.blocked_demand) = (SELECT (value->>''bd'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''before''))::text',
  'eq', 'true', true, a.phase_required
FROM golden.assertions a WHERE a.fixture_id = 2 AND a.seq = 91
ON CONFLICT (fixture_id, seq) DO NOTHING;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
SELECT 14, 97,
  'ADR 8.3 tripwire (extended, leg 24): blocked_demand row count unchanged across this run — v19 does not write it and v3 must not either (shadow blocked demand is a VIEW)',
  'SELECT ((SELECT count(*) FROM public.blocked_demand) = (SELECT (value->>''bd'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''before''))::text',
  'eq', 'true', true, a.phase_required
FROM golden.assertions a WHERE a.fixture_id = 14 AND a.seq = 91
ON CONFLICT (fixture_id, seq) DO NOTHING;

-- 3. Record on the fixtures themselves why the two forms differ, so a bisecting
--    leg reads the reasoning where it will actually look for it.
UPDATE golden.fixtures
   SET notes = COALESCE(notes,'') || chr(10) ||
     '[leg 24] ADR 8.3 tripwire extended from 1 live table to 3. pod_refill_plan (seq 91) and, '||
     'here, pod_refills + blocked_demand. ABSOLUTE counts are correct for fixture 2 because it is '||
     'read-only and calls no engine. Fixture 14 uses the SCOPED form for pod_refills (seq 93) '||
     'because it legitimately calls v19, which legitimately writes that table at the synthetic '||
     'plan_date; only blocked_demand takes the absolute form there. Do not "simplify" the two '||
     'into one shape — the difference is the point.'
 WHERE fixture_id IN (2,14);
