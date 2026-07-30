-- PRD-110 · fixture 10 "Superseded REMOVE conservation" (GOLDEN-FIXTURES row 10)
-- Source incident: bug_conservation_counts_superseded_remove
-- Proves INV-06 of preflight_refill_plan. Pure READ-PATH fixture: calls NO engine.
--   * plan_date 2030-01-11 (= 2030-01-01 + fixture_id, per golden.render)
--   * seeds pod_refill_plan parents + refill_plan_output children on GRIT-1022-0100-W0
--   * LANDMINE: trg_refill_plan_output_approve_to_dispatch is AFTER UPDATE OF operator_status.
--     Children are INSERTed already-approved and operator_status is NEVER updated, so
--     push_plan_to_dispatch cannot fire. Do not "improve" this into an insert-then-update.
--   * pod_refill_plan PK is (plan_date,machine_id,shelf_id,pod_product_id,action) so a
--     shelf/pod can hold at most one REMOVE and one M2W parent - scenario S6 uses both.
--   * No seq-90 engine exposure (S-08) because no engine runs; the tripwire is kept anyway.

DELETE FROM golden.assertions WHERE fixture_id = 10;
DELETE FROM golden.fixtures   WHERE fixture_id = 10;

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, enabled, baseline_status, notes, scenario_sql)
VALUES (10, 'Superseded REMOVE conservation',
  'bug_conservation_counts_superseded_remove', 'P0', DATE '2030-01-11', true, 'failing_expected',
$notes$Spec (GOLDEN-FIXTURES #10): "Assert conservation check ignores superseded rows; no false
stop-ship; INV-06 passes with Remove leg present."

Live decomposition of all 427 historical INV-06 violations (measured 2026-07-30, leg 4):
  156 superseded/voided parent         <- FALSE POSITIVE  (S1, S6)
   98 draft parent, never stitched     <- FALSE POSITIVE  (S2)
    7 children exist, status<>approved <- FALSE POSITIVE  (S5)
  126 no child legs at all             <- real leak (mostly pre-uuid legacy dates)
   40 genuine sum mismatch             <- TRUE POSITIVE   (S4 - must survive the fix)

SPEC CORRECTION (LAW 13). BUILD SPEC P0.6(d) says INV-06 should "treat REMOVE rows as
satisfied when a matching Remove line exists ... action='Remove'". Taken literally that is
an EXISTENCE test, which would silence the 40 genuine sum mismatches (e.g. USH-1008 A14
2026-07-28: parent 8 vs children 3+2+2=7, one unit lost). It would also break M2W parents:
live data shows 26 non-superseded M2W parents, of which 21 have NO child legs, 2 have
'Remove' children and only 1 has a 'Machine To Warehouse' child - so strict action-matching
manufactures new false positives (the landmine recorded in memory). The fix therefore keeps
SUM conservation and the lumped removal family, and corrects the three predicate defects the
data actually shows. S4 + S6 exist to pin that.$notes$,
$scen$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'df_open_before', jsonb_build_object('n', (SELECT count(*) FROM public.driver_feedback WHERE resolved = false));

DELETE FROM public.refill_plan_output WHERE plan_date = {{plan_date}};
DELETE FROM public.pod_refill_plan    WHERE plan_date = {{plan_date}};

-- parents: pod_refill_plan
INSERT INTO public.pod_refill_plan
  (plan_date, machine_id, shelf_id, pod_product_id, action, qty, status, reasoning, source_origin)
SELECT {{plan_date}}, m.machine_id, sc.shelf_id, sl.pod_product_id, s.action, s.qty, s.status,
       jsonb_build_object('source','golden_fixture_10','scenario',s.tag), 'warehouse'::source_origin_enum
FROM (VALUES
    ('A01','REMOVE', 7, 'superseded', 'S1_superseded_parent_no_children'),
    ('A05','REMOVE', 5, 'draft',      'S2_draft_parent_never_stitched'),
    ('A06','REMOVE', 5, 'stitched',   'S3_conserving_remove_leg_present'),
    ('A07','REMOVE', 8, 'stitched',   'S4_genuine_leak_must_stay_flagged'),
    ('A08','REMOVE', 4, 'stitched',   'S5_children_expired_status'),
    ('A12','REMOVE', 9, 'stitched',   'S6_pair_live_remove'),
    ('A12','M2W',    4, 'superseded', 'S6_pair_superseded_m2w')
  ) AS s(shelf_code, action, qty, status, tag)
JOIN public.machines m ON m.official_name = 'GRIT-1022-0100-W0'
JOIN public.shelf_configurations sc ON sc.machine_id = m.machine_id AND sc.shelf_code = s.shelf_code
JOIN public.slot_lifecycle sl ON sl.shelf_id = sc.shelf_id AND sl.archived = false AND sl.is_current = true;

UPDATE public.pod_refill_plan SET stitched_at = now()
 WHERE plan_date = {{plan_date}} AND status = 'stitched';

-- children: refill_plan_output (INSERTed at final operator_status, never updated)
INSERT INTO public.refill_plan_output
  (plan_date, machine_name, shelf_code, pod_product_name, boonz_product_name, action, quantity,
   operator_status, machine_id, shelf_id, pod_product_id, source_origin, comment)
SELECT {{plan_date}}, 'GRIT-1022-0100-W0', s.shelf_code, pp.pod_product_name,
       pp.pod_product_name || ' - ' || s.variant, 'Remove', s.qty, s.op_status,
       m.machine_id, sc.shelf_id, sl.pod_product_id, 'warehouse'::source_origin_enum,
       'golden_fixture_10 ' || s.tag
FROM (VALUES
    ('A06', 3, 'approved', 'Variant A', 'S3_conserving_remove_leg_present'),
    ('A06', 2, 'approved', 'Variant B', 'S3_conserving_remove_leg_present'),
    ('A07', 3, 'approved', 'Variant A', 'S4_genuine_leak_must_stay_flagged'),
    ('A07', 2, 'approved', 'Variant B', 'S4_genuine_leak_must_stay_flagged'),
    ('A07', 2, 'approved', 'Variant C', 'S4_genuine_leak_must_stay_flagged'),
    ('A08', 4, 'expired',  'Variant A', 'S5_children_expired_status'),
    ('A12', 9, 'approved', 'Variant A', 'S6_pair_live_remove')
  ) AS s(shelf_code, qty, op_status, variant, tag)
JOIN public.machines m ON m.official_name = 'GRIT-1022-0100-W0'
JOIN public.shelf_configurations sc ON sc.machine_id = m.machine_id AND sc.shelf_code = s.shelf_code
JOIN public.slot_lifecycle sl ON sl.shelf_id = sc.shelf_id AND sl.archived = false AND sl.is_current = true
JOIN public.pod_products pp ON pp.pod_product_id = sl.pod_product_id;
$scen$);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(10, 1, 'Non-vacuity: 7 parents seeded (6 REMOVE + 1 M2W)',
 'SELECT count(*)::text FROM public.pod_refill_plan WHERE plan_date = {{plan_date}}',
 'eq', '7', true, 'P0'),

(10, 2, 'Non-vacuity: 7 child legs seeded',
 'SELECT count(*)::text FROM public.refill_plan_output WHERE plan_date = {{plan_date}}',
 'eq', '7', true, 'P0'),

(10, 10, 'S1 superseded parent with no children is NOT an INV-06 violation (fixture 10 headline)',
 $q$SELECT count(*)::text FROM public.preflight_refill_plan({{plan_date}}) pf,
     LATERAL jsonb_array_elements(COALESCE(pf.violations,'[]'::jsonb)) v
    WHERE v->>'invariant_id' = 'INV-06' AND v->>'shelf_code' = 'A01'$q$,
 'eq', '0', true, 'P0'),

(10, 11, 'S2 draft parent never stitched is NOT an INV-06 violation',
 $q$SELECT count(*)::text FROM public.preflight_refill_plan({{plan_date}}) pf,
     LATERAL jsonb_array_elements(COALESCE(pf.violations,'[]'::jsonb)) v
    WHERE v->>'invariant_id' = 'INV-06' AND v->>'shelf_code' = 'A05'$q$,
 'eq', '0', true, 'P0'),

(10, 12, 'S3 INV-06 passes with a conserving Remove leg present (5 = 3+2)',
 $q$SELECT count(*)::text FROM public.preflight_refill_plan({{plan_date}}) pf,
     LATERAL jsonb_array_elements(COALESCE(pf.violations,'[]'::jsonb)) v
    WHERE v->>'invariant_id' = 'INV-06' AND v->>'shelf_code' = 'A06'$q$,
 'eq', '0', true, 'P0'),

(10, 13, 'S4 ANTI-OVER-FIX: a genuine sum mismatch (8 vs 7) MUST still be flagged',
 $q$SELECT count(*)::text FROM public.preflight_refill_plan({{plan_date}}) pf,
     LATERAL jsonb_array_elements(COALESCE(pf.violations,'[]'::jsonb)) v
    WHERE v->>'invariant_id' = 'INV-06' AND v->>'shelf_code' = 'A07'$q$,
 'eq', '1', true, 'P0'),

(10, 14, 'S4 the surviving violation still reports the real arithmetic (children sum 7)',
 $q$SELECT string_agg(v->>'found', '|') FROM public.preflight_refill_plan({{plan_date}}) pf,
     LATERAL jsonb_array_elements(COALESCE(pf.violations,'[]'::jsonb)) v
    WHERE v->>'invariant_id' = 'INV-06' AND v->>'shelf_code' = 'A07'$q$,
 'contains', 'children sum 7', true, 'P0'),

(10, 15, 'S5 children that exist but carry operator_status=expired are NOT an INV-06 violation',
 $q$SELECT count(*)::text FROM public.preflight_refill_plan({{plan_date}}) pf,
     LATERAL jsonb_array_elements(COALESCE(pf.violations,'[]'::jsonb)) v
    WHERE v->>'invariant_id' = 'INV-06' AND v->>'shelf_code' = 'A08'$q$,
 'eq', '0', true, 'P0'),

(10, 16, 'S6 a live REMOVE + superseded M2W pair on one shelf/pod yields ZERO violations (guards the superseded bug AND a naive action-matched join)',
 $q$SELECT count(*)::text FROM public.preflight_refill_plan({{plan_date}}) pf,
     LATERAL jsonb_array_elements(COALESCE(pf.violations,'[]'::jsonb)) v
    WHERE v->>'invariant_id' = 'INV-06' AND v->>'shelf_code' = 'A12'$q$,
 'eq', '0', true, 'P0'),

(10, 20, 'Fixture-wide: exactly ONE INV-06 violation on the plan_date (S4 only)',
 $q$SELECT count(*)::text FROM public.preflight_refill_plan({{plan_date}}) pf,
     LATERAL jsonb_array_elements(COALESCE(pf.violations,'[]'::jsonb)) v
    WHERE v->>'invariant_id' = 'INV-06'$q$,
 'eq', '1', true, 'P0'),

(10, 90, 'HARNESS SAFETY: the fixture resolved no live driver_feedback',
 $q$SELECT (SELECT count(*)::int FROM public.driver_feedback WHERE resolved = false)
        - (SELECT (value->>'n')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'df_open_before')$q$,
 'eq', '0', true, 'P0');
