-- PRD-110 leg 98 · GOLDEN FIXTURE 63 — the SECOND preflight enforcement site.
--
-- D-19 says "FLIP TO BLOCK. The audited single-use override is the escape hatch."
-- Fixture 33 proves that story on public.commit_refill_plan. This fixture pins the
-- rest of the truth, because preflight_enforcement is a GLOBAL flag that arms two
-- more call paths that fixture 33 never touches:
--
--   1. public.stitch_pod_to_boonz          — called directly by the FE (RefillPlanningTab).
--   2. public.commit_refill_plan_atomic    — the FE's ONLY commit path, which calls
--                                            stitch_pod_to_boonz(plan_date, false) internally.
--
-- public.commit_refill_plan — the one fixture 33 proves — has NO caller in src/ at all.
--
-- The fixture seeds the same INV-06 conservation leak fixture 33 uses, on its own
-- synthetic 2030 plan_date, with parent rows left at status='stitched' so that
-- stitch_pod_to_boonz can NEVER actually execute: every call that gets past the
-- preflight gate stops at the 'no approved rows' guard. "Reached 'no approved rows'"
-- is therefore the safe, deterministic marker for "the gate let this through".

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, enabled, notes, scenario_sql)
VALUES (
  63,
  'Preflight enforcement at the stitch gate (D-19 pre-flip proof): the flag arms two more paths than fixture 33 covers, and on the FE commit path the refusal arrives with no invariant and no reachable override',
  'PRD-110 leg 98 — D-19 ("flip preflight_enforcement to block") was answered by CS on the premise that the audited single-use override is the escape hatch. It is, for commit_refill_plan, which nothing calls. This fixture pins what the flip would actually arm.',
  'P2',
  DATE '2030-03-05',
  true,
  'Parents are seeded status=''stitched'', never ''approved'', so stitch_pod_to_boonz always halts at its own "no approved rows" guard AFTER the preflight gate. Nothing in this fixture can run a real stitch. The p_force path''s preflight_override_log INSERT is rolled back by that same halt, so override_log_delta is 0 on every probe by construction — the audited-write shape is asserted on the schema default instead.',
$scenario$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);

DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'baselines', jsonb_build_object(
  'enforcement',   (SELECT COALESCE(preflight_enforcement,'warn') FROM public.refill_policy_params ORDER BY id LIMIT 1),
  'ovlog_other',   (SELECT count(*) FROM public.preflight_override_log WHERE plan_date <> {{plan_date}}),
  'ovlog_this',    (SELECT count(*) FROM public.preflight_override_log WHERE plan_date =  {{plan_date}}),
  'rpo_other',     (SELECT count(*) FROM public.refill_plan_output     WHERE plan_date <> {{plan_date}}));

-- synthetic 2030 plan_date only (LAW 12): no live plan row is ever touched
DELETE FROM public.refill_plan_output WHERE plan_date = {{plan_date}};
DELETE FROM public.pod_refill_plan    WHERE plan_date = {{plan_date}};

INSERT INTO public.pod_refill_plan
  (plan_date, machine_id, shelf_id, pod_product_id, action, qty, status, reasoning, source_origin)
SELECT {{plan_date}}, m.machine_id, sc.shelf_id, sl.pod_product_id, s.action, s.qty, s.status,
       jsonb_build_object('source','golden_fixture_63','scenario',s.tag), 'warehouse'::source_origin_enum
FROM (VALUES
    ('A06','REMOVE', 5, 'stitched', 'C1_conserving'),
    ('A07','REMOVE', 8, 'stitched', 'C2_genuine_leak')
  ) AS s(shelf_code, action, qty, status, tag)
JOIN public.machines m ON m.official_name = 'GRIT-1022-0100-W0'
JOIN public.shelf_configurations sc ON sc.machine_id = m.machine_id AND sc.shelf_code = s.shelf_code
JOIN public.slot_lifecycle sl ON sl.shelf_id = sc.shelf_id AND sl.archived = false AND sl.is_current = true;

UPDATE public.pod_refill_plan SET stitched_at = now() WHERE plan_date = {{plan_date}};

INSERT INTO public.refill_plan_output
  (plan_date, machine_name, shelf_code, pod_product_name, boonz_product_name, action, quantity,
   operator_status, machine_id, shelf_id, pod_product_id, source_origin, comment)
