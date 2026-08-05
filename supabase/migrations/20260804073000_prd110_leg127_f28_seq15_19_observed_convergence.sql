-- PRD-110 leg 127 - fixture 28 seq 15 + seq 19: THE FLEET CONVERGED ON THE `observed` TIER
--
-- ── THE RED ──────────────────────────────────────────────────────────────────────────────────
-- S7 round 0 (note 'leg126 S7 r0', run a40690dd, 2026-08-04 06:21:28 UTC) closed fixture 28 at
-- 19 pass / 2 fail. The two failures:
--   seq 15  amz_interval_source   expect 'policy_seed'  actual 'observed'
--   seq 19  tiers_exercised       expect gte 2          actual 1
-- Fixture 28 was GREEN at 2026-08-04 01:58:23 UTC ('leg116 LAW8 sweep r0', 21/21). The drift
-- therefore landed inside a ~4.4 hour window on 2026-08-04.
--
-- ── THE BISECT: RE-DERIVED LIVE, NOT TAKEN FROM THE POINTER (LAW 13) ─────────────────────────
-- AMZ-1046-2406-O1's visit vocabulary inside the 120-day cadence lookback, measured this leg:
--     2026-07-25  dispatch  picked_up=t packed=t dispatched=t
--     2026-07-31  dispatch  picked_up=t packed=t dispatched=t
--     2026-08-04  dispatch  picked_up=t packed=t dispatched=t   <-- REAL OPS, TODAY
-- gaps = {6, 4}  ->  n_gaps = 2  >=  base_stock_min_gaps = 2  ->  tier resolves 'observed'.
-- Live params re-read: precedence 'observed_first', min_gaps 2, lookback 120, default 5.5.
--
-- ⛔ THIS IS PRODUCTION DATA, NOT HARNESS CONTAMINATION, AND THAT WAS PROVEN BEFORE ANY EDIT.
--   a. The fixture's `disp` CTE is bounded `dispatch_date <= CURRENT_DATE`, so every synthetic
--      2030-dated stress plant (S1 2030-11-01, S3 2030-11-03, S4 2030-11-04, S5 2030-11-05) is
--      STRUCTURALLY EXCLUDED from the cadence window. No stress suite can reach this number.
--   b. All three rows carry picked_up/packed/dispatched true on real 2026 dates - driver work.
--   c. AMZ-1046-2406-O1 is not a subject of any S1-S6 plant (S5's subject is an Inactive machine).
-- The 2026-08-04 live plan holds 96 rows: today's real refill round is simply underway.
--
-- ⭐ THE ENGINE IS NOT WRONG AND NOTHING IN IT IS TOUCHED HERE. The resolver behaved exactly as
-- specified: a machine that acquires a measurable cadence must leave the seed behind. seq 15's
-- OWN TEXT predicted this outcome verbatim - "If this ever reads 'observed' the machine finally
-- has a measurable cadence and the seeded row should be revisited". `v_machine_base_stock_policy_v3`
-- is byte-identical after this migration (viewdef md5 62c096f1, guarded below).
--
-- ⭐ AND THE MOVE VINDICATES S-43 RATHER THAN WEAKENING IT. AMZ's measured interval is 5 days
-- against a seeded trip_interval_days of 21 - a 4.2x overstatement, which is precisely the defect
-- fixture 28 exists to pin. seq 16 (divergence_machines) rose 30 -> 31 and stays GREEN.
--
-- ── WHY seq 19 CANNOT SIMPLY BE RE-POINTED AT A NUMBER ───────────────────────────────────────
-- `tiers_exercised` = count(DISTINCT interval_source) over the live population. Measured now:
-- observed 31, policy_seed 0, param_default 0 - ONE tier. AMZ was the last live member of the
-- policy_seed tier, so the fleet has fully converged.
--   · `gte 2` pins a statement that is now FALSE of live data.
--   · `gte 1` is vacuous - the S-48/S-52/S-55 vacuity mode burned four times already.
--   · `eq 1` is fragile in the OPPOSITE direction: it would red the day any machine goes quiet
--     for >120 days and falls back to its seed. Pinning an accident of visit history is exactly
--     what S-204 forbids ("never pin an assertion on a population you do not write").
--
-- ⭐ THE FIXTURE ALREADY SOLVED THIS EXACT PROBLEM ONE TIER DOWN, AND THIS FOLLOWS THAT PRECEDENT
-- VERBATIM. When D-14c (CS 2026-07-31) emptied the param_default tier, seq 18 was introduced as a
-- STRUCTURAL guard - the tier's continued existence proven from `pg_get_viewdef` instead of "from
-- an accident of AMZ-1046's visit history" (the scenario's own words). The policy_seed tier has
-- now met the same fate, so it gets the same treatment: seq 19 becomes the structural policy_seed
-- guard. Tier 1 is proven by the live population (31 rows), tier 2 and tier 3 structurally.
--
-- ⛔ seq 10 IS NOT LEFT UNGUARDED. Its non-vacuity spine survives intact and is asserted below:
--   seq 2  rows > 0                       (31)  - the contract is earned, not vacuous
--   seq 16 divergence_machines > 0        (31)  - seed still disagrees with measured cadence
--   seq 17 manual_evidence_machines > 0   (14)  - canonical Article-16 visit vocabulary exercised
--   seq 18 view_tier3_present = 1               - param_default branch still in the resolver
--   seq 19 view_tier2_present = 1  (NEW)        - policy_seed branch still in the resolver
-- All four pre-existing members are GUARDED UNCHANGED by this migration.
--
-- ── WHAT CHANGES (three named substitutions + two assertion re-phrasings, nothing else) ──────
--  1. scenario_sql gains ONE declaration, ONE computation and ONE payload key: `view_tier2_present`,
--     mirroring seq 18's `view_tier3_present` exactly. Applied by regexp on whitespace-tolerant
--     anchors, each guarded to have fired EXACTLY ONCE.
--  2. seq 15: expect 'policy_seed' -> 'observed', re-phased with the full three-step history.
--  3. seq 19: check_sql re-pointed tiers_exercised -> view_tier2_present, expect_op gte -> eq,
--     expect 2 -> 1, re-phased as the structural tier-2 guard.
-- ⛔ NO assertion is added or deleted: fixture 28 stays at 21, the global population stays at 2094.
-- ⛔ The re-phasings are RE-PHASINGS, not deletions - the protocol seq 16's own text mandates
--    ("If the seed is ever corrected this goes red ON PURPOSE and must be re-phased, not deleted").
--
-- ── BLAST RADIUS ────────────────────────────────────────────────────────────────────────────
-- Writes touch `golden.fixtures` (one row, fixture 28) and `golden.assertions` (two rows, seqs 15
-- and 19) ONLY. Both are harness tables in the `golden` schema, carry ZERO triggers (verified live
-- this leg), and are read by nothing outside the harness. No protected entity, no SECURITY DEFINER,
-- no RLS, no engine, no view, no cron, no flag, no live plan row.

