-- PRD-110 P3.3 — golden fixture 43 assertions.
-- ⭐ Every violation-counting assertion is S-70-wrapped AT AUTHORING TIME: absence of
--    function output yields 'NO_ROTATION_OUTPUT' (eq-ops) or '-1' (gt/gte-ops), never a
--    vacuous 0. Wrapping, never rewriting, so a corrective cannot weaken the assertion.

DELETE FROM golden.assertions WHERE fixture_id = 43;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES

-- ============ DRIFT GUARDS ============
(43, 1, 'Drift guard: {{plan_date}} still renders as the fixture-43 anchor 2030-02-13',
 $a$SELECT {{plan_date}}::text$a$, 'eq', '2030-02-13', true, 'P3'),
(43, 2, 'Drift guard: fixture 43 is registered on phase P3 and enabled',
 $a$SELECT (phase_required = 'P3' AND enabled)::text FROM golden.fixtures WHERE fixture_id = 43$a$, 'eq', 'true', true, 'P3'),

-- ============ PARAMS (prerequisites, not the object under test) ============
(43, 3, 'All five rot_* policy params exist as columns on refill_policy_params',
 $a$SELECT count(*)::text FROM information_schema.columns WHERE table_name='refill_policy_params' AND column_name LIKE 'rot\_%'$a$, 'eq', '5', true, 'P3'),
(43, 4, 'chk_rot_params_sane is present and enforced',
 $a$SELECT count(*)::text FROM pg_constraint WHERE conname='chk_rot_params_sane' AND convalidated$a$, 'eq', '1', true, 'P3'),
(43, 5, 'rot_min_speedup >= 1.0 -- a speedup below 1 would rotate stock to a SLOWER shelf',
 $a$SELECT (rot_min_speedup >= 1.0)::text FROM public.refill_policy_params LIMIT 1$a$, 'eq', 'true', true, 'P3'),
(43, 6, 'Every rot_* param carries a comment declaring it POLICY, not measured (S-69 habit)',
 $a$SELECT count(*)::text FROM information_schema.columns c
   JOIN pg_class cl ON cl.relname='refill_policy_params'
   WHERE c.table_name='refill_policy_params' AND c.column_name LIKE 'rot\_%'
     AND col_description(cl.oid, c.ordinal_position) LIKE '%POLICY, not measured%'$a$, 'eq', '5', true, 'P3'),

-- ============ POPULATION EVIDENCE: the fixture is not vacuous ============
(43, 7, 'POPULATION: shelves carrying a pod product exist to reason about',
 $a$SELECT (value->>'shelves_with_pod') FROM golden.scratch WHERE fixture_id=43 AND key='pop'$a$, 'gt', '400', true, 'P3'),
(43, 8, 'POPULATION: source candidates (measurably slow, stocked, non-venue) exist -- if this hits 0 the whole fixture is vacuous',
 $a$SELECT (value->>'source_candidates') FROM golden.scratch WHERE fixture_id=43 AND key='pop'$a$, 'gt', '20', true, 'P3'),
(43, 9, 'POPULATION: target candidates (measurably selling, with headroom) exist',
 $a$SELECT (value->>'target_candidates') FROM golden.scratch WHERE fixture_id=43 AND key='pop'$a$, 'gt', '50', true, 'P3'),
(43, 10, 'POPULATION: the independent recomputation yields at least one proposable pair',
 $a$SELECT (value->>'expected_rows') FROM golden.scratch WHERE fixture_id=43 AND key='pop'$a$, 'gt', '0', true, 'P3'),
(43, 11, 'POPULATION: unmeasurable shelves are COUNTED, not silently dropped (S-71 idiom)',
 $a$SELECT (value->>'vel_null') FROM golden.scratch WHERE fixture_id=43 AND key='pop'$a$, 'gte', '0', true, 'P3'),