SELECT {{plan_date}}, 'GRIT-1022-0100-W0', s.shelf_code, pp.pod_product_name,
       pp.pod_product_name || ' - ' || s.variant, 'Remove', s.qty, 'approved',
       m.machine_id, sc.shelf_id, sl.pod_product_id, 'warehouse'::source_origin_enum,
       'golden_fixture_63 ' || s.tag
FROM (VALUES
    ('A06', 3, 'Variant A', 'C1_conserving'),
    ('A06', 2, 'Variant B', 'C1_conserving'),
    ('A07', 3, 'Variant A', 'C2_genuine_leak'),
    ('A07', 2, 'Variant B', 'C2_genuine_leak'),
    ('A07', 2, 'Variant C', 'C2_genuine_leak')
  ) AS s(shelf_code, qty, variant, tag)
JOIN public.machines m ON m.official_name = 'GRIT-1022-0100-W0'
JOIN public.shelf_configurations sc ON sc.machine_id = m.machine_id AND sc.shelf_code = s.shelf_code
JOIN public.slot_lifecycle sl ON sl.shelf_id = sc.shelf_id AND sl.archived = false AND sl.is_current = true
JOIN public.pod_products pp ON pp.pod_product_id = sl.pod_product_id;

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'seeded', jsonb_build_object(
  'parents',  (SELECT count(*) FROM public.pod_refill_plan   WHERE plan_date = {{plan_date}}),
  'children', (SELECT count(*) FROM public.refill_plan_output WHERE plan_date = {{plan_date}}),
  'approved', (SELECT count(*) FROM public.pod_refill_plan   WHERE plan_date = {{plan_date}} AND status = 'approved'));

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'pf_dirty', jsonb_build_object(
  'verdict', pf.verdict,
  'n_viol',  jsonb_array_length(pf.violations),
  'n_inv06', (SELECT count(*) FROM jsonb_array_elements(pf.violations) v WHERE v->>'invariant_id' = 'INV-06'))
FROM public.preflight_refill_plan({{plan_date}}) pf;

-- WARN (today's live mode): the gate reports but never refuses
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'warn_nondry',
       golden.probe_stitch_under_mode({{plan_date}}, 'warn', false, false, NULL);

-- BLOCK: the stitch gate must refuse, richly
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'block_nondry',
       golden.probe_stitch_under_mode({{plan_date}}, 'block', false, false, NULL);

-- BLOCK + dry run: an advisory read may never be blocked
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'block_dry',
       golden.probe_stitch_under_mode({{plan_date}}, 'block', true, false, NULL);

-- BLOCK + p_force with an unusable reason: the audit requirement bites first
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'block_short',
       golden.probe_stitch_under_mode({{plan_date}}, 'block', false, true, 'short');

-- BLOCK + p_force with a real reason: the hatch opens
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'block_forced',
       golden.probe_stitch_under_mode({{plan_date}}, 'block', false, true,
                                      'CS override for golden fixture 63 stitch gate');

-- THE FE'S REAL COMMIT PATH under block mode. Safe here precisely because the
-- verdict is FAIL and the mode is block, so the call aborts at the gate.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'atomic_block',
       golden.probe_atomic_commit_under_mode({{plan_date}}, 'block', ARRAY['GRIT-1022-0100-W0']);

-- ANTI-OVER-BLOCK: repair the leak and the same gate must stand aside
UPDATE public.pod_refill_plan SET qty = 7
 WHERE plan_date = {{plan_date}} AND reasoning->>'scenario' = 'C2_genuine_leak';

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'pf_clean', jsonb_build_object(
  'verdict', pf.verdict, 'n_viol', jsonb_array_length(pf.violations))
FROM public.preflight_refill_plan({{plan_date}}) pf;

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'block_clean',
       golden.probe_stitch_under_mode({{plan_date}}, 'block', false, false, NULL);

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'final', jsonb_build_object(
  'enforcement',   (SELECT COALESCE(preflight_enforcement,'warn') FROM public.refill_policy_params ORDER BY id LIMIT 1),
  'ovlog_other',   (SELECT count(*) FROM public.preflight_override_log WHERE plan_date <> {{plan_date}}),
  'ovlog_this',    (SELECT count(*) FROM public.preflight_override_log WHERE plan_date =  {{plan_date}}),
  'rpo_other',     (SELECT count(*) FROM public.refill_plan_output     WHERE plan_date <> {{plan_date}}));
$scenario$
);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
-- ── NON-VACUITY ────────────────────────────────────────────────────────────
(63, 1, 'NON-VACUITY: 2 REMOVE parents seeded on the fixture plan_date',
 'SELECT value->>''parents'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''seeded''',
 'eq', '2', true, 'P2'),
(63, 2, 'NON-VACUITY: 5 child legs seeded on the fixture plan_date',
 'SELECT value->>''children'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''seeded''',
 'eq', '5', true, 'P2'),
