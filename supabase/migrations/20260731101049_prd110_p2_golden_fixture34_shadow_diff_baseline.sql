-- PRD-110 P2 / D-12 · GOLDEN FIXTURE 34 — "Nightly shadow diff vs v19 is non-vacuous"
--
-- LAW 1: the fixture lands BEFORE the diff object it proves, and is run RED first.
--
-- WHY THIS FIXTURE EXISTS (measured live at leg 51 STEP R, not assumed):
--   `public.v_shadow_vs_live_plan_v3` already exists and reads `pod_refill_plan_shadow`
--   FULL JOIN `pod_refill_plan`. But `pod_refill_plan_shadow` has 0 rows and
--   `engine_add_pod_v3` never mentions it (position('pod_refill_plan_shadow' in prosrc) = 0).
--   The v3 engine's ONLY INSERT target is `pod_refills_shadow`. So the existing "diff"
--   object is STRUCTURALLY VACUOUS: it can never return a row, and a reader would read
--   "0 differences" as PARITY. That is the exact S-48 / S-52 failure class, sitting in the
--   one object whose whole job is to be the Phase-2 gate's evidence.
--
--   The plan-grain view is not wrong — it is correct for the grain it names, and it comes
--   alive at cutover when v3 writes plan rows. It is simply not the D-12 object. Article 12
--   is forward-only, so it is kept, and seq 60/61 below PIN it at 0 with an explicit
--   description so its emptiness can never again be mistaken for agreement.
--
-- WHAT IS PROVEN: the canonical diff must agree, number for number, with an INDEPENDENT
--   recomputation from the base tables (`golden.scratch` key 'truth'), taken in the same
--   transaction. No assertion compares the diff object against itself.

-- ---------------------------------------------------------------------------------------
-- Harness helper: run a probe whose target may not exist yet.
--
-- LAW 1 requires the fixture to precede its object. Referencing a not-yet-created relation
-- inside a plain check_sql fails at PARSE time, which surfaces as a run ERROR and takes the
-- whole fixture with it (leg 50 note: "the RED had to come from BEHAVIOUR"). This wraps the
-- probe in EXECUTE so a missing object degrades to a clean, comparable sentinel string and
-- the assertion FAILS instead of erroring.
--
-- ⛔ Assertions built on this MUST use expect_op 'eq' / 'ne' / 'contains'. golden.compare
--    RAISES on gt/gte/lt/lte when an operand is non-numeric, so a 'MISSING:…' sentinel under
--    'gt' would produce an ERROR — the very thing this helper exists to avoid.
CREATE OR REPLACE FUNCTION golden.probe_scalar(p_sql text)
RETURNS text
LANGUAGE plpgsql
AS $fn$
DECLARE v_out text;
BEGIN
  EXECUTE p_sql INTO v_out;
  RETURN v_out;
EXCEPTION
  WHEN undefined_table OR undefined_column OR undefined_function OR undefined_object THEN
    RETURN 'MISSING: ' || SQLERRM;
  WHEN OTHERS THEN
    RETURN 'ERROR: ' || SQLERRM;
END
$fn$;

COMMENT ON FUNCTION golden.probe_scalar(text) IS
  'PRD-110 golden harness: EXECUTE a scalar probe whose target relation may not exist yet, '
  'returning a MISSING:/ERROR: sentinel instead of raising. Lets a fixture be written and run '
  'RED before the object it proves exists (LAW 1). Use only with eq/ne/contains expect_ops.';

-- ---------------------------------------------------------------------------------------
INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, baseline_status, notes, enabled, scenario_sql)
VALUES (
  34,
  'Nightly shadow diff vs v19 is non-vacuous (P2 D-12)',
  'Leg 51 STEP R: v_shadow_vs_live_plan_v3 reads pod_refill_plan_shadow (0 rows, never written by '
    || 'engine_add_pod_v3). The Phase-2 gate object could return "no differences" forever.',
  'P2',
  DATE '2030-02-04',
  'failing_expected',
  'Runs BOTH engines on one synthetic plan_date, recomputes the whole diff independently from '
    || 'pod_refills / pod_refills_shadow / blocked_demand into scratch key ''truth'', then requires the '
    || 'canonical diff object to reproduce every one of those numbers. seq 1-9 are the non-vacuity '
    || 'guards; seq 60/61 pin the plan-grain view''s emptiness as by-design.',
  true,
$scen$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);

DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- Baseline FIRST, before this fixture writes anything (RISK 65: scope residue tripwires to
-- this run's own window so a concurrent cron-44 firing cannot flake them).
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'before', jsonb_build_object(
  't0',      clock_timestamp()::text,
  'df_open', (SELECT count(*) FROM public.driver_feedback WHERE resolved = false),
  'prp',     (SELECT count(*) FROM public.pod_refill_plan),
  'prps',    (SELECT count(*) FROM public.pod_refill_plan_shadow),
  'rpo',     (SELECT count(*) FROM public.refill_plan_output),
  'bd',      (SELECT count(*) FROM public.blocked_demand));

DELETE FROM public.machines_to_visit WHERE plan_date = {{plan_date}};
INSERT INTO public.machines_to_visit
 (plan_date, machine_id, official_name, status, add_source, is_included, service_track,
  picked_reasons, active_intent_count, is_ramping, priority_score, picked_at, picked_by,
  venue_group, location_type, confirmed_at, confirmed_by)
SELECT {{plan_date}}, machine_id, official_name, 'picked', 'operator', true,
       CASE WHEN venue_group='VOX' THEN 'vox' ELSE 'main' END,
       ARRAY['golden_fixture_34']::text[], 0, false, 100, now(),
       '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid, venue_group, location_type,
       now(), 'golden_fixture_34'
FROM public.machines
 WHERE official_name IN ('MPMCC-1058-0000-R0','AMZ-1046-2406-O1');

-- v19 writes LIVE pod_refills for this synthetic date; v3 writes pod_refills_shadow.
-- Both read the same picked set, so the two answers are comparable line for line.
SELECT public.engine_add_pod({{plan_date}}, 7);
SELECT golden.run_engine_v3_if_built({{fixture_id}}, {{plan_date}}, 7);

-- THE INDEPENDENT RECOMPUTATION. Every canonical-object assertion below compares against
-- these numbers, never against the object itself. pod_product_id is joined with
-- IS NOT DISTINCT FROM because an empty shelf carries NULL there and `=` would drop the row
-- silently — which is precisely how a diff goes quietly wrong.
INSERT INTO golden.scratch (fixture_id, key, value)
WITH s AS (
  SELECT machine_id, shelf_id, pod_product_id, qty
    FROM public.pod_refills_shadow
   WHERE run_id = golden.v3_run_id({{fixture_id}}) AND plan_date = {{plan_date}}
), v AS (
  SELECT machine_id, shelf_id, pod_product_id, qty
    FROM public.pod_refills
   WHERE plan_date = {{plan_date}}
), j AS (
  SELECT COALESCE(s.machine_id, v.machine_id)         AS machine_id,
         COALESCE(s.shelf_id, v.shelf_id)             AS shelf_id,
         COALESCE(s.pod_product_id, v.pod_product_id) AS pod_product_id,
         s.qty AS qty_v3, v.qty AS qty_v19
    FROM s FULL JOIN v
      ON  s.machine_id     =                v.machine_id
      AND s.shelf_id       =                v.shelf_id
      AND s.pod_product_id IS NOT DISTINCT FROM v.pod_product_id
)
SELECT {{fixture_id}}, 'truth', jsonb_build_object(
  'lines_v3',      (SELECT count(*) FROM s),
  'lines_v19',     (SELECT count(*) FROM v),
  'units_v3',      (SELECT COALESCE(sum(qty),0) FROM s),
  'units_v19',     (SELECT COALESCE(sum(qty),0) FROM v),
  'dup_v3',        (SELECT COALESCE(sum(c-1),0) FROM (SELECT count(*) c FROM s GROUP BY machine_id, shelf_id, pod_product_id) d),
  'dup_v19',       (SELECT COALESCE(sum(c-1),0) FROM (SELECT count(*) c FROM v GROUP BY machine_id, shelf_id, pod_product_id) d),
  'join_rows',     (SELECT count(*) FROM j),
  'n_match',       (SELECT count(*) FROM j WHERE qty_v3 IS NOT NULL AND qty_v19 IS NOT NULL AND qty_v3 =  qty_v19),
  'n_qty_diff',    (SELECT count(*) FROM j WHERE qty_v3 IS NOT NULL AND qty_v19 IS NOT NULL AND qty_v3 <> qty_v19),
  'n_v3_only',     (SELECT count(*) FROM j WHERE qty_v19 IS NULL),
  'n_v19_only',    (SELECT count(*) FROM j WHERE qty_v3  IS NULL),
  'sum_abs_delta', (SELECT COALESCE(sum(abs(COALESCE(qty_v3,0) - COALESCE(qty_v19,0))),0) FROM j),
  'machines',      (SELECT count(DISTINCT machine_id) FROM j),
  'blocked_v3',    (SELECT count(*) FROM public.v_blocked_demand_shadow_v3 b
                     WHERE b.run_id = golden.v3_run_id({{fixture_id}}) AND b.plan_date = {{plan_date}}),
  'blocked_v19',   (SELECT count(*) FROM public.blocked_demand b WHERE b.plan_date = {{plan_date}}),
  'plan_grain_rows',(SELECT count(*) FROM public.v_shadow_vs_live_plan_v3 WHERE plan_date = {{plan_date}}));
$scen$
);

