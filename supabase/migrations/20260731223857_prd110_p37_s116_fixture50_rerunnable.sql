-- PRD-110 · S-116 — make golden fixture 50 RE-RUNNABLE without weakening its absolute counts.
--
-- SYMPTOM (leg 73, verified): fixture 50 appends exactly 5 rows to plan_edits_v3 on its own
-- plan_date 2030-02-20 per run (4 edits + 1 supersession), of which 2 land on E_shelf. It then
-- asserts ABSOLUTE totals (seq 17 expects 2, seq 42 expects 5), so it is green only on the FIRST
-- run after creation. Measured: 15 rows over 3 runs = 3 x 5, E_shelf 6 = 3 x 2. Exactly the model.
--
-- THE POINTER'S PROPOSED REMEDY IS IMPOSSIBLE AND MUST NOT BE ATTEMPTED (S-114: a mechanism is a
-- hypothesis). "Clear the fixture's own plan_date rows in arrange" cannot work: plan_edits_v3
-- carries tg_plan_edits_v3_append_only (row) AND tg_plan_edits_v3_no_truncate (statement), and
-- section (7) of this very scenario ASSERTS that a DELETE on this plan_date is REFUSED. Deleting
-- would also violate LAW 3 (no destructive change to an append-only ledger).
--
-- ⭐ S-108 IS THEREFORE NOT FALSIFIED — IT IS CONFIRMED. The TRUNCATE guard is present and enabled;
-- it is the CAUSE of the non-re-runnability, not a gap in it. Seq 48 below pins that with a live
-- assertion so no future leg has to take the claim on trust.
--
-- FIX: capture the ledger depth BEFORE any edit is recorded, and report what THIS RUN appended.
-- The counts stay ABSOLUTE (exactly 2, exactly 5) — nothing is weakened to gte. The raw totals are
-- retained under *_abs keys for diagnostics.

DO $mig$
DECLARE
  s text;
  s_before text;
  n int;
BEGIN
  SELECT scenario_sql INTO s FROM golden.fixtures WHERE fixture_id = 50;
  IF s IS NULL THEN
    RAISE EXCEPTION 'S-116: golden fixture 50 not found';
  END IF;

  ---------------------------------------------------------------------------
  -- (a) PRE-CAPTURE block, inserted immediately after the anchors INSERT so it
  --     runs before the first record_plan_edit_v3 call in section (3).
  ---------------------------------------------------------------------------
  s_before := s;
  s := replace(
    s,
    $anch$  'U_shelf', '8ae4c5f3-cde6-4210-859b-a7aff71895a2', 'U_pod', '36f381fe-9e42-4d2f-920a-7c5192d56c43');$anch$,
    $anch$  'U_shelf', '8ae4c5f3-cde6-4210-859b-a7aff71895a2', 'U_pod', '36f381fe-9e42-4d2f-920a-7c5192d56c43');

-- ---------------------------------------------------------------------------
-- (0b) S-116 RUN-SCOPED BASELINE. plan_edits_v3 is append-only by trigger and
--      refuses TRUNCATE (S-108, asserted at seq 48), and section (7) asserts a
--      DELETE on this plan_date is REFUSED -- so this fixture CANNOT clear its
--      own rows. It therefore measures what THIS RUN appended. The counts below
--      stay absolute (exactly 2, exactly 5); only the baseline is subtracted.
-- ---------------------------------------------------------------------------
DO $pre$
DECLARE v jsonb := jsonb_build_object('pre_E', 0, 'pre_all', 0); n int;
BEGIN
  IF to_regclass('public.plan_edits_v3') IS NOT NULL THEN
    EXECUTE $x$ SELECT count(*) FROM public.plan_edits_v3
                 WHERE plan_date = DATE '2030-02-20'
                   AND shelf_id = 'b6454a65-f4da-4c07-8570-b8791f687ee2'::uuid $x$ INTO n;
    v := jsonb_set(v, '{pre_E}', to_jsonb(n));
    EXECUTE $x$ SELECT count(*) FROM public.plan_edits_v3
                 WHERE plan_date = DATE '2030-02-20' $x$ INTO n;
    v := jsonb_set(v, '{pre_all}', to_jsonb(n));
  END IF;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (50, 'pre', v);
