-- PRD-110 leg 165 · D-34 · S-334: the non-vacuity probe was anchored to a MOMENT
--
-- Migration 20260809050000 proved the swap by counting rows in pipeline_runs_v3 carrying
-- the runner's note. That count is CUMULATIVE and the table never gets cleaned, so the
-- first green run pins it green FOREVER: if a later leg reverted the runner to calling
-- engine_add_pod_v3 directly, seq 27/28 would keep passing on receipts written today.
--
-- ⛔ THIS IS THE S-204 CLASS -- an assertion anchored to a moment rather than to an
--    invariant -- and it is the specific class that makes the S7 triple unachievable.
--    Caught before the fix landed, so it never got to bank a false green.
--
-- ⭐ THE FIX. Compare against THIS run's own clock: the runner returns 'ran_at'
--    (v_started), so a receipt only counts if it was started at or after the invocation
--    this very scenario made. Same shape as fixture 37 seq 13's "DELTA across the run".
--    Now the probe re-proves the swap on every single execution.
--
-- golden.scratch is PK (fixture_id, key), so this writes a NEW key rather than
-- re-inserting 'swap', and seq 27/28 are repointed at it.

UPDATE golden.fixtures
SET scenario_sql = scenario_sql || $append$

-- ---------------------------------------------------------------------------
-- (8) S-334. NON-VACUITY OF THE SWAP, PER RUN.
--     A cumulative count cannot distinguish "the runner went through the pipeline
--     just now" from "some run did, once, weeks ago". Anchor to the runner's own
--     ran_at so the proof expires with the run that earned it.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT 53, 'swap_per_run', jsonb_build_object(
  'sat_receipts_this_run', CASE
     WHEN to_regclass('public.pipeline_runs_v3') IS NULL THEN -1
     WHEN (SELECT value->>'ran_at' FROM golden.scratch
            WHERE fixture_id = 53 AND key = 'sat_run') IS NULL THEN -1
     ELSE (SELECT count(*) FROM public.pipeline_runs_v3 p
            WHERE p.note = 'golden_fixture_53_saturday'
              AND p.started_at >= (SELECT (value->>'ran_at')::timestamptz
                                     FROM golden.scratch
                                    WHERE fixture_id = 53 AND key = 'sat_run')) END,
  'fri_receipts_this_run', CASE
     WHEN to_regclass('public.pipeline_runs_v3') IS NULL THEN -1
     WHEN (SELECT value->>'ran_at' FROM golden.scratch
            WHERE fixture_id = 53 AND key = 'fri_run') IS NULL THEN -1
     ELSE (SELECT count(*) FROM public.pipeline_runs_v3 p
            WHERE p.note = 'golden_fixture_53_friday'
              AND p.started_at >= (SELECT (value->>'ran_at')::timestamptz
                                     FROM golden.scratch
                                    WHERE fixture_id = 53 AND key = 'fri_run')) END);
$append$
WHERE fixture_id = 53;

-- Repoint the two non-vacuity assertions at the per-run probe. The cumulative 'swap'
-- key stays in the scenario as a harmless diagnostic; nothing asserts on it any more.
UPDATE golden.assertions
   SET check_sql = 'SELECT (value->>''sat_receipts_this_run'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''swap_per_run''',
       description = 'NON-VACUITY OF D-34, PER RUN (S-334): the runner''s Saturday night left a pipeline receipt started at or after THIS scenario''s own invocation -- proof the runner goes THROUGH run_pipeline_v3 on every execution, not merely that it did so once. A cumulative count would stay green forever after the first pass.'
 WHERE fixture_id = 53 AND seq = 27;

UPDATE golden.assertions
   SET check_sql = 'SELECT (value->>''fri_receipts_this_run'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''swap_per_run''',
       description = 'NON-VACUITY OF D-34, PER RUN (S-334): and so did the Friday night. A refusal night still writes its pipeline receipt, so the swap stays observable even when nothing is planned.'
 WHERE fixture_id = 53 AND seq = 28;
