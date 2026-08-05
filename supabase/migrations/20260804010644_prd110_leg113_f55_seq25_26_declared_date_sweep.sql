-- PRD-110 leg 113 · S-200 red set · fixture 55 seq 25 + 26 (class (D), re-derived live and
-- CONFIRMED). ⛔ S-200's (D) was read in full first, and its instruction is obeyed: the
-- constant is NOT bumped.
--
-- WHY 25/26 WERE RED, MEASURED LIVE THIS LEG:
--   seq 25  refill_plan_output rows on any 2030+ plan_date  eq 21 -> actual 26
--   seq 26  pod_refill_plan    rows on any 2030+ plan_date  eq  9 -> actual 11
--
--   | table | 2030-01-11 (fx10) | 2030-02-03 (fx33) | 2030-03-05 (fx63) | 2099-12-* (legacy) |
--   | rpo   | 7                 | 5                 | 5                 | 9                  | = 26
--   | prp   | 7                 | 2                 | 2                 | 0                  | = 11
--
--   ⭐ The overshoot is EXACTLY fixture 63's own legitimate plants. Every one of the three
--      2030 dates is a DECLARED golden.fixtures.plan_date. There is no residue here at all --
--      the tripwire is red because the build did its job.
--   ⛔ So the assertion is guaranteed to go red every time PRD-110 adds a synthetic-date
--      fixture. Bumping 21 -> 26 just re-arms the identical trap for fixture 67.
--      (And per S-204, raised this leg: a constant over a population the HARNESS grows is not
--      a photograph, it is a countdown.)
--
-- WHAT 25/26 ARE FOR (S-124): they are the FLEET-WIDE RESIDUE SWEEP. A per-date tripwire
-- passed for 78 legs while residue accumulated elsewhere, so the sweep must stay fleet-wide.
-- ⭐ The thing it actually cares about is not "how many" but "does every synthetic row have a
--    declared owner". Restate it that way and it is residue-detecting AND fixture-immune.
--
-- REMEDY:
--   seq 25 -> every 2030+ plan_date in refill_plan_output belongs to a declared
--             golden.fixtures.plan_date  (count of orphans = 0)
--   seq 26 -> same sweep for pod_refill_plan
--   seq 27 -> NON-VACUITY: rpo actually HAS 2030+ rows to sweep (else seq 25 is 0 of 0)
--   seq 28 -> NON-VACUITY: prp likewise
--   seq 29 -> ⛔ LAW 12 CARVE-OUT PIN, and it is what keeps the exclusion HONEST
--   seq 30 -> the prp carve-out term is provably inert (prp holds zero 2099+ rows)
--
-- ⛔ THE 2099-12-* CARVE-OUT, WITH ITS PROVENANCE RE-DERIVED LIVE (S-158):
--    9 rows · 8 distinct dates · EXACTLY ONE machine a6c02486-5d95-42ca-9adc-bc755c3019d3 ·
--    comments '[S1] refill full-fill test', '[S4] BUG-012 cascade live test',
--    '[S5/S6] dispatch X/Y/Z', '[S7]/[S8]/[S9] Remove receive PATH A/B/C FEFO'.
--    ⚠️ S-200 listed only the first two comments -- it under-described this set; the other six
--       are recorded here. The provenance conclusion is unchanged: pre-PRD-110, one machine,
--       [S*] test-harness rows. No golden.fixtures row declares any 2099 date (verified: 0).
--    ⛔ LAW 12 -- these rows are LEFT ALONE. They are carved out EXPLICITLY, by machine AND
--       date, never silently included.
--    ⭐ seq 29 is what stops the carve-out becoming a hiding place: it pins the 2099+ set at
--       exactly 9 rows AND asserts every one of them is on the carved-out machine. A new 2099
--       row from any other machine trips seq 25; from the SAME machine it trips seq 29.
--
-- NEGATIVE CONTROL: residue on an undeclared 2030+ date -> seq 25/26 fire (the original
-- purpose, now per-date-attributed instead of by total). Legacy rows touched -> seq 29 fires.
-- Synthetic population wiped -> seq 27/28 fire. The old `eq 21`/`eq 9` caught only the first
-- of those, and only by accident of arithmetic.
--
-- ⚠️ NOTED, NOT A DEFECT: "declared" spans ALL golden.fixtures rows, not just enabled ones. A
--    disabled fixture's date must still count as owned, or disabling a fixture would false-fire
--    the sweep. The residual (someone legitimising residue by adding a fixtures row) is not a
--    threat model this harness defends against.
--
-- DRY-PROVEN BEFORE WRITING (live, read-only, this leg):
--   cand_25 0 · cand_26 0 · nv_rpo 26 · nv_prp 11 · legacy_all 9 · legacy_scoped 9 · prp_2099 0
--
-- Cody class (f): golden.* only. The bodies READ refill_plan_output / pod_refill_plan, but a
-- read is not a protected-entity touch -- this migration writes nothing outside golden.*.
-- No DDL, no SECURITY DEFINER, no RLS, no cron, no engine md5 moved.

