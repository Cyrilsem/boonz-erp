SET LOCAL statement_timeout = '120s';

-- PRD-110 fixture 57 seq 21 restatement.
--
-- ⛔ plan_edits_v3 refuses DELETE, so fixture 57's reclaim SUPERSEDES its old
--    rows instead of removing them. The superseded 'FX57 I%' population
--    therefore grows by 2 on every run: the assertion read 2 on run one and 4
--    on run two. It was counting RUNS, not proving anything about the subject.
--
-- ⭐ The invariant that is actually true on every run, and is strictly stronger:
--    at least two self-corrected edits exist AND not one of them is still live.
--    Per S-103 an assertion edit is TWO fields; expect_op moves with check_sql.
--
-- ⭐ LESSON: run every new fixture TWICE, COMMITTED, before calling it green.
--    A first run cannot distinguish "correct" from "correct once".
UPDATE golden.assertions
   SET check_sql = $q$SELECT (count(*) FILTER (WHERE superseded_at IS NOT NULL) >= 2
                          AND count(*) FILTER (WHERE superseded_at IS NULL)  = 0)::text
                     FROM public.plan_edits_v3 WHERE reason LIKE 'FX57 I%'$q$,
       expect_op = 'eq',
       expect    = 'true',
       description = '⛔ NON-VACUITY for seq 20: the self-corrected edits exist, at least two of them, and NOT ONE is still live - stated so it cannot drift with the number of times the fixture has been run'
 WHERE fixture_id = 57 AND seq = 21;

DO $chk$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE fixture_id = 57 AND seq = 21 AND expect = 'true' AND check_sql LIKE '%superseded_at IS NULL%';
  IF v_n <> 1 THEN RAISE EXCEPTION 'seq 21 restatement did not land (n=%)', v_n; END IF;
END $chk$;
