SET LOCAL statement_timeout = '120s';

-- ============================================================================
-- PRD-110 leg 83 · UNIT 1a — THE FIXTURE FOR S-128(b), WRITTEN BEFORE THE GUARD
--
-- LAW 1: no verb change before the fixture that proves it. This migration adds
-- ONLY the proof; the guard itself ships in a separate migration so the reds
-- below are observed against the CURRENT verb first.
--
-- ⛔ THE SCENARIO IS EDITED BY SUBSTITUTION OVER THE LIVE DEFINITION, never
--    re-transcribed. 15.7k characters hand-copied is a transcription bug waiting
--    to happen; every anchor below asserts its own occurrence count and the
--    migration ABORTS rather than silently no-op'ing on a missed match.
-- ============================================================================

DO $mig$
DECLARE
  s   text;
  n   int;
  a_key    CONSTANT text := '''neg_contra''';
  a_tail   CONSTANT text := E'  PERFORM set_config(''request.jwt.claims'', '''', true);\nEND\n$fx56c$;';
  a_decl   CONSTANT text := '  fb_c1 uuid; fb_n1 uuid; fb_n2 uuid; fb_n3 uuid; pr1 uuid; pr3 uuid;';
  probe_l  text;
BEGIN
  SELECT scenario_sql INTO s FROM golden.fixtures WHERE fixture_id = 56;
  IF s IS NULL THEN
    RAISE EXCEPTION 'FX56 scenario not found - refusing to edit nothing';
  END IF;

  -- ---------- substitution 1: the probe key stops claiming to be about the contradiction ----------
  -- ⭐ Probe (j) has ALWAYS been the never_stock approval probe; only the RULE that
  --    refuses it changes. Renaming the key keeps the harness honest about which
  --    rule it is reading.
  n := (length(s) - length(replace(s, a_key, ''))) / length(a_key);
  IF n <> 2 THEN
    RAISE EXCEPTION 'anchor 1 (neg_contra key) matched % times, expected exactly 2', n;
  END IF;
  s := replace(s, a_key, '''neg_ns_parked''');

  -- ---------- substitution 2: BLOCK C gains one variable ----------
  n := (length(s) - length(replace(s, a_decl, ''))) / length(a_decl);
  IF n <> 1 THEN
    RAISE EXCEPTION 'anchor 2 (BLOCK C declare) matched % times, expected exactly 1', n;
  END IF;
  s := replace(s, a_decl, a_decl || E'\n  v_rej text;');

  -- ---------- substitution 3: probe (l), the legal exit ----------
  probe_l := E'\n'
  || E'  -- (l) ⭐ THE PARKED GUARD IS ON APPROVE ONLY, AND THAT IS THE POINT. A never_stock\n'
  || E'  --     proposal must keep a LEGAL EXIT: if rejection were blocked too, S-128''s guard\n'
  || E'  --     would strand the proposal in CS''s queue forever with no way to dispose of it,\n'
  || E'  --     which trades a silent wrong answer for a permanent stuck one.\n'
  || E'  --     ⛔ Runs inside a rolled-back subtransaction so pr3 stays PENDING for the probe\n'
  || E'  --     above. plpgsql variables survive the rollback; DB writes do not.\n'
  || E'  BEGIN\n'
  || E'    v_rej := public.approve_feedback_proposal_v3(pr3, ''reject'',\n'
  || E'               ''FX56 disposing of the parked never_stock proposal'') ->> ''status'';\n'
  || E'    RAISE EXCEPTION ''FX56_ROLLBACK_REJECT_PROBE'';\n'
  || E'  EXCEPTION WHEN OTHERS THEN\n'
  || E'    IF SQLERRM <> ''FX56_ROLLBACK_REJECT_PROBE'' THEN v_rej := ''REFUSED: '' || SQLERRM; END IF;\n'
  || E'  END;\n'
  || E'  INSERT INTO golden.scratch(fixture_id,key,value)\n'
  || E'    VALUES (56,''ns_reject_ok'', to_jsonb(COALESCE(v_rej,''<none>'')));\n'
  || E'\n';

  n := (length(s) - length(replace(s, a_tail, ''))) / length(a_tail);
  IF n <> 1 THEN
    RAISE EXCEPTION 'anchor 3 (BLOCK C tail) matched % times, expected exactly 1', n;
  END IF;
  s := replace(s, a_tail, probe_l || a_tail);

  -- ---------- post-conditions on the GENERATED source, not on the intent ----------
  IF strpos(s, 'neg_contra') <> 0 THEN
    RAISE EXCEPTION 'post-check: the old probe key survived the substitution';
  END IF;
  IF strpos(s, 'ns_reject_ok') = 0 OR strpos(s, 'v_rej text;') = 0 THEN
    RAISE EXCEPTION 'post-check: probe (l) did not land';
  END IF;

  UPDATE golden.fixtures SET scenario_sql = s WHERE fixture_id = 56;
END
$mig$;

-- ============================================================================
-- ASSERTIONS
-- ⛔ S-103: an assertion edit is TWO fields. seq 35's check_sql AND its expect
--    AND its description are all re-stated together below - a check_sql moved to
--    a new key while its expect still named the old rule would pass over nothing.
-- ⛔ Every new row carries phase_required EXPLICITLY; the column defaults to 'P0'.
-- ============================================================================

-- seq 35 RE-STATED. ⭐ The contradiction guard is not deleted and not weakened -
-- it is SHADOWED: with never_stock unapprovable, the verb can no longer reach it
-- from either direction, so this probe now reads the rule that actually fires.
-- The STRUCTURAL contradiction protection is unaffected and still proven
-- independently by fixture 55 seq 7 at the index level (23505).
UPDATE golden.assertions SET
  description = '⭐ THE PARKED KIND IS REFUSED LOUDLY, NOT MINTED SILENTLY: approving never_stock names its own rule (S-128). ⛔ This probe formerly read the contradiction guard, which is now SHADOWED - never_stock cannot be approved from either direction, so the contradiction message ("revoke it first") would be true but MISLEADING, implying a retry that would still fail. Index-level contradiction protection is unchanged and still proven by fixture 55 seq 7',
  check_sql   = 'SELECT value #>> ''{}'' FROM golden.scratch WHERE fixture_id=56 AND key=''neg_ns_parked''',
  expect_op   = 'contains',
  expect      = 'not yet consumed by the engine'
