-- PRD-110 · leg 139 · S-259 — fixture 53's masking probe is a TIME-BOMB, not a no-op plant.
--
-- ⛔ LEG 138's DIAGNOSIS IS CORRECTED HERE. It read golden.scratch key 'mask' carrying
--    rows_before = rows_after = 249 and concluded "the errored-scheduled-night plant inserted
--    nothing". That inference is wrong, and fixture 53 says so itself: **seq 18 asserts
--    non_destructive = true, i.e. rows_before = rows_after, and it has always been GREEN.**
--    The probe uses fixture 31/37's forced-rollback idiom - it RAISEs on purpose so the two
--    planted rows roll back while the measurements survive in PL/pgSQL variables. Equal
--    counts are the idiom WORKING. The plant landed every time.
--
-- ⭐ THE REAL CAUSE, established by measurement, not by reading. v_shadow_runner_health_v3
--    picks the last scheduled night with:
--        WHERE step='summary' AND note='cron' ORDER BY run_started_at DESC, id DESC LIMIT 1
--    The fixture planted its errored row at now() - INTERVAL '2 hours'. Cron 45 writes a REAL
--    note='cron' summary row every night at 21:22 UTC. At leg 139 the newest real row was
--    2026-08-06 21:22:00Z - **1.16 hours old**. A plant 2 hours old therefore LOSES the
--    ORDER BY to the live cron row, and the view faithfully reports that row's status='ok'.
--    ⇒ seq 15/16/17 read true / ok / ok. Exactly what leg 138 observed.
--
-- ⛔ SO THE FIXTURE WAS GREEN OR RED PURELY BY WALL-CLOCK: the plant only wins when
--    now() - 2h is later than today's 21:22 cron row, i.e. only after 23:22 UTC. Leg 138's
--    sweep ran at 22:08Z - inside the two-hour dead zone. The 18/0 green at 06:30Z the same
--    morning was outside it. Nothing about the engine, the view or the runner changed
--    between those two runs.
--
-- ⭐ v_shadow_runner_health_v3 IS THEREFORE EXONERATED - and now genuinely proven, which it
--    was not before. This matters because it is the object that would hide a failed shadow
--    night ahead of the DR-1 cutover.
--
-- ⭐ THE FIX IS A RECENCY ANCHOR, NOT A LOOSENED ASSERTION. The plant is stamped at
--    GREATEST(now(), newest live cron row) + 1s, so it is unconditionally the row the view
--    selects, at any hour, forever. The manual mask sits 1s later still, preserving the
--    S-113 incident shape (a manual rerun that succeeded AFTER the scheduled night failed)
--    while remaining invisible to `sl`, which filters note='cron'.
--
-- ⛔ AND THE HOLE THAT LET THIS HIDE IS CLOSED BY NEW seq 23: the probe now banks the
--    plan_date the view actually judged and asserts it is the FIXTURE's date. A live cron
--    row can never again silently stand in for the plant - if it does, seq 23 fails at the
--    plant, not three seqs later disguised as a monitoring regression. That is S-259's
--    remedy shape, corrected for the real fault: the detector needed a SELECTION receipt,
--    not an insertion receipt.
--
-- ⛔ No engine, view, runner or RPC is touched. golden.* only. The probe stays
--    non-destructive and seq 18 keeps proving it.

BEGIN;

DO $mig$
DECLARE
  v_old  text;
  v_head text;
  v_pos  int;
  v_new  text;
BEGIN
  SELECT scenario_sql INTO v_old FROM golden.fixtures WHERE fixture_id = 53;
  IF v_old IS NULL THEN
    RAISE EXCEPTION 'S-259: fixture 53 has no scenario_sql';
  END IF;

  v_pos := position('-- (4) S-113, THE MASKING PROBE.' IN v_old);
  IF v_pos = 0 THEN
    RAISE EXCEPTION 'S-259: section (4) marker not found - refusing to rewrite blind';
  END IF;

  -- Everything before section (4) is preserved byte-for-byte. Sections 0-3 are green and
  -- are not this finding's business.
  v_head := left(v_old, v_pos - 1);

  v_new := v_head || $sec$-- (4) S-113, THE MASKING PROBE. A SCHEDULED night that failed outright, plus a
