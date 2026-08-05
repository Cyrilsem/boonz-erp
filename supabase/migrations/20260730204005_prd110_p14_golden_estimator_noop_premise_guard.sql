-- PRD-110 relay leg 25 · S-28 ESCALATED
--
-- MEASURED THIS LEG inside a rollback envelope, not inferred:
--   first  estimate_shelf_composition_v3(shelf, false) -> events_written=7, already_processed_skipped=0
--   second estimate_shelf_composition_v3(shelf, false) -> events_written=0, already_processed_skipped=1
-- The estimator body (prosrc line 59-60) takes an "already processed this snapshot for this
-- shelf -> CONTINUE" branch keyed on source_ref='estimator:<snapshot_at>'. So once ANY caller
-- has consumed the current WEIMI snapshot for a shelf, every later call on that shelf writes
-- NOTHING until a new snapshot lands.
--
-- Fixtures 20 and 22 are the ONLY two of the eleven that call the estimator. Both target
-- machines cron 44 does not currently cover (NOVO-1023, NISSAN-0804), so both are green today.
-- The moment D-08 expands cron 44 fleet-wide the cron consumes the snapshot first and both
-- fixtures' own estimator calls become silent no-ops.
--
-- WHY THIS IS WORSE THAN A COUNT DRIFT (S-28 recorded only fixture 22 seq 1):
--   * fixture 22 post-flip, measured: candidates 2->8, drops_allocated 1->0,
--     estimator_events 2->0, decayed_by_estimator 1->0. The whole PART-1 chain, not one seq.
--   * fixture 20 is the LAW 7 (EXPIRY IRON RULE) proof and its assertions are shaped
--     "the expired bucket was NOT touched" / "0 unallocatable residuals". A no-op makes those
--     pass VACUOUSLY - the S-29 class, in the one fixture that proves LAW 7.
--
-- This migration does NOT fix the no-op. It makes the no-op IMPOSSIBLE TO MISS, by adding a
-- run-time premise assertion (seq 89) to both fixtures: "my own estimator call actually ran".
-- Touches the golden harness only: no production object, no protected entity, no DEFINER,
-- no RLS, no engine body. Cody-reviewed (class (f)); revisions 1 and 2 applied.
--
-- Apply attempt 1 FAILED on the Cody-revision-1 guard ("reached 1 of 2"): fixture 20's
-- 'a_events_written' key is NOT adjacent to its jsonb_build_object( line (line 52 vs 47), so
-- the two-line anchor never matched. The whole migration rolled back with nothing half-applied,
-- which is exactly what the end-state guard was added to produce.

-- 1. fixture 22: surface the estimator's own skip counter in the observation payload
UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
$old$    v_payload := jsonb_build_object(
      'candidates',$old$,
$new$    v_payload := jsonb_build_object(
      'estimator_noop_skipped', v_est->>'already_processed_skipped',
      'candidates',$new$)
 WHERE fixture_id = 22;

-- 2. fixture 20: same, summed over BOTH shelves it estimates. Anchored on the single exact
--    line rather than on adjacency, per the attempt-1 failure.
UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
$old$      'a_events_written',  v_est->>'events_written',$old$,
$new$      'estimator_noop_skipped', (((v_est->>'already_processed_skipped')::int
                                + (v_estb->>'already_processed_skipped')::int))::text,
      'a_events_written',  v_est->>'events_written',$new$)
 WHERE fixture_id = 20;

-- 3. Cody revision 1: guard on the END STATE, not on "the replace fired".
--    A byte-mismatched anchor would otherwise ship an assertion reading a key that never
--    exists; testing the end state also makes this migration safely re-runnable.
DO $chk$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM golden.fixtures
   WHERE fixture_id IN (20,22) AND scenario_sql LIKE '%estimator_noop_skipped%';
  IF n <> 2 THEN
    RAISE EXCEPTION 'PRD-110 leg25: scenario_sql anchor replace reached % of 2 fixtures', n;
  END IF;
END $chk$;

-- 4. the premise assertions themselves.
--    Cody revision 2 verified before apply: golden.compare returns false when the actual is
--    NULL, so an absent key FAILS rather than silently passing.
INSERT INTO golden.assertions
  (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required, acceptance_gate_sql)
VALUES
 (20, 89,
  'PREMISE: this fixture''s own estimator calls actually ran (0 skipped as already-processed). If cron 44 consumed the snapshot first, the EXPIRY IRON RULE assertions below would pass vacuously.',
  $q$SELECT value->>'estimator_noop_skipped' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$,
  'eq', '0', true, 'P1', NULL),
 (22, 89,
  'PREMISE: this fixture''s own estimator call actually ran (0 skipped as already-processed). If cron 44 consumed the snapshot first, the multi-SKU split assertions below measure nothing.',
  $q$SELECT value->>'estimator_noop_skipped' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$,
  'eq', '0', true, 'P1', NULL);

-- 5. record the finding where a bisecting leg will read it (S-04 house pattern)
UPDATE golden.fixtures
   SET notes = COALESCE(notes,'') || E'\n\n[leg 25 · S-28 ESCALATED] This fixture calls '
     || 'estimate_shelf_composition_v3 on a LIVE shelf. That call is idempotent per WEIMI '
     || 'snapshot (source_ref=''estimator:<snapshot_at>''), so once cron 44 has consumed the '
     || 'current snapshot for this shelf the fixture''s own call writes NOTHING and every '
     || 'assertion downstream of it measures a no-op. Measured leg 25: first call '
     || 'events_written=7/skipped=0, second call events_written=0/skipped=1. seq 89 is the '
     || 'premise guard - if it goes red, the cause is "the cron got here first", NOT the '
     || 'estimator. The durable fix (a re-derive path so a caller that has deliberately '
     || 'perturbed belief can re-run) is owed BEFORE D-08 goes fleet-wide.'
 WHERE fixture_id IN (20,22);