-- ============ TABLE CONTRACT ============
(43, 12, 'rotation_proposals_v3 exists',
 $a$SELECT (to_regclass('public.rotation_proposals_v3') IS NOT NULL)::text$a$, 'eq', 'true', true, 'P3'),
(43, 13, 'Article 2: RLS is enabled on rotation_proposals_v3',
 $a$SELECT relrowsecurity::text FROM pg_class WHERE oid='public.rotation_proposals_v3'::regclass$a$, 'eq', 'true', true, 'P3'),
(43, 14, 'Article 3/5: NO update, insert or delete policy exists -- a logged-in client cannot flip the CS gate',
 $a$SELECT count(*)::text FROM pg_policy WHERE polrelid='public.rotation_proposals_v3'::regclass AND polcmd::text <> 'r'$a$, 'eq', '0', true, 'P3'),
(43, 15, 'anon holds NO privilege on rotation_proposals_v3 (S-57 loose-grant class)',
 $a$SELECT COALESCE(has_table_privilege('anon','public.rotation_proposals_v3','SELECT')
                 OR has_table_privilege('anon','public.rotation_proposals_v3','INSERT'), false)::text$a$, 'eq', 'false', true, 'P3'),
(43, 16, 'Conservation is enforced in the SCHEMA, not merely by the writer: qty<=on-shelf and qty<=headroom CHECKs are present and validated',
 $a$SELECT count(*)::text FROM pg_constraint WHERE conrelid='public.rotation_proposals_v3'::regclass
   AND conname IN ('rp_v3_qty_le_onshelf','rp_v3_qty_le_headroom','rp_v3_no_self_move') AND convalidated$a$, 'eq', '3', true, 'P3'),
(43, 17, 'Idempotency key (plan_date, source_shelf_id, target_shelf_id) is UNIQUE -- the heartbeat is a weekly cron (S-58)',
 $a$SELECT count(*)::text FROM pg_constraint WHERE conrelid='public.rotation_proposals_v3'::regclass
   AND conname='rp_v3_unique_heartbeat' AND contype='u'$a$, 'eq', '1', true, 'P3'),
(43, 18, 'CS gate as a constraint: any approved/rejected/applied row must NAME its reviewer',
 $a$SELECT count(*)::text FROM pg_constraint WHERE conrelid='public.rotation_proposals_v3'::regclass
   AND conname='rp_v3_review_named' AND convalidated$a$, 'eq', '1', true, 'P3'),

-- ============ THE SPINE: independent recomputation, row for row ============
(43, 20, 'THE SPINE: the function emits EXACTLY the pair set the fixture independently derived from base tables -- 0 rows the fixture did not predict',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id=43 AND s.key='out'
       AND NOT EXISTS (SELECT 1 FROM golden.scratch i WHERE i.fixture_id=43
                        AND i.key = 'indep_'||(e->>'source_shelf_id')||'_'||(e->>'target_shelf_id'))) END$a$,
 'eq', '0', true, 'P3'),
(43, 21, 'THE SPINE, other direction: 0 pairs the fixture predicted that the function failed to emit',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM golden.scratch i
     WHERE i.fixture_id=43 AND i.key LIKE 'indep\_%'
       AND NOT EXISTS (SELECT 1 FROM golden.scratch s, jsonb_array_elements(s.value) e
                        WHERE s.fixture_id=43 AND s.key='out'
                          AND i.key = 'indep_'||(e->>'source_shelf_id')||'_'||(e->>'target_shelf_id'))) END$a$,
 'eq', '0', true, 'P3'),
(43, 22, 'THE SPINE: every proposed_qty equals the independent recomputation -- 0 mismatches',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
     JOIN golden.scratch i ON i.fixture_id=43
       AND i.key='indep_'||(e->>'source_shelf_id')||'_'||(e->>'target_shelf_id')
     WHERE s.fixture_id=43 AND s.key='out'
       AND (e->>'proposed_qty')::int IS DISTINCT FROM (i.value->>'qty')::int) END$a$,
 'eq', '0', true, 'P3'),
