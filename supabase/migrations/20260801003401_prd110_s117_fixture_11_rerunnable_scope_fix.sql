-- PRD-110 · S-117 / S7 — FIXTURE 11 MADE RE-RUNNABLE
--
-- Falsified by test at leg 78: leg 77's pointer hoped `ux_realloc_v3_pair` would
-- make a second run of fixture 11 idempotent. It cannot, and for the opposite
-- reason to the one guessed: the composed_run_id is FRESH on every run, so the
-- pair index never collides and every run APPENDS a complete second set of
-- proposals. Two identical 4-row batches were observed (23:44Z leg 77, 00:26Z
-- leg 78) and the fixture read 31/39, with the exact doubling signature
-- (seq 18 got 2 want 1, seq 22 got 6 want 3, seq 35 got 4 want 0).
--
-- ⛔ NOT a fixture 1 regression: fixture 1's scenario references neither
--    reallocation_proposals_v3 nor 2030-01-12. Proven before this fix was written.
--
-- THE FIX IS A SCOPE TIGHTENING IN THE SCENARIO, NOT AN ASSERTION EDIT.
-- Both reads asked "what is on this plan_date"; they now ask "what did THIS run
-- produce". All 39 assertion rows are left byte-identical - no expect value is
-- weakened, no op is loosened, nothing is deleted (S-103 / S-122 discipline).
-- The assertions get MORE precise: they now measure this run's output instead of
-- the accumulated history of every run that ever touched the date.

SET LOCAL statement_timeout = '120s';

UPDATE golden.fixtures SET scenario_sql = replace(scenario_sql,
$old$      EXECUTE $x$ SELECT count(*) FROM public.reallocation_proposals_v3
                   WHERE plan_date = DATE '2030-01-12' $x$ INTO n;$old$,
$new$      -- ⭐ S-117: scoped to THIS run. "The dry run wrote no row" is a claim
      --    about this run, not about the whole plan_date - counting the date
      --    made every re-run inherit the previous run's rows.
      EXECUTE $x$ SELECT count(*) FROM public.reallocation_proposals_v3
                   WHERE plan_date = DATE '2030-01-12'
                     AND composed_run_id = $1 $x$ INTO n USING comp;$new$)
WHERE fixture_id = 11;

UPDATE golden.fixtures SET scenario_sql = replace(scenario_sql,
$old$        FROM public.reallocation_proposals_v3 WHERE plan_date = DATE '2030-01-12' $x$ INTO props;$old$,
$new$        FROM public.reallocation_proposals_v3
         WHERE plan_date = DATE '2030-01-12'
           AND composed_run_id = $1 $x$ INTO props USING comp;$new$)
WHERE fixture_id = 11;

-- ⛔ A replace() that matches nothing is a SILENT no-op. Prove both landed.
DO $guard$
DECLARE s text; n_scoped int;
BEGIN
  SELECT scenario_sql INTO s FROM golden.fixtures WHERE fixture_id = 11;
  n_scoped := (length(s) - length(replace(s, 'AND composed_run_id = $1', ''))) / length('AND composed_run_id = $1');
  IF n_scoped <> 2 THEN
    RAISE EXCEPTION 'fixture 11 scope fix did not apply: expected 2 scoped reads, found %', n_scoped;
  END IF;
  IF s LIKE '%WHERE plan_date = DATE ''2030-01-12'' $x$ INTO props;%' THEN
    RAISE EXCEPTION 'fixture 11 props read is still date-scoped';
  END IF;
END
$guard$;