(63, 3, 'NON-VACUITY: the dirty plan really is dirty - preflight verdict FAIL',
 'SELECT value->>''verdict'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''pf_dirty''',
 'eq', 'FAIL', true, 'P2'),
(63, 4, 'NON-VACUITY: exactly ONE violation and it is the INV-06 conservation leak',
 'SELECT value->>''n_inv06'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''pf_dirty''',
 'eq', '1', true, 'P2'),
(63, 5, 'SAFETY INVARIANT OF THIS FIXTURE: zero approved parents, so stitch_pod_to_boonz can never actually execute - every post-gate path stops at "no approved rows"',
 'SELECT value->>''approved'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''seeded''',
 'eq', '0', true, 'P2'),
(63, 6, 'NON-VACUITY: every probe actually ran (scratch rows written by the scenario)',
 'SELECT count(*)::text FROM golden.scratch WHERE fixture_id = {{fixture_id}}',
 'gte', '11', true, 'P2'),

-- ── WARN: today's live mode reports but never refuses ──────────────────────
(63, 10, 'WARN: a FAILing preflight does NOT refuse the stitch - execution reaches the post-gate guard',
 'SELECT value->''error''->>''message'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''warn_nondry''',
 'contains', 'no approved rows', true, 'P2'),
(63, 11, 'WARN: no refusal payload is returned at all under warn',
 'SELECT jsonb_typeof(value->''result'') FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''warn_nondry''',
 'eq', 'null', true, 'P2'),

-- ── BLOCK: the stitch gate refuses, and refuses usefully ───────────────────
(63, 20, 'BLOCK: the stitch gate REFUSES a plan that violates an invariant (fixture 63 headline)',
 'SELECT value->''result''->>''status'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_nondry''',
 'eq', 'preflight_failed', true, 'P2'),
(63, 21, 'BLOCK: the refusal names the invariant it stopped on, not just a NO',
 'SELECT value->''result''->>''violations'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_nondry''',
 'contains', 'INV-06', true, 'P2'),
(63, 22, 'BLOCK: the refusal reports the violation count',
 'SELECT value->''result''->>''violation_count'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_nondry''',
 'eq', '1', true, 'P2'),
(63, 23, 'BLOCK: the refusal carries a fix path the operator can act on',
 'SELECT value->''result''->>''violations'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_nondry''',
 'contains', 'Re-run the stitch', true, 'P2'),
(63, 24, 'BLOCK: the refusal names its own escape hatch (p_force + an audited reason)',
 'SELECT value->''result''->>''message'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_nondry''',
 'contains', 'p_force', true, 'P2'),
(63, 25, 'BLOCK: a refusal is not a write - no override_log row is minted by refusing',
 'SELECT value->>''override_log_delta'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_nondry''',
 'eq', '0', true, 'P2'),

-- ── A DRY RUN IS A READ AND MAY NEVER BE BLOCKED ───────────────────────────
(63, 30, 'DRY RUN: block mode never refuses an advisory dry run - the nightly advisory stays functional (LAW 12)',
 'SELECT value->''error''->>''message'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_dry''',
 'contains', 'no approved rows', true, 'P2'),

-- ── THE p_force HATCH ──────────────────────────────────────────────────────
(63, 40, 'HATCH: p_force with a reason under 10 characters is REFUSED - the override is audited or it is not granted',
 'SELECT value->''error''->>''message'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_short''',
 'contains', '10 characters', true, 'P2'),
(63, 41, 'HATCH: the unusable-reason attempt logged nothing',
 'SELECT value->>''override_log_delta'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_short''',
 'eq', '0', true, 'P2'),
(63, 42, 'HATCH: p_force with a real reason opens the gate - execution reaches the post-gate guard',
 'SELECT value->''error''->>''message'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_forced''',
 'contains', 'no approved rows', true, 'P2'),
(63, 43, 'HATCH: the audit row is attributable to the stitch gate by schema default, since this fixture''s post-gate halt rolls the INSERT itself back',
 'SELECT column_default FROM information_schema.columns WHERE table_name = ''preflight_override_log'' AND column_name = ''source''',
 'contains', 'stitch', true, 'P2'),