BEGIN;

-- ── 1. scenario_sql: add the structural tier-2 probe ────────────────────────────────────────
UPDATE golden.fixtures
   SET scenario_sql = regexp_replace(
         regexp_replace(
           regexp_replace(
             scenario_sql,
             '(v_tiers\s+int;)',
             E'\\1\n  v_tier2        int;'
           ),
           '(SELECT count\(DISTINCT interval_source\) INTO v_tiers FROM fx28_act;)',
           E'\\1\n\n  -- STRUCTURAL TIER-2 GUARD (leg 127). The policy_seed tier emptied on 2026-08-04 when\n  -- AMZ-1046-2406-O1, its last live member, acquired a second visit gap. Same treatment D-14c\n  -- gave tier 3: prove the branch from the resolver definition, not from live visit history.\n  SELECT CASE WHEN pg_get_viewdef(''public.v_machine_base_stock_policy_v3''::regclass, true) LIKE ''%policy_seed%''\n               AND pg_get_viewdef(''public.v_machine_base_stock_policy_v3''::regclass, true) LIKE ''%trip_interval_days_v3%''\n              THEN 1 ELSE 0 END INTO v_tier2;'
         ),
         '(''view_tier3_present'',\s+v_tier3::text,)',
         E'\\1\n    ''view_tier2_present'',  v_tier2::text,'
       )
 WHERE fixture_id = 28;