(43, 23, 'THE SPINE: every fit_score equals the independent recomputation -- 0 mismatches',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
     JOIN golden.scratch i ON i.fixture_id=43
       AND i.key='indep_'||(e->>'source_shelf_id')||'_'||(e->>'target_shelf_id')
     WHERE s.fixture_id=43 AND s.key='out'
       AND round((e->>'fit_score')::numeric,4) IS DISTINCT FROM round((i.value->>'fit')::numeric,4)) END$a$,
 'eq', '0', true, 'P3'),
(43, 24, 'THE SPINE: every projected_days_to_sell equals the independent recomputation -- 0 mismatches',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
     JOIN golden.scratch i ON i.fixture_id=43
       AND i.key='indep_'||(e->>'source_shelf_id')||'_'||(e->>'target_shelf_id')
     WHERE s.fixture_id=43 AND s.key='out'
       AND round((e->>'projected_days_to_sell')::numeric,2) IS DISTINCT FROM round((i.value->>'pdays')::numeric,2)) END$a$,
 'eq', '0', true, 'P3'),

-- ============ CONSERVATION AND POLICY INVARIANTS ============
(43, 25, 'CROSS-ROW CONSERVATION: no destination shelf is committed twice in one run -- the per-row headroom CHECK alone would not catch two proposals summing past it',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM (
       SELECT e->>'target_shelf_id' t FROM golden.scratch s, jsonb_array_elements(s.value) e
       WHERE s.fixture_id=43 AND s.key='out' GROUP BY 1 HAVING count(*) > 1) z) END$a$,
 'eq', '0', true, 'P3'),
(43, 26, 'No source shelf is drained by two proposals in one run',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM (
       SELECT e->>'source_shelf_id' s2 FROM golden.scratch s, jsonb_array_elements(s.value) e
       WHERE s.fixture_id=43 AND s.key='out' GROUP BY 1 HAVING count(*) > 1) z) END$a$,
 'eq', '0', true, 'P3'),
(43, 27, 'Never a self-move: 0 proposals where source and target are the same machine',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id=43 AND s.key='out' AND (e->>'source_machine_id') = (e->>'target_machine_id')) END$a$,
 'eq', '0', true, 'P3'),
(43, 28, 'Every source is MEASURABLY slow: 0 proposals whose source velocity is at or above the policy floor',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id=43 AND s.key='out'
       AND (e->>'source_velocity')::numeric >= (SELECT rot_slow_velocity_per_day FROM public.refill_policy_params LIMIT 1)) END$a$,
 'eq', '0', true, 'P3'),
(43, 29, 'THE POINT OF THE FEATURE: every target is at least rot_min_speedup times faster than its source -- 0 violations',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id=43 AND s.key='out'
       AND (e->>'target_velocity')::numeric
           < (e->>'source_velocity')::numeric * (SELECT rot_min_speedup FROM public.refill_policy_params LIMIT 1)) END$a$,
 'eq', '0', true, 'P3'),
(43, 30, 'LAW 7 PREVENTIVE: 0 proposals move stock that would expire before it could clear at the destination',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
     JOIN public.v_shelf_state v ON v.shelf_id = (e->>'source_shelf_id')::uuid
     WHERE s.fixture_id=43 AND s.key='out'
       AND v.oldest_expiry_est IS NOT NULL
       AND (v.oldest_expiry_est::date - DATE '2030-02-13') < (e->>'projected_days_to_sell')::numeric) END$a$,
 'eq', '0', true, 'P3'),
(43, 31, 'No venue-sourced stock is rotated in either direction -- partner stock is not ours to move (LAW 6)',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
     JOIN public.v_shelf_state v ON v.shelf_id IN ((e->>'source_shelf_id')::uuid, (e->>'target_shelf_id')::uuid)
     WHERE s.fixture_id=43 AND s.key='out' AND v.sourcing = 'venue') END$a$,
 'eq', '0', true, 'P3'),
