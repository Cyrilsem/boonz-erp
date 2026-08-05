-- PRD-110 P3.7 — fixture 51 vacuous-green hardening.
-- The RED baseline read 5/53 and THREE of those greens were weak: seq 26 and 28
-- measure the coin-flip premise, and with no pipeline built the base run is the
-- ONLY run on the date, so "one distinct produced_at" and "the implicit pick is
-- the engine run" are both trivially true. An assertion that is green before its
-- engine exists tests nothing (leg 70, S-107). Both probes now emit the distinct
-- 'no_pipeline' sentinel unless a pipeline actually planned a run, so they can
-- only go green on the real, non-trivial state: a composed run EXISTS on the
-- date, ties with the base on produced_at, and the implicit pick STILL lands on
-- the base.
-- Seq 49/50/51 stay green by design: they are live-state tripwires (LAW 4/11)
-- that must hold at every moment of the build, red or green.

UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
$old$  SELECT s.run_id, s.engine_tag INTO pick, tag
    FROM public.pod_refills_shadow s
   WHERE s.plan_date = DATE '2030-02-21'
   ORDER BY s.produced_at DESC, s.run_id DESC LIMIT 1;
  v := v || jsonb_build_object('implicit_tag', COALESCE(tag,'none'));

  SELECT count(DISTINCT s.produced_at) INTO n
    FROM public.pod_refills_shadow s
   WHERE s.plan_date = DATE '2030-02-21' AND s.produced_at = now();
  v := v || jsonb_build_object('tied_produced_at_rows_in_this_tx',
        (SELECT count(*) FROM public.pod_refills_shadow s
          WHERE s.plan_date = DATE '2030-02-21' AND s.produced_at = now()));
  v := v || jsonb_build_object('distinct_produced_at_in_this_tx', n);

  SELECT (value->>'planned_run_id')::uuid INTO composed
    FROM golden.scratch WHERE fixture_id = 51 AND key = 'p1';
  v := v || jsonb_build_object('implicit_equals_planned',
        CASE WHEN composed IS NULL THEN 'no_pipeline'
             ELSE (pick = composed)::text END);$old$,
$new$  SELECT (value->>'planned_run_id')::uuid INTO composed
    FROM golden.scratch WHERE fixture_id = 51 AND key = 'p1';

  SELECT s.run_id, s.engine_tag INTO pick, tag
    FROM public.pod_refills_shadow s
   WHERE s.plan_date = DATE '2030-02-21'
   ORDER BY s.produced_at DESC, s.run_id DESC LIMIT 1;

  SELECT count(DISTINCT s.produced_at) INTO n
    FROM public.pod_refills_shadow s
   WHERE s.plan_date = DATE '2030-02-21' AND s.produced_at = now();

  -- ⛔ Every reading below is gated on a pipeline having actually planned a run.
  --    Without that gate the base run is the only run on the date and all three
  --    read TRUE for a reason that has nothing to do with the defect.
  v := v || jsonb_build_object(
    'implicit_tag',
      CASE WHEN composed IS NULL THEN 'no_pipeline' ELSE COALESCE(tag,'none') END,
    'tied_produced_at_rows_in_this_tx',
      CASE WHEN composed IS NULL THEN -1 ELSE
        (SELECT count(*) FROM public.pod_refills_shadow s
          WHERE s.plan_date = DATE '2030-02-21' AND s.produced_at = now()) END,
    'distinct_produced_at_in_this_tx',
      CASE WHEN composed IS NULL THEN -1 ELSE n END,
    'implicit_equals_planned',
      CASE WHEN composed IS NULL THEN 'no_pipeline' ELSE (pick = composed)::text END);$new$)
 WHERE fixture_id = 51;

UPDATE golden.assertions
   SET description = 'PREMISE: with a composed run present, base and composed share ONE produced_at -- the tie the implicit pick collapses on is real'
 WHERE fixture_id = 51 AND seq = 26;

UPDATE golden.assertions
   SET description = 'THE DEFECT, SHOWN: even with a composed run sitting on the date, an implicit NULL-source stitch picks the RAW ENGINE run here'
 WHERE fixture_id = 51 AND seq = 28;