-- ── 2. seq 15 - re-phased, not deleted ──────────────────────────────────────────────────────
UPDATE golden.assertions
   SET expect = 'observed',
       description = 'THIRD PHASING (leg 127, 2026-08-04): AMZ-1046-2406-O1 now resolves via the OBSERVED tier. '
                  || 'History: param_default (until 2026-07-31) -> policy_seed (D-14c, CS 2026-07-31, a real '
                  || 'machine_service_policy row with observed_n_gaps=1 < base_stock_min_gaps=2) -> observed '
                  || '(2026-08-04, real driver dispatches on 07-25 / 07-31 / 08-04 gave gaps {6,4}, so '
                  || 'n_gaps=2 >= min_gaps=2 under precedence observed_first). Re-phased, never deleted. '
                  || 'Measured interval 5 days vs a seeded trip_interval_days of 21 - a 4.2x overstatement, '
                  || 'which is S-43 itself, so this transition VINDICATES the fixture rather than weakening it. '
                  || 'If this ever reverts to policy_seed the machine has gone quiet for >120 days (the cadence '
                  || 'lookback) and the fleet has lost a visit clock - investigate the silence, do not re-phase.'
 WHERE fixture_id = 28 AND seq = 15;

-- ── 3. seq 19 - re-pointed to the structural guard, following the seq-18 precedent ──────────
UPDATE golden.assertions
   SET check_sql = 'SELECT value->>''view_tier2_present'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''',
       expect_op = 'eq',
       expect    = '1',
       description = 'STRUCTURAL TIER-2 GUARD (leg 127, re-phased from the live-population form): the policy_seed '
                  || 'branch still exists in the canonical resolver. Was "tiers_exercised gte 2" until 2026-08-04, '
                  || 'when AMZ-1046-2406-O1 - the tier''s last live member - acquired a second visit gap and moved '
                  || 'to observed, leaving the fleet fully converged at 31/31 observed. A gte-2 pin would then '
                  || 'assert something FALSE of live data, gte 1 would be vacuous (the S-48/S-52/S-55 mode), and '
                  || 'eq 1 on tiers_exercised would be fragile in the opposite direction - it would red the day any '
                  || 'machine goes quiet past the 120-day lookback. Per S-204 the tier is therefore proven from the '
                  || 'view DEFINITION, exactly as D-14c did for param_default at seq 18. seq 10''s non-vacuity is '
                  || 'carried by seq 2 (rows>0), seq 16 (divergence>0) and seq 17 (manual evidence>0), all green.'
 WHERE fixture_id = 28 AND seq = 19;

-- ── 4. GUARDS - every one of these ABORTS the migration ─────────────────────────────────────
DO $guard$
DECLARE
  v_scn      text;
  v_n_fx28   int;
  v_n_all    int;
  v_viewmd5  text;
  v_bad      int;
BEGIN
  SELECT scenario_sql INTO v_scn FROM golden.fixtures WHERE fixture_id = 28;

  -- 4a. each of the three substitutions fired EXACTLY ONCE
  IF (length(v_scn) - length(replace(v_scn, 'v_tier2        int;', ''))) / length('v_tier2        int;') <> 1 THEN
    RAISE EXCEPTION 'GUARD 4a-decl: v_tier2 declaration not inserted exactly once';
  END IF;
  IF (length(v_scn) - length(replace(v_scn, 'INTO v_tier2;', ''))) / length('INTO v_tier2;') <> 1 THEN
    RAISE EXCEPTION 'GUARD 4a-calc: v_tier2 computation not inserted exactly once';
  END IF;
  IF (length(v_scn) - length(replace(v_scn, '''view_tier2_present''', ''))) / length('''view_tier2_present''') <> 1 THEN
    RAISE EXCEPTION 'GUARD 4a-payload: view_tier2_present key not inserted exactly once';
  END IF;

  -- 4b. the tier-3 guard and the rest of the scenario survived untouched
  IF (length(v_scn) - length(replace(v_scn, '''view_tier3_present''', ''))) / length('''view_tier3_present''') <> 1 THEN
    RAISE EXCEPTION 'GUARD 4b: view_tier3_present no longer appears exactly once';
  END IF;
  IF v_scn NOT LIKE '%tiers_exercised%' THEN
    RAISE EXCEPTION 'GUARD 4b: tiers_exercised computation was removed - it must survive as telemetry';
  END IF;

  -- 4c. population size is unchanged: no assertion added, none deleted
  SELECT count(*) INTO v_n_fx28 FROM golden.assertions WHERE fixture_id = 28;
  SELECT count(*) INTO v_n_all  FROM golden.assertions;
  IF v_n_fx28 <> 21 THEN RAISE EXCEPTION 'GUARD 4c: fixture 28 assertion count is %, expected 21', v_n_fx28; END IF;
  IF v_n_all  <> 2094 THEN RAISE EXCEPTION 'GUARD 4c: global assertion count is %, expected 2094', v_n_all; END IF;

  -- 4d. THE NON-VACUITY SPINE IS UNTOUCHED (seq 10, 16, 17, 18 exactly as before)
  SELECT count(*) INTO v_bad FROM golden.assertions
   WHERE fixture_id = 28
     AND ( (seq = 10 AND NOT (expect_op = 'eq'  AND expect = '0' AND check_sql LIKE '%interval_mismatch%'))
        OR (seq = 16 AND NOT (expect_op = 'gt'  AND expect = '0' AND check_sql LIKE '%divergence_machines%'))
        OR (seq = 17 AND NOT (expect_op = 'gt'  AND expect = '0' AND check_sql LIKE '%manual_evidence_machines%'))
        OR (seq = 18 AND NOT (expect_op = 'eq'  AND expect = '1' AND check_sql LIKE '%view_tier3_present%')) );
  IF v_bad <> 0 THEN RAISE EXCEPTION 'GUARD 4d: the non-vacuity spine (seq 10/16/17/18) was altered'; END IF;

  -- 4e. the resolver view itself is byte-identical - this migration touches no engine object
  SELECT left(md5(pg_get_viewdef('public.v_machine_base_stock_policy_v3'::regclass, true)), 8) INTO v_viewmd5;
  IF v_viewmd5 <> '62c096f1' THEN
    RAISE EXCEPTION 'GUARD 4e: v_machine_base_stock_policy_v3 viewdef md5 is %, expected 62c096f1', v_viewmd5;
  END IF;

  -- 4f. the two edits actually landed
  IF NOT EXISTS (SELECT 1 FROM golden.assertions WHERE fixture_id=28 AND seq=15 AND expect='observed') THEN
    RAISE EXCEPTION 'GUARD 4f: seq 15 did not take the new expect';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM golden.assertions WHERE fixture_id=28 AND seq=19
                   AND expect='1' AND expect_op='eq' AND check_sql LIKE '%view_tier2_present%') THEN
    RAISE EXCEPTION 'GUARD 4f: seq 19 did not take the structural form';
  END IF;

  RAISE NOTICE 'leg127 fixture-28 guards all passed';
END
$guard$;

COMMIT;
