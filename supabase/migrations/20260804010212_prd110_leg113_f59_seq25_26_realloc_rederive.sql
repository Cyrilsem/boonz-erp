-- PRD-110 leg 113 · S-200 red set · fixture 59 seq 25 + 26 (class (B), re-derived live and
-- CONFIRMED -- and the cause is sharper than S-200 stated)
--
-- WHY 25/26 WERE RED, MEASURED LIVE THIS LEG:
--   seq 25  reallocation.fixture_unmatched  eq 18 -> actual 33
--   seq 26  reallocation.fixture_undecided  eq  6 -> actual 11
--
--   ⭐ Fixture 59 PLANTS NOTHING into reallocation_proposals_v3. It plants only into
--      feedback_proposals_v3 and picker_weight_proposals_v3, on its own 1999 sentinel date,
--      and deletes both populations again. The reallocation family it asserts over is
--      entirely AMBIENT.
--
--   ⛔ AND THAT AMBIENT POPULATION IS APPEND-ONLY, GROWN BY ANOTHER FIXTURE. Every row lives
--      on plan_date 2030-01-12 and is keyed by base_run_id / composed_run_id. Measured:
--        44 rows · 11 distinct base_run_id · proposed_at spanning 2026-07-31 .. 2026-08-03
--        33 unclaimed + 11 proposed  ==  11 runs x (3 unclaimed + 1 proposed)
--      The producer is FIXTURE 11 (mid-plan machine drop / P3.8 freed-unit re-offer), which
--      does not reclaim its proposals. ⭐ So fixture 59 pinned a constant over a population
--      that fixture 11 grows by exactly 4 on EVERY run. 18/6 was the photograph at 6 runs.
--      This is class (B), but the drift is not fleet turnover -- it is THE HARNESS ITSELF.
--      ⛔ Bumping 18 -> 33 would re-arm the same trap for run 12.
--
-- WHAT 25/26 ARE ACTUALLY FOR (their own prose): "unclaimed maps to unmatched -- an offer
-- that found no target was never put to CS", and "those unmatched rows are NOT counted as
-- undecided". ⭐ That is a claim about v_proposal_acceptance_v3's BUCKET MAPPING. The counts
-- 18 and 6 were only ever the vehicle. Re-express the mapping and the vehicle stops rotting.
--
-- REMEDY (the class-(B) idiom, proven at 2/64 and 40/8): re-derive the RELATIONSHIP off the
-- source table instead of pinning a count.
--   seq 25 -> AFTER-snapshot fixture_unmatched  ==  live count(status='unclaimed'   , >= epoch)
--   seq 26 -> AFTER-snapshot fixture_undecided  ==  live count(status IN (pending,proposed))
--   seq 51 -> NON-VACUITY: fixture_unmatched > 0   (else seq 25 is 0 = 0)
--   seq 52 -> NON-VACUITY: fixture_undecided > 0   (else seq 26 is 0 = 0)
--   seq 53 -> DISJOINTNESS, stated outright: undecided + unmatched <= fixture_rows AND
--             undecided < fixture_rows. This is the half the prose claimed and the old
--             constants never actually tested.
--
-- ⛔ NOT RELAXED TO gte 0. That is the S-48 / S-52 / S-55 vacuity mode, burned four times.
--    `gt 0` here is the POSITIVE non-vacuity form, and 51/52 exist precisely so the two new
--    equalities can never be satisfied by two zeros.
--
-- NEGATIVE CONTROL (why this still catches the regression it was written for):
--   if the CASE ever remapped 'unclaimed' -> 'undecided', fixture_unmatched collapses to 0,
--   which fails seq 51 outright AND fails seq 25 (0 <> 33); fixture_undecided becomes 44,
--   which fails seq 26 and seq 53. If 'unclaimed' -> 'unmapped', seq 51 and seq 25 fail and
--   the existing seq 4 (sum of unmapped = 0) fails too. Strictly stronger than eq 18 / eq 6.
--
-- DRY-PROVEN BEFORE WRITING (live, this leg, against the standing AFTER scratch):
--   cand_25 true · cand_26 true · cand_51 33 · cand_52 11 · cand_53 true
--
-- Cody class (f): golden.* only. No DDL, no SECURITY DEFINER, no RLS, no cron, no protected
-- entity, no engine md5 moved. Article 12 forward-only -- harness DATA, no past migration
-- edited (precedent: leg 73 fixture-54, leg 112 fixture-2).