WHERE fixture_id = 56 AND seq = 35;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES
(56, 41,
 'the refusal names the KIND it is refusing, so CS reads which pin is parked rather than a generic policy error',
 'SELECT value #>> ''{}'' FROM golden.scratch WHERE fixture_id=56 AND key=''neg_ns_parked''',
 'contains', 'never_stock', true, 'P4'),

(56, 42,
 '⭐ THE GUARD''S ACTUAL PROMISE, STATED AT ITS STRONGEST: no never_stock pin exists ANYWHERE in the base table. approve_feedback_proposal_v3 is the sole INSERT path (verified live against prosrc), so this is a fleet-wide tripwire, not a scoped one. ⛔ Retire this row in the same unit that ships the ceiling branch, when never_stock becomes legal',
 'SELECT count(*)::text FROM public.planning_pins_v3 WHERE kind = ''never_stock''',
 'eq', '0', true, 'P4'),

(56, 43,
 '⭐ THE LEGAL EXIT SURVIVES: a never_stock proposal can still be REJECTED. The guard sits inside the approve branch only, so CS can dispose of the proposal instead of it sitting in the queue forever',
 'SELECT value #>> ''{}'' FROM golden.scratch WHERE fixture_id=56 AND key=''ns_reject_ok''',
 'eq', 'rejected', true, 'P4'),

(56, 44,
 '⛔ ORDER IS LOAD-BEARING AND ASSERTED AGAINST prosrc, NOT AGAINST A REVIEW: the never_stock guard precedes the contradiction guard. Hoisting the contradiction check above it would send CS to revoke a live always_stock pin in order to unblock an approval that would still fail afterwards',
 'SELECT (strpos(p.prosrc, ''not yet consumed by the engine'') > 0 AND strpos(p.prosrc, ''not yet consumed by the engine'') < strpos(p.prosrc, ''contradicts live pin''))::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = ''public'' AND p.proname = ''approve_feedback_proposal_v3''',
 'eq', 'true', true, 'P4'),

(56, 45,
 '⛔ ANTI-VACUITY for probe (l): the reject probe actually ran. A missing scratch key reads NULL and seq 43 would pass over nothing',
 'SELECT count(*)::text FROM golden.scratch WHERE fixture_id=56 AND key = ''ns_reject_ok''',
 'eq', '1', true, 'P4');