(43, 32, 'Every proposal carries the same product at both ends -- rotation moves stock, it does not re-assort',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
     JOIN public.v_shelf_state a ON a.shelf_id=(e->>'source_shelf_id')::uuid
     JOIN public.v_shelf_state b ON b.shelf_id=(e->>'target_shelf_id')::uuid
     WHERE s.fixture_id=43 AND s.key='out' AND a.pod_product_id IS DISTINCT FROM b.pod_product_id) END$a$,
 'eq', '0', true, 'P3'),
(43, 33, 'fit_score honours its own floor: 0 emitted proposals score below rot_min_fit_score',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id=43 AND s.key='out'
       AND (e->>'fit_score')::numeric < (SELECT rot_min_fit_score FROM public.refill_policy_params LIMIT 1)) END$a$,
 'eq', '0', true, 'P3'),
(43, 34, 'Output is ordered best-first by fit_score -- 0 inversions',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM (
       SELECT (e->>'fit_score')::numeric f,
              lag((e->>'fit_score')::numeric) OVER (ORDER BY ord) prev
       FROM golden.scratch s, jsonb_array_elements(s.value) WITH ORDINALITY AS t(e, ord)
       WHERE s.fixture_id=43 AND s.key='out') z WHERE prev IS NOT NULL AND f > prev) END$a$,
 'eq', '0', true, 'P3'),

-- ============ TRANSPARENCY (S-71 idiom: counters ride on every row) ============
(43, 35, 'Every proposal carries a scoring_breakdown -- 0 rows without one',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id=43 AND s.key='out'
       AND (e->'scoring_breakdown' IS NULL OR e->'scoring_breakdown' = 'null'::jsonb)) END$a$,
 'eq', '0', true, 'P3'),
(43, 36, 'Every scoring_breakdown NAMES the canonical velocity object it read (Article 16 provenance, the leg-58 lesson applied forward)',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id=43 AND s.key='out'
       AND COALESCE(e->'scoring_breakdown'->>'velocity_source','') <> 'v_shelf_instock_velocity_split_v3') END$a$,
 'eq', '0', true, 'P3'),
(43, 37, 'Every scoring_breakdown carries coverage_gaps so a zero can be told from a blind spot (S-71)',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id=43 AND s.key='out' AND e->'scoring_breakdown'->'coverage_gaps' IS NULL) END$a$,
 'eq', '0', true, 'P3'),
(43, 38, 'Every proposal declares its thresholds were POLICY, not measurement (S-69 habit)',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id=43 AND s.key='out'
       AND COALESCE(e->'scoring_breakdown'->>'threshold_basis','') NOT LIKE '%POLICY%') END$a$,
 'eq', '0', true, 'P3'),

-- ============ THE CS GATE (LAW 4: shadow, don't switch) ============
(43, 39, 'LAW 4 / CS GATE: every written proposal is pending. 0 rows reach any other status without a human',
 $a$SELECT COALESCE((SELECT value::text FROM golden.scratch WHERE fixture_id=43 AND key='statuses'), 'NO_ROTATION_OUTPUT')$a$,
 'eq', '0', true, 'P3'),
(43, 40, 'The heartbeat actually wrote proposals -- non-vacuous evidence the writer works',
 $a$SELECT COALESCE((SELECT value::text FROM golden.scratch WHERE fixture_id=43 AND key='rows_after'), '-1')$a$,
 'gt', '0', true, 'P3'),
(43, 41, 'Written row count equals the number of proposals returned',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT ((SELECT value::int FROM golden.scratch WHERE fixture_id=43 AND key='rows_after')
             = (SELECT jsonb_array_length(value) FROM golden.scratch WHERE fixture_id=43 AND key='out'))::text) END$a$,
 'eq', 'true', true, 'P3'),

