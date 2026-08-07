-- PRD-110 · S-264 · fixture 57's reclaim may only ever delete rows it OWNS
--
-- THE DEFECT (leg 141). Fixture 57 picks mA from LIVE machines and reclaims with
--   DELETE FROM feedback_proposals_v3 WHERE machine_id = mA
--     AND trigger_reason LIKE 'WS-H2 recurring%'
-- but that prefix is exactly what the production edit miner writes. On
-- 2026-08-06 the first live miner run reported proposals_created = 9 and the
-- table held 8: fixture 57 ran four minutes later and ate one. Golden has been
-- unsafe to run since DR-5 made the miners live.
--
-- WHY "MARKER *AND* MACHINE" WAS NEVER ENOUGH. The anchor predicate excludes
-- machines carrying foreign plan_edits_v3 / pod_refill_plan_audit /
-- feedback_ledger_v3 / planning_pins_v3 rows. It does NOT exclude machines that
-- receive real miner PROPOSALS - and it cannot, because the miner targets
-- precisely the machines with rich edit history, which is what makes them good
-- anchors. mA (0f698c26) is a live production machine.
--
-- THE FIX - two scopes, each physical, neither relying on the anchor predicate:
--   · proposals + pins -> plan_date >= g12_fixture_epoch (the 2030 synthetic band)
--   · ledger           -> ONLY the feedback rows those proposals CITE, because
--                         feedback_ledger_v3 has NO plan_date to scope by.
-- Verified live before writing: the fixture's 3 proposals cite exactly 3
-- feedback ids, matching all 3 miner ledger rows on mA, with 0 uncited. The
-- citation reclaim is therefore exact AND complete.
--
-- ⛔ THE LEDGER HOLE IS WIDER THAN S-264 RECORDED. The old
--   DELETE FROM feedback_ledger_v3 WHERE machine_id = mA AND channel = 'miner'
-- destroys real miner ledger rows too - the evidence real proposals cite - and
-- epoch-scoping alone cannot close it. 8 of the 11 miner ledger rows live today
-- are real. Both copies of that DELETE (mA path and mPrev path) are replaced.
--
-- ASSERTIONS: seq 24/25 are absolute counts over a machine the fixture no longer
-- exclusively owns (the S-262 class), and seq 29 counts miner ledger rows
-- machine-wide. All three are SCOPED to the fixture's own band. No expect value
-- moves; this is not a re-baseline in the S-103 sense - each check is made to
-- measure the population its description always described.
-- NEW seq 40/41: the S-264 sensor - the real pre-epoch population is byte-equal
-- before and after the fixture runs - plus its non-vacuity guard.


DO $mig$
DECLARE
  v_old text; v_new text;
  v_hits int;