-- ── THE FE'S REAL COMMIT PATH (S-172) ──────────────────────────────────────
(63, 50, 'TRANSITIVE: the flag DOES reach the FE commit path - commit_refill_plan_atomic aborts when the stitch it calls is refused',
 'SELECT value->''error''->>''sqlstate'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''atomic_block''',
 'eq', 'P0001', true, 'P2'),
(63, 51, 'TRANSITIVE: the abort is real - the refused commit added zero refill_plan_output rows',
 'SELECT value->>''plan_output_delta'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''atomic_block''',
 'eq', '0', true, 'P2'),
(63, 52, 'S-172 GAP (pinned as CURRENT behaviour, not as desired): the operator sees a PRD-019 rollback message instead of the invariant that stopped them',
 'SELECT value->''error''->>''message'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''atomic_block''',
 'contains', 'PRD-019 E2', true, 'P2'),
(63, 53, 'S-172 GAP: that message carries NO invariant id - the fix path fixture 63 seq 21/23 proves exists is swallowed before it reaches the operator',
 'SELECT ((value->''error''->>''message'') LIKE ''%INV-%'')::text FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''atomic_block''',
 'eq', 'false', true, 'P2'),
(63, 54, 'S-172 GAP: commit_refill_plan_atomic has NO p_force passthrough, so the audited hatch is unreachable from the only commit path the FE calls',
 'SELECT (SELECT count(*) FROM regexp_matches((SELECT p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = ''public'' AND p.proname = ''commit_refill_plan_atomic''), ''p_force'', ''g''))::text',
 'eq', '0', true, 'P2'),
(63, 55, 'S-172 GAP: commit_refill_plan_atomic handles no preflight status of its own - it only ever sees a missing write_result',
 'SELECT (SELECT count(*) FROM regexp_matches((SELECT p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = ''public'' AND p.proname = ''commit_refill_plan_atomic''), ''preflight'', ''g''))::text',
 'eq', '0', true, 'P2'),
(63, 56, 'SCOPE OF THE FLIP: public.commit_refill_plan - the path fixture 33 proves - is still the gated one, and it remains a real function',
 'SELECT (to_regprocedure(''public.commit_refill_plan(date,text,uuid[])'') IS NOT NULL)::text',
 'eq', 'true', true, 'P2'),

-- ── ANTI-OVER-BLOCK ────────────────────────────────────────────────────────
(63, 60, 'ANTI-OVER-BLOCK: repairing the leak flips the verdict to PASS (the gate reads the plan, not the calendar)',
 'SELECT value->>''verdict'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''pf_clean''',
 'eq', 'PASS', true, 'P2'),
(63, 61, 'ANTI-OVER-BLOCK: a clean plan is not refused under block mode - it reaches the post-gate guard with no override at all',
 'SELECT value->''error''->>''message'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_clean''',
 'contains', 'no approved rows', true, 'P2'),
(63, 62, 'ANTI-OVER-BLOCK: the clean run returned no refusal payload',
 'SELECT jsonb_typeof(value->''result'') FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_clean''',
 'eq', 'null', true, 'P2'),

-- ── HARNESS SAFETY (drift-immune: compare to the baseline, never to a literal) ──
(63, 90, 'HARNESS SAFETY: preflight_enforcement is restored to exactly what it was before the fixture ran - asserted as a DELTA so this fixture survives D-19 being executed (S-166)',
 'SELECT ((SELECT value->>''enforcement'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''final'')
        = (SELECT value->>''enforcement'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''baselines''))::text',
 'eq', 'true', true, 'P2'),
(63, 91, 'HARNESS SAFETY: zero override_log rows were written for any OTHER plan_date',
 'SELECT ((SELECT (value->>''ovlog_other'')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''final'')
        - (SELECT (value->>''ovlog_other'')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''baselines''))::text',
 'eq', '0', true, 'P2'),
(63, 92, 'HARNESS SAFETY: zero override_log rows persisted even for THIS plan_date - every p_force INSERT was rolled back by the post-gate halt',
 'SELECT ((SELECT (value->>''ovlog_this'')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''final'')
        - (SELECT (value->>''ovlog_this'')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''baselines''))::text',
 'eq', '0', true, 'P2'),
(63, 93, 'HARNESS SAFETY: no refill_plan_output row for any other plan_date was touched',
 'SELECT ((SELECT (value->>''rpo_other'')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''final'')
        - (SELECT (value->>''rpo_other'')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''baselines''))::text',
 'eq', '0', true, 'P2');