BEGIN;

-- ── seq 25 · restated: the mapping, not the photograph ──────────────────────────────────
UPDATE golden.assertions SET
  description = 'S-139 member-of-the-difference: unclaimed maps to unmatched - an offer that found no target was never put to CS. RE-DERIVED off reallocation_proposals_v3, not pinned: fixture 11 grows this population by 4 on every run (S-204). Non-vacuity partner = seq 51.',
  check_sql = $q$
SELECT ((((SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after')
            -> 'reallocation' ->> 'fixture_unmatched')::int)
        = (SELECT count(*) FROM public.reallocation_proposals_v3
             WHERE status = 'unclaimed'
               AND plan_date >= (SELECT g12_fixture_epoch
                                   FROM public.refill_policy_params ORDER BY id LIMIT 1)))::text
$q$,
  expect_op = 'eq',
  expect    = 'true'
WHERE fixture_id = 59 AND seq = 25;

-- ── seq 26 · restated: undecided is exactly the pending/proposed population ──────────────
UPDATE golden.assertions SET
  description = 'and those unmatched rows are NOT counted as undecided - undecided RE-DERIVES to exactly the pending/proposed population and nothing else (S-204). Non-vacuity partner = seq 52; disjointness stated outright at seq 53.',
  check_sql = $q$
SELECT ((((SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after')
            -> 'reallocation' ->> 'fixture_undecided')::int)
        = (SELECT count(*) FROM public.reallocation_proposals_v3
             WHERE status IN ('pending','proposed')
               AND plan_date >= (SELECT g12_fixture_epoch
                                   FROM public.refill_policy_params ORDER BY id LIMIT 1)))::text
$q$,
  expect_op = 'eq',
  expect    = 'true'
WHERE fixture_id = 59 AND seq = 26;

-- ⛔ fail-loud: a silent no-op UPDATE would ship two untouched constants and read as green.
DO $g$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM golden.assertions
   WHERE fixture_id = 59 AND seq IN (25,26)
     AND expect = 'true' AND check_sql LIKE '%reallocation_proposals_v3%';
  IF n <> 2 THEN
    RAISE EXCEPTION 'FX59 seq 25/26 restatement did not land: % of 2 rows carry the new body', n;
  END IF;
END
$g$;

-- ── seq 51/52/53 · the guards the old constants never had ───────────────────────────────
-- ⛔ bare INSERT on purpose (S-?): a seq collision must ABORT, not silently overwrite. The
--    body is one transaction, so a raise here costs nothing. max(seq) was 50, unfiltered.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
 (59, 51,
  '⛔ NON-VACUITY PARTNER for seq 25: the unmatched bucket is a REAL, NON-EMPTY population, so seq 25 can never be an equality of two zeros (S-48/S-52/S-55 mode).',
  $q$
SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after')
         -> 'reallocation' ->> 'fixture_unmatched'
$q$,
  'gt', '0', true, 'P4'),

 (59, 52,
  '⛔ NON-VACUITY PARTNER for seq 26: the undecided bucket is likewise non-empty, so seq 26 cannot be satisfied on 0 = 0.',
  $q$
SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after')
         -> 'reallocation' ->> 'fixture_undecided'
$q$,
  'gt', '0', true, 'P4'),

 (59, 53,
  'S-204 DISJOINTNESS, stated outright rather than implied by two constants: unmatched and undecided do not overlap (their sum fits inside fixture_rows) AND undecided does not swallow the unclaimed rows (undecided < fixture_rows).',
  $q$
SELECT ((((SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after')
            -> 'reallocation' ->> 'fixture_undecided')::int
       + ((SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after')
            -> 'reallocation' ->> 'fixture_unmatched')::int)
        <= ((SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after')
            -> 'reallocation' ->> 'fixture_rows')::int
   AND (((SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after')
            -> 'reallocation' ->> 'fixture_undecided')::int)
        < ((SELECT value FROM golden.scratch WHERE fixture_id=59 AND key='after')
            -> 'reallocation' ->> 'fixture_rows')::int)::text
$q$,
  'eq', 'true', true, 'P4');

COMMIT;