-- ============ IDEMPOTENCY, DRY RUN, LIMIT ============
(43, 42, 'S4 STRESS PRECONDITION: a second identical heartbeat writes NOTHING new -- row count unchanged',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT ((SELECT value::int FROM golden.scratch WHERE fixture_id=43 AND key='rows_after')
             = (SELECT jsonb_array_length(value) FROM golden.scratch WHERE fixture_id=43 AND key='out'))::text) END$a$,
 'eq', 'true', true, 'P3'),
(43, 43, 'DRY RUN COMPUTES BUT DOES NOT WRITE: zero rows existed after the dry run',
 $a$SELECT COALESCE((SELECT value::text FROM golden.scratch WHERE fixture_id=43 AND key='rows_after_dry'), 'NO_ROTATION_OUTPUT')$a$,
 'eq', '0', true, 'P3'),
(43, 44, 'DRY RUN IS NOT A NO-OP: it still returned a full answer',
 $a$SELECT COALESCE((SELECT jsonb_array_length(value)::text FROM golden.scratch WHERE fixture_id=43 AND key='out_dry'), '-1')$a$,
 'gt', '0', true, 'P3'),
(43, 45, 'p_limit is honoured: a 3-limited call returns at most 3',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out_limit3')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT ((value::int) <= 3)::text FROM golden.scratch WHERE fixture_id=43 AND key='out_limit3') END$a$,
 'eq', 'true', true, 'P3'),
(43, 46, 'Emitted count never exceeds rot_max_proposals',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT ((SELECT jsonb_array_length(value) FROM golden.scratch WHERE fixture_id=43 AND key='out')
             <= (SELECT rot_max_proposals FROM public.refill_policy_params LIMIT 1))::text) END$a$,
 'eq', 'true', true, 'P3'),

-- ============ LAW 12 / LAW 11 TRIPWIRES (this function WRITES, so these are not decorative) ============
(43, 47, 'LAW 12: pod_refill_plan row count is identical before and after the heartbeat',
 $a$SELECT ((SELECT (value->>'live_plan_before')::int FROM golden.scratch WHERE fixture_id=43 AND key='pop')
        = (SELECT (value->>'live_plan_after')::int  FROM golden.scratch WHERE fixture_id=43 AND key='after'))::text$a$,
 'eq', 'true', true, 'P3'),
(43, 48, 'LAW 12: refill_plan_output row count is identical before and after the heartbeat',
 $a$SELECT ((SELECT (value->>'rpo_before')::int FROM golden.scratch WHERE fixture_id=43 AND key='pop')
        = (SELECT (value->>'rpo_after')::int  FROM golden.scratch WHERE fixture_id=43 AND key='after'))::text$a$,
 'eq', 'true', true, 'P3'),
(43, 49, 'LAW 11: machines_to_visit is untouched -- Gate 0 stays manual and this object is not a picker',
 $a$SELECT ((SELECT (value->>'mtv_before')::int FROM golden.scratch WHERE fixture_id=43 AND key='pop')
        = (SELECT (value->>'mtv_after')::int  FROM golden.scratch WHERE fixture_id=43 AND key='after'))::text$a$,
 'eq', 'true', true, 'P3'),

-- ============ THE RETIRED PREDECESSOR (S-74) ============
(43, 50, 'S-74 SENTINEL: public.rotation_proposals still does NOT exist. If this ever flips to true, three anon-executable SECURITY DEFINER writers silently come back to life',
 $a$SELECT (to_regclass('public.rotation_proposals') IS NULL)::text$a$, 'eq', 'true', true, 'P3'),
(43, 51, 'S-74: the 22 retired rows are preserved in graveyard, never deleted (LAW 3, no destructive change)',
 $a$SELECT (count(*) >= 22)::text FROM graveyard.rotation_proposals$a$, 'eq', 'true', true, 'P3');