BEGIN
  SELECT scenario_sql INTO v_new FROM golden.fixtures WHERE fixture_id = 57;
  IF v_new IS NULL THEN RAISE EXCEPTION 'S-264: fixture 57 has no scenario_sql'; END IF;
  v_old := v_new;

  ---------------------------------------------------------------- R1: decls ---
  v_new := replace(v_new,
    '  r1 jsonb; r2 jsonb; rdry jsonb; rscope jsonb;',
    E'  r1 jsonb; r2 jsonb; rdry jsonb; rscope jsonb;' || E'\n' ||
    '  v_epoch date; own_fids uuid[]; n_real_before int;');
  IF position('own_fids uuid[]' in v_new) = 0 THEN
    RAISE EXCEPTION 'S-264 R1 MISSED: declaration anchor not found';
  END IF;

  -------------------------------------------------------------- R2: reclaim ---
  v_new := replace(v_new,
$r2old$  -- ⛔ BY MARKER *AND* MACHINE. Machine alone once ate fixtures 55/56 rows.
  DELETE FROM public.planning_pins_v3 p
   WHERE p.machine_id = mA
     AND p.proposal_id IN (SELECT proposal_id FROM public.feedback_proposals_v3
                            WHERE trigger_reason LIKE 'WS-H2 recurring%');
  DELETE FROM public.feedback_proposals_v3
   WHERE machine_id = mA AND trigger_reason LIKE 'WS-H2 recurring%';
  DELETE FROM public.feedback_ledger_v3
   WHERE machine_id = mA AND channel = 'miner';
$r2old$,

$r2new$  -- ⛔⛔ S-264: mA IS A LIVE MACHINE AND THE REAL WS-H2 MINER WRITES THE
  --    SAME trigger_reason PREFIX ONTO IT. Marker+machine was NOT enough: on
  --    2026-08-06 this block ate one of the nine proposals the first live
  --    miner run minted. Every reclaim below is scoped to rows this fixture
  --    PROVABLY OWNS, and the scope is physical, not a naming convention:
  --      · proposals + pins -> plan_date >= g12_fixture_epoch (the 2030 band)
  --      · ledger          -> only the feedback rows those proposals CITE,
  --                             because feedback_ledger_v3 has NO plan_date.
  SELECT g12_fixture_epoch INTO v_epoch
    FROM public.refill_policy_params ORDER BY id LIMIT 1;
  IF v_epoch IS NULL THEN
    RAISE EXCEPTION 'FX57 setup: g12_fixture_epoch is NULL - refusing to reclaim unscoped';
  END IF;

  -- the S-264 sensor baseline: what the REAL population looked like before a
  -- single DELETE ran. Captured before the reclaim, asserted after the fixture.
  SELECT count(*) INTO n_real_before
    FROM public.feedback_proposals_v3 WHERE plan_date < v_epoch;

  -- ⭐ anchor memory: where the LAST run actually wrote. Read
  --    BEFORE the deletes so mPrev is covered by the same scoped statements.
  SELECT (value #>> '{}')::uuid INTO mPrev FROM golden.scratch
   WHERE fixture_id = 57 AND key = 'mA';

  SELECT COALESCE(array_agg(DISTINCT fid), '{}') INTO own_fids
    FROM public.feedback_proposals_v3 f, unnest(f.feedback_ids) AS fid
   WHERE f.machine_id IN (mA, mPrev)
     AND f.plan_date >= v_epoch
     AND f.trigger_reason LIKE 'WS-H2 recurring%';

  DELETE FROM public.planning_pins_v3 p
   WHERE p.machine_id IN (mA, mPrev)
     AND p.proposal_id IN (SELECT proposal_id FROM public.feedback_proposals_v3
                            WHERE trigger_reason LIKE 'WS-H2 recurring%'
                              AND plan_date >= v_epoch);
  DELETE FROM public.feedback_proposals_v3
   WHERE machine_id IN (mA, mPrev) AND trigger_reason LIKE 'WS-H2 recurring%'
     AND plan_date >= v_epoch;
  DELETE FROM public.feedback_ledger_v3
   WHERE feedback_id = ANY(own_fids) AND channel = 'miner';
$r2new$);

  IF position('S-264: mA IS A LIVE MACHINE' in v_new) = 0 THEN
    RAISE EXCEPTION 'S-264 R2 MISSED: reclaim block anchor not found (whitespace drift?)';
  END IF;

  ------------------------------------------------- R3: the old mPrev block ----
  v_new := replace(v_new,
$r3old$  -- ⭐ follow an anchor move: reclaim where the LAST run actually wrote.
  SELECT (value #>> '{}')::uuid INTO mPrev FROM golden.scratch
   WHERE fixture_id = 57 AND key = 'mA';
  IF mPrev IS NOT NULL AND mPrev <> mA THEN
    DELETE FROM public.feedback_proposals_v3
     WHERE machine_id = mPrev AND trigger_reason LIKE 'WS-H2 recurring%';
    DELETE FROM public.feedback_ledger_v3
     WHERE machine_id = mPrev AND channel = 'miner';
  END IF;
$r3old$,

$r3new$  -- ⭐ the anchor-move reclaim is folded into the epoch-scoped block above,
  --    which already covers mPrev. S-264: the machine-wide ledger DELETE that
  --    stood here was the SECOND copy of the same live-data-destroying defect.
$r3new$);

  IF position('the anchor-move reclaim is folded' in v_new) = 0 THEN
    RAISE EXCEPTION 'S-264 R3 MISSED: mPrev block anchor not found';
  END IF;

  -- both machine-wide ledger DELETEs must now be GONE
  IF position('WHERE machine_id = mA AND channel = ''miner''' in v_new) > 0
     OR position('WHERE machine_id = mPrev AND channel = ''miner''' in v_new) > 0 THEN
    RAISE EXCEPTION 'S-264: a machine-wide ledger DELETE survived the rewrite';
  END IF;
  -- and no unscoped proposal DELETE may remain
  SELECT count(*) INTO v_hits FROM regexp_matches(
    v_new, 'DELETE FROM public\.feedback_proposals_v3', 'g') t;
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'S-264: expected exactly 1 proposal DELETE after rewrite, found %', v_hits;
  END IF;

  ------------------------------------------------ R4: bank the sensor value ---
  v_new := replace(v_new,
    '    (57,''min_occ_1_refusal'', to_jsonb(v_refused));',
    E'    (57,''min_occ_1_refusal'', to_jsonb(v_refused)),' || E'\n' ||
    '    (57,''n_real_before'', to_jsonb(n_real_before));');
  IF position('n_real_before'', to_jsonb(n_real_before)' in v_new) = 0 THEN
    RAISE EXCEPTION 'S-264 R4 MISSED: scratch tail anchor not found';
  END IF;

  IF v_new = v_old THEN RAISE EXCEPTION 'S-264: scenario_sql unchanged'; END IF;

  UPDATE golden.fixtures SET scenario_sql = v_new WHERE fixture_id = 57;
END $mig$;

--------------------------------------------------------------- assertions ----
-- seq 24/25: scope to the fixture's own band. The DESCRIPTION already claimed
-- "every proposal" / "three pending proposals" meaning the fixture's own; only
-- the check was machine-wide. expect values do not move.
UPDATE golden.assertions SET
  check_sql = 'SELECT count(*)::text FROM public.feedback_proposals_v3
   WHERE machine_id = (SELECT (value #>> ''{}'')::uuid FROM golden.scratch WHERE fixture_id=57 AND key=''mA'')
     AND plan_date >= (SELECT g12_fixture_epoch FROM public.refill_policy_params ORDER BY id LIMIT 1)
     AND status <> ''pending''',
  description = 'THE CS GATE HOLDS: every proposal THIS FIXTURE minted is pending. The miner proposes, it never applies (S-264: scoped to the fixture band - mA is a live machine and CS may decide real proposals on it)'
WHERE fixture_id=57 AND seq=24;

UPDATE golden.assertions SET
  check_sql = 'SELECT count(*)::text FROM public.feedback_proposals_v3
   WHERE machine_id = (SELECT (value #>> ''{}'')::uuid FROM golden.scratch WHERE fixture_id=57 AND key=''mA'')
     AND plan_date >= (SELECT g12_fixture_epoch FROM public.refill_policy_params ORDER BY id LIMIT 1)
     AND status = ''pending''',
  description = '⛔ NON-VACUITY for seq 24: there ARE three pending proposals to gate (S-264: counted in the fixture band, not machine-wide)'
WHERE fixture_id=57 AND seq=25;

-- seq 29: the description's claim is a DELTA ("did NOT grow on the second run").
-- Counting machine-wide made it an absolute that only held while the fixture was
-- mA's sole miner. Scoped to the rows the fixture's own proposals cite.
UPDATE golden.assertions SET
  check_sql = 'SELECT count(*)::text FROM public.feedback_ledger_v3 l
   WHERE l.machine_id = (SELECT (value #>> ''{}'')::uuid FROM golden.scratch WHERE fixture_id=57 AND key=''mA'')
     AND l.channel=''miner''
     AND EXISTS (SELECT 1 FROM public.feedback_proposals_v3 f
                  WHERE f.plan_date >= (SELECT g12_fixture_epoch FROM public.refill_policy_params ORDER BY id LIMIT 1)
                    AND f.trigger_reason LIKE ''WS-H2 recurring%''
                    AND l.feedback_id = ANY(f.feedback_ids))',
  description = 'the ledger did NOT grow on the second run: exactly three miner rows THIS FIXTURE''S proposals cite, not six (S-264: cited-scope, because feedback_ledger_v3 has no plan_date to scope by)'
WHERE fixture_id=57 AND seq=29;

-- seq 40/41: the S-264 sensor itself.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled)
VALUES
(57, 40,
 '⛔⛔ S-264 SENSOR: running this fixture destroyed NOT ONE real proposal. The pre-epoch population is identical before the reclaim and after both miner runs. If this ever goes red, the reclaim has escaped the fixture band and is eating CS''s review queue again',
 'SELECT ((SELECT (value #>> ''{}'')::int FROM golden.scratch WHERE fixture_id=57 AND key=''n_real_before'')
        = (SELECT count(*) FROM public.feedback_proposals_v3
            WHERE plan_date < (SELECT g12_fixture_epoch FROM public.refill_policy_params ORDER BY id LIMIT 1)))::text',
 'eq', 'true', true),
(57, 41,
 '⛔ NON-VACUITY for seq 40: there IS a real pre-epoch population to protect, so the sensor is not comparing zero to zero',
 'SELECT count(*)::text FROM public.feedback_proposals_v3
   WHERE plan_date < (SELECT g12_fixture_epoch FROM public.refill_policy_params ORDER BY id LIMIT 1)',
 'gte', '1', true),
-- Cody REQUIRED REVISION: g12_fixture_epoch is a mutable dial and EVERY guard in
-- this fixture now leans on it. If it is ever moved back into the live band, all
-- three reclaim scopes silently widen to cover real rows again and seq 40 would
-- only notice AFTER the damage. This goes red BEFORE a reclaim can run.
(57, 42,
 '⛔ S-264 GUARD-THE-GUARD: g12_fixture_epoch still sits ABOVE every live plan_date, so the epoch scope that protects the real proposal queue is still a real scope. If this goes red, do NOT run this fixture - the reclaim predicate has widened onto live data',
 'SELECT ((SELECT g12_fixture_epoch FROM public.refill_policy_params ORDER BY id LIMIT 1)
        > (SELECT COALESCE(max(plan_date), DATE ''1970-01-01'')
             FROM public.feedback_proposals_v3
            WHERE plan_date < DATE ''2027-01-01''))::text',
 'eq', 'true', true);