END
$pre$;$anch$);
  IF s = s_before THEN
    RAISE EXCEPTION 'S-116 (a): anchors tail not found -- fixture 50 scenario has drifted';
  END IF;

  ---------------------------------------------------------------------------
  -- (b) seq 17 source: rows_after_reedit becomes THIS RUN's contribution.
  ---------------------------------------------------------------------------
  s_before := s;
  s := replace(
    s,
    $a2$    v := v || jsonb_build_object('rows_after_reedit', n);$a2$,
    $a2$    v := v || jsonb_build_object('rows_after_reedit_abs', n);
    n := n - COALESCE(((SELECT value FROM golden.scratch
                         WHERE fixture_id = 50 AND key = 'pre')->>'pre_E')::int, 0);
    v := v || jsonb_build_object('rows_after_reedit', n);$a2$);
  IF s = s_before THEN
    RAISE EXCEPTION 'S-116 (b): rows_after_reedit sink not found';
  END IF;

  ---------------------------------------------------------------------------
  -- (c) seq 42 source: edits_after_compose becomes THIS RUN's contribution.
  ---------------------------------------------------------------------------
  s_before := s;
  s := replace(
    s,
    $a3$    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (50, 'edits_after_compose', to_jsonb(n));$a3$,
    $a3$    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (50, 'edits_after_compose_abs', to_jsonb(n));
    n := n - COALESCE(((SELECT value FROM golden.scratch
                         WHERE fixture_id = 50 AND key = 'pre')->>'pre_all')::int, 0);
    INSERT INTO golden.scratch (fixture_id, key, value) VALUES (50, 'edits_after_compose', to_jsonb(n));$a3$);
  IF s = s_before THEN
    RAISE EXCEPTION 'S-116 (c): edits_after_compose sink not found';
  END IF;

  UPDATE golden.fixtures SET scenario_sql = s WHERE fixture_id = 50;

  -- the three edits must each have landed exactly once
  n := (length(s) - length(replace(s, 'S-116 RUN-SCOPED BASELINE', '')))
       / length('S-116 RUN-SCOPED BASELINE');
  IF n <> 1 THEN
    RAISE EXCEPTION 'S-116: pre-capture block appears % times, expected 1', n;
  END IF;
END
$mig$;

---------------------------------------------------------------------------
-- Assertion descriptions must stay honest about what they now measure.
-- expect is UNCHANGED (2 and 5) and expect_op stays eq -- per the pointer,
-- weakening these to gte would destroy the supersession proof.
---------------------------------------------------------------------------
UPDATE golden.assertions
   SET description = '...but BOTH events survive in the ledger -- supersession, not overwrite '
                     || '(exactly 2 appended by THIS run; S-116 run-scoped, prior runs excluded)'
 WHERE fixture_id = 50 AND seq = 17;

UPDATE golden.assertions
   SET description = 'the composer wrote no edit of its own (exactly 5 events appended by THIS run: '
                     || '4 edits + 1 supersession; S-116 run-scoped)'
 WHERE fixture_id = 50 AND seq = 42;

---------------------------------------------------------------------------
-- Two NEW assertions that pin the fix itself (LAW 1: the fixture is the proof).
---------------------------------------------------------------------------
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required)
VALUES
 (50, 47,
  'S-116: the run-scoped baseline was captured BEFORE the first edit, so this fixture is re-runnable',
  $c$SELECT (value->>'pre_all') FROM golden.scratch WHERE fixture_id=50 AND key='pre'$c$,
  'not_null', '', 'P3'),
 (50, 48,
  'S-108 INTACT (not falsified): plan_edits_v3 still carries the BEFORE TRUNCATE guard -- which is '
  || 'exactly WHY this fixture cannot clear its own rows and must measure a run-scoped delta',
  $c$SELECT count(*)::text FROM pg_trigger
      WHERE tgrelid='public.plan_edits_v3'::regclass
        AND NOT tgisinternal AND tgname='tg_plan_edits_v3_no_truncate' AND tgenabled<>'D'$c$,
  'eq', '1', 'P3'),
 (50, 49,
  'S-116: the ledger really did grow -- the absolute total is the pre-existing baseline plus '
  || 'exactly the 5 events this run appended (proves the delta is a scope, not a fudge)',
  $c$SELECT ((SELECT (value#>>'{}')::int FROM golden.scratch WHERE fixture_id=50 AND key='edits_after_compose_abs')
          - (SELECT (value->>'pre_all')::int FROM golden.scratch WHERE fixture_id=50 AND key='pre'))::text$c$,
  'eq', '5', 'P3');
