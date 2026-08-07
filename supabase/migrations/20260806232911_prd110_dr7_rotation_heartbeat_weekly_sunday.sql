-- PRD-110 · DR-7 · leg 141
-- CS RULING (2026-08-04): "DR-7 CLOSED: SCHEDULE ROTATION HEARTBEAT WEEKLY,
-- SUNDAY (align with D-32 facing review)."
-- Cody ✅ class (e), Articles 1/4/11/12.
--
-- SCHEDULE: '30 1 * * 0' = 01:30 UTC Sunday = 05:30 Dubai Sunday.
--   ⭐ Deliberately the SAME wall-clock minute as the existing weekly miners job
--     (prd110_p43d_weekly_miners_0530_dubai, '30 1 * * 1'), one day EARLIER. So
--     CS opens a Sunday review to a rotation queue refreshed that morning, and
--     the Monday miner batch then mines a week that already contains it. The
--     Dubai hour is the one this build already established for weekly work; a
--     new hour would be an unexplained second convention.
--
-- ⛔ THE COMMAND CARRIES NO DRY-RUN OVERRIDE (Article 11, and the doctrine
--    fixture 60 seq 16 already pins for the miners cron): an override inside a
--    cron body puts a decision where nobody looks for it. p_dry_run defaults to
--    false, and minting the advisory queue IS the heartbeat's job.
--
-- ⛔ WHY A WEEKLY REPEAT IS SAFE, ASSERTED NOT ASSUMED: propose_rotations_v3
--    inserts ON CONFLICT ON CONSTRAINT rp_v3_unique_heartbeat DO NOTHING, keyed
--    (plan_date, source_shelf_id, target_shelf_id). Without that pair a repeating
--    schedule would either raise 23505 into the cron log or duplicate the queue.
--    Fixture 43 seq 60 below pins BOTH halves.
--
-- ⛔ NOT FIRED HERE. DR-7 schedules; it does not run. A manual first fire would
--    mint 25 proposals (measured by dry run at 2026-08-06 23:2xZ) that CS never
--    asked for today. The first real fire is 2026-08-09.
-- ⛔ Writes no protected entity and no live plan table (LAW 12): the RPC's only
--    write target is rotation_proposals_v3, always at status 'pending'.

DO $dr7$
DECLARE v_existing int; v_jobid bigint; v_n int;
BEGIN
  SELECT count(*) INTO v_existing FROM cron.job
   WHERE jobname = 'prd110_dr7_rotation_heartbeat_0530_sunday_dubai';
  IF v_existing > 0 THEN
    RAISE EXCEPTION 'DR-7: a job named prd110_dr7_rotation_heartbeat_0530_sunday_dubai already exists - refusing to overwrite it';
  END IF;

  SELECT count(*) INTO v_n FROM cron.job WHERE command ILIKE '%propose_rotations_v3%';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'DR-7: % cron job(s) already call propose_rotations_v3', v_n;
  END IF;

  SELECT cron.schedule(
    'prd110_dr7_rotation_heartbeat_0530_sunday_dubai',
    '30 1 * * 0',
    'SELECT public.propose_rotations_v3(public.resolve_refill_plan_date());'
  ) INTO v_jobid;

  PERFORM 1 FROM cron.job
   WHERE jobid = v_jobid AND active
     AND schedule = '30 1 * * 0'
     AND jobname  = 'prd110_dr7_rotation_heartbeat_0530_sunday_dubai'
     AND command  = 'SELECT public.propose_rotations_v3(public.resolve_refill_plan_date());';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DR-7: job % did not land with the ruled name, schedule and bare command', v_jobid;
  END IF;

  RAISE NOTICE 'DR-7: rotation heartbeat scheduled as jobid % (Sunday 05:30 Dubai)', v_jobid;
END
$dr7$;

INSERT INTO golden.assertions
  (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
 (43, 56,
  'DR-7: the rotation heartbeat job exists and is ACTIVE on the ruled cadence - weekly, SUNDAY, '
  || '05:30 Dubai (01:30 UTC). ⛔ Asserted as name|schedule|active together: a job that exists but '
  || 'is inactive is the failure mode a bare existence check reads as green.',
  'SELECT jobname || ''|'' || schedule || ''|'' || active::text FROM cron.job'
  || E'\n     WHERE jobname = ''prd110_dr7_rotation_heartbeat_0530_sunday_dubai''',
  'eq', 'prd110_dr7_rotation_heartbeat_0530_sunday_dubai|30 1 * * 0|true', true, 'P3'),

 (43, 57,
  '⛔ DR-7: the command is the EXACT bare RPC call with NO dry-run override (Article 11). '
  || 'p_dry_run defaults to false, so the heartbeat mints; an override written into the cron body '
  || 'would hide that decision where nobody looks for it. Same doctrine as fixture 60 seq 16.',
  'SELECT command FROM cron.job WHERE jobname = ''prd110_dr7_rotation_heartbeat_0530_sunday_dubai''',
  'eq', 'SELECT public.propose_rotations_v3(public.resolve_refill_plan_date());', true, 'P3'),

 (43, 58,
  'DR-7: exactly ONE cron job calls propose_rotations_v3 - two schedules would double-run the '
  || 'heartbeat and make the queue''s provenance unreadable.',
  'SELECT count(*)::text FROM cron.job WHERE command ILIKE ''%propose_rotations_v3%''',
  'eq', '1', true, 'P3'),

 (43, 59,
  'DR-7: the job runs as postgres, the role that holds EXECUTE - a job owned by anyone else fails '
  || 'silently into cron.job_run_details where nobody reads it.',
  'SELECT username FROM cron.job WHERE jobname = ''prd110_dr7_rotation_heartbeat_0530_sunday_dubai''',
  'eq', 'postgres', true, 'P3'),

 (43, 60,
  '⭐ DR-7: THE WEEKLY CADENCE IS ONLY SAFE BECAUSE THE HEARTBEAT IS IDEMPOTENT, so both halves are '
  || 'pinned here: the unique constraint rp_v3_unique_heartbeat (plan_date, source_shelf_id, '
  || 'target_shelf_id) AND the ON CONFLICT ... DO NOTHING that honours it. ⛔ Lose either and a '
  || 'repeating schedule either raises 23505 into the cron log or duplicates the review queue.',
  'SELECT (EXISTS (SELECT 1 FROM pg_constraint'
  || E'\n                 WHERE conrelid = ''public.rotation_proposals_v3''::regclass'
  || E'\n                   AND conname = ''rp_v3_unique_heartbeat'' AND contype = ''u'')'
  || E'\n        AND (SELECT prosrc ~* ''on conflict on constraint\\s+rp_v3_unique_heartbeat\\s+do nothing'''
  || E'\n               FROM pg_proc WHERE proname = ''propose_rotations_v3''))::text',
  'eq', 'true', true, 'P3');

DO $dr7_verify$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE fixture_id = 43 AND seq BETWEEN 56 AND 60 AND enabled;
  IF v_n <> 5 THEN
    RAISE EXCEPTION 'DR-7: expected 5 new enabled fixture-43 assertions, found %', v_n;
  END IF;
END
$dr7_verify$;