BEGIN;

-- ── seq 25 · restated: ownership, not cardinality ───────────────────────────────────────
UPDATE golden.assertions SET
  description = '⭐ S-124 FLEET SWEEP, restated (S-200 class (D)): every 2030+ refill_plan_output plan_date belongs to a DECLARED golden.fixtures row. Residue-detecting AND immune to new synthetic-date fixtures - the old eq 21 went red on fixture 63''s own legitimate plants. ⛔ The pre-PRD-110 2099-12-* legacy rows (one machine, LAW 12) are carved out EXPLICITLY and pinned by seq 29.',
  check_sql = $q$
SELECT count(*)::text FROM public.refill_plan_output r
 WHERE r.plan_date >= DATE '2030-01-01'
   AND NOT EXISTS (SELECT 1 FROM golden.fixtures f WHERE f.plan_date = r.plan_date)
   AND NOT (r.machine_id = 'a6c02486-5d95-42ca-9adc-bc755c3019d3'::uuid
            AND r.plan_date >= DATE '2099-01-01')
$q$,
  expect_op = 'eq',
  expect    = '0'
WHERE fixture_id = 55 AND seq = 25;

-- ── seq 26 · the same sweep on pod_refill_plan ──────────────────────────────────────────
UPDATE golden.assertions SET
  description = '⭐ S-124 extended, restated the same way: every 2030+ pod_refill_plan plan_date belongs to a DECLARED golden.fixtures row. A tripwire on one table is no more a sweep than a per-date check was.',
  check_sql = $q$
SELECT count(*)::text FROM public.pod_refill_plan p
 WHERE p.plan_date >= DATE '2030-01-01'
   AND NOT EXISTS (SELECT 1 FROM golden.fixtures f WHERE f.plan_date = p.plan_date)
   AND NOT (p.machine_id = 'a6c02486-5d95-42ca-9adc-bc755c3019d3'::uuid
            AND p.plan_date >= DATE '2099-01-01')
$q$,
  expect_op = 'eq',
  expect    = '0'
WHERE fixture_id = 55 AND seq = 26;

-- ⛔ fail-loud: a silent no-op UPDATE would ship two untouched constants and read as green.
DO $g$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM golden.assertions
   WHERE fixture_id = 55 AND seq IN (25,26)
     AND expect = '0' AND check_sql LIKE '%golden.fixtures f%';
  IF n <> 2 THEN
    RAISE EXCEPTION 'FX55 seq 25/26 restatement did not land: % of 2 rows carry the new body', n;
  END IF;
END
$g$;

-- ── seq 27..30 · the guards a bare "eq 0" residue sweep must never ship without ──────────
-- ⛔ bare INSERT on purpose: a seq collision must ABORT, not silently overwrite. max(seq) was
--    26, unfiltered. The body is one transaction, so a raise costs nothing.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
 (55, 27,
  '⛔ NON-VACUITY PARTNER for seq 25: there ARE 2030+ refill_plan_output rows to sweep. Without this, "zero orphans" is satisfied by an empty synthetic population - the S-48/S-52/S-55 mode.',
  $q$
SELECT count(*)::text FROM public.refill_plan_output WHERE plan_date >= DATE '2030-01-01'
$q$,
  'gt', '0', true, 'P4'),

 (55, 28,
  '⛔ NON-VACUITY PARTNER for seq 26: there ARE 2030+ pod_refill_plan rows to sweep.',
  $q$
SELECT count(*)::text FROM public.pod_refill_plan WHERE plan_date >= DATE '2030-01-01'
$q$,
  'gt', '0', true, 'P4'),

 (55, 29,
  '⛔ LAW 12 CARVE-OUT PIN - this is what stops seq 25''s exclusion becoming a hiding place. The pre-PRD-110 2099-12-* population is EXACTLY 9 rows and EVERY one of them is on the single carved-out machine a6c02486. A new 2099 row from another machine trips seq 25; from the same machine it trips this. ⛔ These rows are never to be modified.',
  $q$
SELECT ((SELECT count(*) FROM public.refill_plan_output WHERE plan_date >= DATE '2099-01-01') = 9
    AND (SELECT count(*) FROM public.refill_plan_output
          WHERE plan_date >= DATE '2099-01-01'
            AND machine_id = 'a6c02486-5d95-42ca-9adc-bc755c3019d3'::uuid) = 9)::text
$q$,
  'eq', 'true', true, 'P4'),

 (55, 30,
  'and pod_refill_plan carries NO 2099+ rows at all, so seq 26''s carve-out term is provably inert rather than quietly load-bearing.',
  $q$
SELECT count(*)::text FROM public.pod_refill_plan WHERE plan_date >= DATE '2099-01-01'
$q$,
  'eq', '0', true, 'P4');

COMMIT;