--     MANUAL run that succeeded afterwards -- exactly the 2026-07-31 incident. Health must
--     report the scheduled failure and must not be rescued by the manual run.
--
--     Uses fixture 31/37's forced-rollback idiom: the measurement survives in
--     PL/pgSQL variables, the rows do not. seq 18 proves the rollback worked.
--
-- ⛔ S-259 RECENCY ANCHOR. This probe used to stamp the errored row at now() - 2 hours.
--    v_shadow_runner_health_v3 selects the last scheduled night by
--    (step='summary', note='cron') ORDER BY run_started_at DESC, id DESC LIMIT 1, and cron 45
--    writes a REAL note='cron' row nightly at 21:22 UTC. Between 21:22 and 23:22 UTC the live
--    row is NEWER than a 2-hour-old plant, so the view judged production instead of the
--    fixture and reported ok -- making this fixture green or red by wall-clock alone.
--    Anchoring to GREATEST(now(), newest live cron row) + 1s makes the plant win at any hour.
--    ⭐ Ordered, not literal: it cannot rot when the cron schedule moves.
DO $do$
DECLARE
  v_verdict text; v_healthy text; v_sched text;
  v_before int; v_after int;
  v_anchor timestamptz;
  v_sel_plan_date date;
BEGIN
  IF to_regclass('public.v_shadow_runner_health_v3') IS NULL THEN
    INSERT INTO golden.scratch (fixture_id, key, value)
    VALUES (53, 'mask', jsonb_build_object('verdict','no_health_view'));
    RETURN;
  END IF;

  SELECT count(*) INTO v_before FROM public.shadow_runner_log_v3;

  -- The anchor: strictly newer than every live scheduled row, so `sl` must select ours.
  SELECT GREATEST(now(), COALESCE(max(l.run_started_at), now())) + interval '1 second'
    INTO v_anchor
    FROM public.shadow_runner_log_v3 l
   WHERE l.step = 'summary' AND l.note = 'cron';

  BEGIN
    -- the SCHEDULED night, and it failed outright
    INSERT INTO public.shadow_runner_log_v3
      (run_started_at, plan_date, step, step_target, status, note)
    VALUES (v_anchor, {{plan_date}}, 'summary', {{plan_date}}, 'error', 'cron');

    -- and the MANUAL run that succeeded AFTER it -- the mask. note <> 'cron', so it can
    -- never enter `sl`; that is precisely what seq 15 proves it must not do.
    INSERT INTO public.shadow_runner_log_v3
      (run_started_at, plan_date, step, step_target, status, note)
    VALUES (v_anchor + interval '1 second', {{plan_date}}, 'summary', {{plan_date}}, 'ok',
            'golden_fixture_53_manual_mask');

    SELECT h.verdict, h.is_healthy::text, h.last_scheduled_plan_date
      INTO v_verdict, v_healthy, v_sel_plan_date
      FROM public.v_shadow_runner_health_v3 h;

    BEGIN
      SELECT h.last_scheduled_status INTO v_sched FROM public.v_shadow_runner_health_v3 h;
    EXCEPTION WHEN undefined_column THEN
      v_sched := 'column_absent';
    END;

    RAISE EXCEPTION 'golden_fixture_53_forced_rollback';
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- the measurements survive the rollback; the two rows do not.
  END;

  SELECT count(*) INTO v_after FROM public.shadow_runner_log_v3;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (53, 'mask', jsonb_build_object(
    'verdict',               COALESCE(v_verdict, 'not_measured'),
    'is_healthy',            COALESCE(v_healthy, 'not_measured'),
    'last_scheduled_status', COALESCE(v_sched,   'not_measured'),
    'rows_before',           v_before,
    'rows_after',            v_after,
    'non_destructive',       (v_before = v_after),
    -- ⭐ S-259: the SELECTION receipt. Proves the view judged THIS fixture's planted night
    --    and not a live cron row that happened to be newer.
    'judged_plan_date',      v_sel_plan_date,
    'judged_ours',           (v_sel_plan_date IS NOT DISTINCT FROM {{plan_date}})));
END $do$;
$sec$;

  UPDATE golden.fixtures SET scenario_sql = v_new WHERE fixture_id = 53;

  IF (SELECT scenario_sql FROM golden.fixtures WHERE fixture_id = 53) NOT LIKE '%judged_ours%' THEN
    RAISE EXCEPTION 'S-259: rewrite did not land';
  END IF;
END
$mig$;

-- The assertion that makes a wall-clock substitution impossible to hide again.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(53, 23,
 'S-259: the health view judged THIS FIXTURE''S planted scheduled night, not a live cron row that happened to be newer - the selection receipt that turns a wall-clock coincidence into a loud failure at its own seq',
 $q$SELECT value->>'judged_ours' FROM golden.scratch WHERE fixture_id=53 AND key='mask'$q$,
 'eq', 'true', true, 'P2');   -- P2 to match all 22 incumbent assertions; a P3 tag would let
                              -- this be SKIPPED at lower max_phase, which is the exact way
                              -- a detector goes quiet.

COMMIT;