-- ---------------------------------------------------------------------------------------
-- ASSERTIONS
-- seq 1-9   : non-vacuity + join-key sanity. GREEN at baseline — if these ever go red the
--             later numbers mean nothing (the S-48/S-52 discipline, applied up front).
-- seq 10-33 : the canonical diff object. RED at baseline via the MISSING: sentinel.
-- seq 60-61 : the plan-grain view's emptiness, pinned as by-design.
-- seq 87-99 : standard LAW 4 / LAW 12 / ADR 8.3 tripwires.
-- ---------------------------------------------------------------------------------------
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required) VALUES

(34, 1, 'NON-VACUITY: the v3 engine actually ran and recorded a run_id (everything downstream is conditioned on this)',
 $a$SELECT golden.v3_run_id({{fixture_id}})::text$a$, 'not_null', NULL, 'P2'),

(34, 2, 'NON-VACUITY: the v3 engine reported no error',
 $a$SELECT COALESCE((SELECT value->>'error' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='engine_v3'),'none')$a$,
 'eq', 'none', 'P2'),

(34, 3, 'NON-VACUITY: the SHADOW side of the comparison is non-empty (v3 produced lines)',
 $a$SELECT (SELECT (value->>'lines_v3')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth')::text$a$,
 'gt', '0', 'P2'),

(34, 4, 'NON-VACUITY: the LIVE side of the comparison is non-empty (v19 produced lines)',
 $a$SELECT (SELECT (value->>'lines_v19')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth')::text$a$,
 'gt', '0', 'P2'),

(34, 5, 'NON-VACUITY: v3 proposed a positive number of units — a diff over two zero-plans would prove nothing',
 $a$SELECT (SELECT (value->>'units_v3')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth')::text$a$,
 'gt', '0', 'P2'),

(34, 6, 'NON-VACUITY: v19 proposed a positive number of units',
 $a$SELECT (SELECT (value->>'units_v19')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth')::text$a$,
 'gt', '0', 'P2'),

(34, 7, 'JOIN KEY SANITY: (machine, shelf, pod_product) is unique in the shadow run — a duplicate would fan the FULL JOIN out and inflate every diff number',
 $a$SELECT (SELECT (value->>'dup_v3')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth')::text$a$,
 'eq', '0', 'P2'),

(34, 8, 'JOIN KEY SANITY: (machine, shelf, pod_product) is unique in the live plan for this date',
 $a$SELECT (SELECT (value->>'dup_v19')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth')::text$a$,
 'eq', '0', 'P2'),

(34, 9, 'NON-VACUITY: the two engines DISAGREE somewhere — if every line matched, an identity view would pass every assertion below and prove nothing',
 $a$SELECT ((SELECT (value->>'n_qty_diff')::int + (value->>'n_v3_only')::int + (value->>'n_v19_only')::int
            FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth'))::text$a$,
 'gt', '0', 'P2'),

(34, 10, 'CANONICAL DIFF: v_engine_diff_v3 returns exactly the independently computed FULL-JOIN row count for this plan_date',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT count(*) FROM public.v_engine_diff_v3 WHERE plan_date = {{plan_date}})
         = (SELECT (value->>'join_rows')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth'))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 11, 'CANONICAL DIFF: total v3 units in the diff equal the shadow table''s own total (no line dropped, none double counted)',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT COALESCE(sum(qty_v3),0) FROM public.v_engine_diff_v3 WHERE plan_date = {{plan_date}})
         = (SELECT (value->>'units_v3')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth'))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 12, 'CANONICAL DIFF: total v19 units in the diff equal the live table''s own total',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT COALESCE(sum(qty_v19),0) FROM public.v_engine_diff_v3 WHERE plan_date = {{plan_date}})
         = (SELECT (value->>'units_v19')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth'))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 13, 'CANONICAL DIFF: diff_kind=''match'' count is exact',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT count(*) FROM public.v_engine_diff_v3 WHERE plan_date = {{plan_date}} AND diff_kind = 'match')
         = (SELECT (value->>'n_match')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth'))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 14, 'CANONICAL DIFF: diff_kind=''qty_diff'' count is exact',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT count(*) FROM public.v_engine_diff_v3 WHERE plan_date = {{plan_date}} AND diff_kind = 'qty_diff')
         = (SELECT (value->>'n_qty_diff')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth'))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 15, 'CANONICAL DIFF: diff_kind=''v3_only'' count is exact (a line v3 proposes and v19 does not)',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT count(*) FROM public.v_engine_diff_v3 WHERE plan_date = {{plan_date}} AND diff_kind = 'v3_only')
         = (SELECT (value->>'n_v3_only')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth'))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 16, 'CANONICAL DIFF: diff_kind=''v19_only'' count is exact (a line v3 DROPS — the PRD-109 Extra Gum absence class, which is the diff''s whole reason to exist)',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT count(*) FROM public.v_engine_diff_v3 WHERE plan_date = {{plan_date}} AND diff_kind = 'v19_only')
         = (SELECT (value->>'n_v19_only')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth'))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 17, 'CANONICAL DIFF: the four diff_kind buckets partition the result set exactly (no row uncategorised, none counted twice)',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT count(*) FROM public.v_engine_diff_v3 WHERE plan_date = {{plan_date}}
              AND diff_kind IN ('match','qty_diff','v3_only','v19_only'))
         = (SELECT count(*) FROM public.v_engine_diff_v3 WHERE plan_date = {{plan_date}}))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 18, 'CANONICAL DIFF: sum of abs_qty_delta equals the independently computed total absolute movement',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT COALESCE(sum(abs_qty_delta),0) FROM public.v_engine_diff_v3 WHERE plan_date = {{plan_date}})
         = (SELECT (value->>'sum_abs_delta')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth'))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 19, 'CANONICAL DIFF: qty_delta = COALESCE(qty_v3,0) - COALESCE(qty_v19,0) on EVERY row (0 violations) — a NULL-swallowing delta is how a one-sided line reads as agreement',
 $a$SELECT golden.probe_scalar($q$
   SELECT count(*)::text FROM public.v_engine_diff_v3
    WHERE plan_date = {{plan_date}}
      AND qty_delta IS DISTINCT FROM (COALESCE(qty_v3,0) - COALESCE(qty_v19,0))
 $q$)$a$, 'eq', '0', 'P2'),

(34, 20, 'CANONICAL DIFF: abs_qty_delta = abs(qty_delta) on every row (0 violations)',
 $a$SELECT golden.probe_scalar($q$
   SELECT count(*)::text FROM public.v_engine_diff_v3
    WHERE plan_date = {{plan_date}} AND abs_qty_delta IS DISTINCT FROM abs(qty_delta)
 $q$)$a$, 'eq', '0', 'P2'),

(34, 21, 'CANONICAL DIFF: every row carries the shadow run''s engine_tag or is a v19_only row (the diff must never guess which engine produced a line — ADR §2)',
 $a$SELECT golden.probe_scalar($q$
   SELECT count(*)::text FROM public.v_engine_diff_v3
    WHERE plan_date = {{plan_date}}
      AND NOT (diff_kind = 'v19_only' OR engine_tag = 'engine_add_pod_v3')
 $q$)$a$, 'eq', '0', 'P2'),

(34, 22, 'CANONICAL DIFF: the view resolves ONE shadow run per plan_date (the LATEST). 117 runs exist across the synthetic dates; a view that unioned them would multiply every count',
 $a$SELECT golden.probe_scalar($q$
   SELECT (SELECT count(DISTINCT run_id) FROM public.v_engine_diff_v3
            WHERE plan_date = {{plan_date}} AND run_id IS NOT NULL)::text
 $q$)$a$, 'eq', '1', 'P2'),

(34, 23, 'CANONICAL DIFF: the run it resolved is THIS fixture''s run (the latest produced_at), not an earlier one',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT DISTINCT run_id FROM public.v_engine_diff_v3
             WHERE plan_date = {{plan_date}} AND run_id IS NOT NULL)
         = golden.v3_run_id({{fixture_id}}))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 30, 'PER-MACHINE ROLLUP: one row per machine appearing on either side',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT count(*) FROM public.v_engine_diff_v3_by_machine WHERE plan_date = {{plan_date}})
         = (SELECT (value->>'machines')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth'))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 31, 'PER-MACHINE ROLLUP: lines_v3 sums to the shadow line total',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT COALESCE(sum(lines_v3),0) FROM public.v_engine_diff_v3_by_machine WHERE plan_date = {{plan_date}})
         = (SELECT (value->>'lines_v3')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth'))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 32, 'PER-MACHINE ROLLUP: lines_v19 sums to the live line total',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT COALESCE(sum(lines_v19),0) FROM public.v_engine_diff_v3_by_machine WHERE plan_date = {{plan_date}})
         = (SELECT (value->>'lines_v19')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth'))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 33, 'PER-MACHINE ROLLUP: units_v3 sums to the shadow unit total',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT COALESCE(sum(units_v3),0) FROM public.v_engine_diff_v3_by_machine WHERE plan_date = {{plan_date}})
         = (SELECT (value->>'units_v3')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth'))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 34, 'PER-MACHINE ROLLUP: units_v19 sums to the live unit total',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT COALESCE(sum(units_v19),0) FROM public.v_engine_diff_v3_by_machine WHERE plan_date = {{plan_date}})
         = (SELECT (value->>'units_v19')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth'))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 35, 'PER-MACHINE ROLLUP: blocked_v3 sums to the shadow blocked-demand count (BUILD SPEC P2 names "blocked" as a diff dimension — LAW 5 lives here)',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT COALESCE(sum(blocked_v3),0) FROM public.v_engine_diff_v3_by_machine WHERE plan_date = {{plan_date}})
         = (SELECT (value->>'blocked_v3')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth'))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 36, 'PER-MACHINE ROLLUP: blocked_v19 sums to the live blocked-demand count for this plan_date',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT COALESCE(sum(blocked_v19),0) FROM public.v_engine_diff_v3_by_machine WHERE plan_date = {{plan_date}})
         = (SELECT (value->>'blocked_v19')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth'))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 37, 'PER-MACHINE ROLLUP agrees with the LINE GRAIN machine by machine (0 mismatching machines) — the rollup must be an aggregate of the same rows, not a second query with its own predicates',
 $a$SELECT golden.probe_scalar($q$
   SELECT count(*)::text FROM (
     SELECT machine_id, count(*) l3, COALESCE(sum(qty_v3),0) u3, COALESCE(sum(qty_v19),0) u19
       FROM public.v_engine_diff_v3 WHERE plan_date = {{plan_date}} GROUP BY machine_id) g
   FULL JOIN (
     SELECT machine_id, lines_v3 + lines_v19_only l3, units_v3 u3, units_v19 u19
       FROM public.v_engine_diff_v3_by_machine WHERE plan_date = {{plan_date}}) m
   USING (machine_id)
   WHERE g.u3 IS DISTINCT FROM m.u3 OR g.u19 IS DISTINCT FROM m.u19
 $q$)$a$, 'eq', '0', 'P2'),

(34, 40, 'NIGHTLY SUMMARY: exactly one row per plan_date — this is what the nightly report reads',
 $a$SELECT golden.probe_scalar($q$
   SELECT (SELECT count(*) FROM public.v_engine_diff_v3_summary WHERE plan_date = {{plan_date}})::text
 $q$)$a$, 'eq', '1', 'P2'),

(34, 41, 'NIGHTLY SUMMARY: units_delta = units_v3 - units_v19, signed (the direction matters: v3 over- or under-planning is a different problem)',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT units_delta FROM public.v_engine_diff_v3_summary WHERE plan_date = {{plan_date}})
         = (SELECT (value->>'units_v3')::int - (value->>'units_v19')::int
              FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth'))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 42, 'NIGHTLY SUMMARY: machines_compared equals the independently counted machine set',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT machines_compared FROM public.v_engine_diff_v3_summary WHERE plan_date = {{plan_date}})
         = (SELECT (value->>'machines')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth'))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 43, 'NIGHTLY SUMMARY: lines_total equals the line-grain row count (the summary is an aggregate of the same view, not a parallel derivation)',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT lines_total FROM public.v_engine_diff_v3_summary WHERE plan_date = {{plan_date}})
         = (SELECT count(*) FROM public.v_engine_diff_v3 WHERE plan_date = {{plan_date}}))::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 44, 'NIGHTLY SUMMARY: is_vacuous is FALSE here, and the column EXISTS — the object must be able to say "I compared nothing" out loud rather than reporting zero differences',
 $a$SELECT golden.probe_scalar($q$
   SELECT (SELECT is_vacuous FROM public.v_engine_diff_v3_summary WHERE plan_date = {{plan_date}})::text
 $q$)$a$, 'eq', 'false', 'P2'),

(34, 60, 'BY DESIGN, PINNED: the PLAN-GRAIN v_shadow_vs_live_plan_v3 returns 0 rows for this date. engine_add_pod_v3 writes pod_refills_shadow, never pod_refill_plan_shadow, so that view is empty until cutover. ⛔ Its 0 is NOT evidence the engines agree.',
 $a$SELECT (SELECT (value->>'plan_grain_rows')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='truth')::text$a$,
 'eq', '0', 'P2'),

(34, 61, 'THE TRAP, STATED AS ONE ASSERTION: the canonical diff is NON-EMPTY on exactly the date where the plan-grain view is empty. This single line is the difference between a real comparison and a vacuous green.',
 $a$SELECT golden.probe_scalar($q$
   SELECT ((SELECT count(*) FROM public.v_engine_diff_v3 WHERE plan_date = {{plan_date}}) > 0
       AND (SELECT count(*) FROM public.v_shadow_vs_live_plan_v3 WHERE plan_date = {{plan_date}}) = 0)::text
 $q$)$a$, 'eq', 'true', 'P2'),

(34, 87, 'LAW 4 tripwire: engine_add_pod_v3 wrote NOTHING to the LIVE public.pod_refills at this plan_date (delta measured inside run_engine_v3_if_built, after v19 and before v3)',
 $a$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run'
   ELSE ((SELECT count(*) FROM public.pod_refills WHERE plan_date = {{plan_date}})
       = (SELECT (value->>'pr_live_before')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='engine_v3'))::text END$a$,
 'eq', 'true', 'P2'),

(34, 90, 'S-08 tripwire: open driver_feedback count unchanged by the fixture',
 $a$SELECT ((SELECT count(*) FROM public.driver_feedback WHERE resolved = false)
        = (SELECT (value->>'df_open')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,
 'eq', 'true', 'P1'),

(34, 92, 'LAW 12 tripwire: this transaction wrote NO refill_plan_output row on any date other than a registered synthetic fixture plan_date',
 $a$SELECT count(*)::text FROM public.refill_plan_output x
  WHERE golden.written_by_this_txn(x.xmin) AND NOT (x.plan_date >= DATE '2030-01-01'
        AND x.plan_date IN (SELECT f.plan_date FROM golden.fixtures f WHERE f.plan_date IS NOT NULL))$a$,
 'eq', '0', 'P1'),

(34, 93, 'LAW 12 tripwire: this transaction wrote NO pod_refills row on any date other than a registered synthetic fixture plan_date',
 $a$SELECT count(*)::text FROM public.pod_refills x
  WHERE golden.written_by_this_txn(x.xmin) AND NOT (x.plan_date >= DATE '2030-01-01'
        AND x.plan_date IN (SELECT f.plan_date FROM golden.fixtures f WHERE f.plan_date IS NOT NULL))$a$,
 'eq', '0', 'P1'),

(34, 97, 'ADR 8.3 tripwire: blocked_demand row count unchanged across this run (shadow blocked demand is a VIEW)',
 $a$SELECT ((SELECT count(*) FROM public.blocked_demand)
        = (SELECT (value->>'bd')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,
 'eq', 'true', 'P1'),

(34, 98, 'ADR 8.3 tripwire: pod_refill_plan row count unchanged (absolute — no fixture in this suite may write the live plan table at all)',
 $a$SELECT ((SELECT count(*) FROM public.pod_refill_plan)
        = (SELECT (value->>'prp')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,
 'eq', 'true', 'P1'),

(34, 99, 'pod_refill_plan_shadow row count unchanged — pins the premise of this whole fixture: v3 does NOT write the plan-grain shadow table',
 $a$SELECT ((SELECT count(*) FROM public.pod_refill_plan_shadow)
        = (SELECT (value->>'prps')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,
 'eq', 'true', 'P1');
