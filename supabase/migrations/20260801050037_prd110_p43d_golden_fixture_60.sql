-- PRD-110 leg 89 — golden fixture 60: the weekly miner schedule and its run log.
-- LAW 1: no engine change before the fixture that proves it.
--
-- ⛔ THE ONE FIXTURE THAT CANNOT RECLAIM, AND WHY THAT IS CORRECT.
--    miner_runs_v3 refuses DELETE, UPDATE and TRUNCATE — that is the property
--    under test. So unlike every other fixture, 60 cannot remove what it wrote;
--    each run leaves exactly 2 rows behind forever. This is why `invoked_by`
--    exists as a column: the fixture's rows are stamped 'fixture' and any board
--    reads WHERE invoked_by = 'cron'. Every count assertion below is therefore
--    scoped to the run's OWN batch_id or expressed as a DELTA, never as a
--    global total — a global count would drift by 2 on every run and the
--    fixture would be red the second time it was ever executed.
--
-- ⛔ WHY THE SCENARIO PASSES EXPLICIT dry-run OVERRIDES.
--    run_weekly_miners_v3 defaults to the refill_policy_params dials. Those
--    dials are TRUE today, but the parked CS activation is to flip them FALSE —
--    and on that day a fixture that relied on the defaults would start MINTING
--    LIVE PROPOSALS every time the harness ran. So the scenario always passes
--    true/true explicitly (permitted: the harness runs as postgres, where
--    auth.uid() is NULL). Seq 12 and 13 pin the dials separately, so the flip
--    is still detected — as a re-baselineable assertion rather than as a test
--    that quietly starts writing production data.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes, enabled, baseline_status)
VALUES (
  60,
  'The weekly miner schedule is not theatre: a dry run''s findings are persisted, two miners with different vocabularies normalise to one row shape, the log refuses to be edited, and the parked live-minting dials cannot be bypassed by the caller',
  'PRD-110 P4.3d + leg 89. cron.job_run_details keeps a return message, not the miner payload, so an unlogged dry-run cron discards everything it learns. Discovered at build: fixture 58 residue already occupies the GLOBAL one-pending-row-per-dial slot, so the live pick miner is refused with pending_exists by test data rather than by evidence.',
  'P4',
  -- ⚠️ golden.fixtures_plan_date_check requires the DECLARED plan_date to sit
  --    inside 2030. This fixture does not use the {{plan_date}} token: the
  --    miners read their own trailing windows off the live calendar.
  DATE '2030-06-02',
$fx60body$
DO $fx60$
DECLARE
  v_r          jsonb;
  v_batch      uuid;
  v_mr_before  int;
  v_pwp_before int;
  v_fp_before  int;
  v_pin_before int;
  v_del  text := 'NOT REFUSED';
  v_upd  text := 'NOT REFUSED';
  v_trc  text := 'NOT REFUSED';
  v_esc  text := 'NOT REFUSED';
  v_c1   text := 'NOT REFUSED';
  v_c2   text := 'NOT REFUSED';
  v_c3   text := 'NOT REFUSED';
  v_c4   text := 'NOT REFUSED';
  v_c5   text := 'NOT REFUSED';
  v_c6   text := 'NOT REFUSED';
  v_c7   text := 'NOT REFUSED';
  v_bad  text := 'NOT REFUSED';
BEGIN
  -- Article 8: name the harness write. via_rpc stays false because that is the
  -- truth — this is a harness write, not an RPC. The runner overwrites both
  -- while it logs, and restores them; seq 51/52 prove the restore.
  PERFORM set_config('app.rpc_name', 'golden.fixture_60', true);

  -- S-134: reclaim by this fixture's OWN marker. The scratch rows are all
  -- fixture 60 can take back; the miner_runs_v3 rows are permanent by design.
  DELETE FROM golden.scratch WHERE fixture_id = 60;

  SELECT count(*) INTO v_mr_before  FROM public.miner_runs_v3;
  SELECT count(*) INTO v_pwp_before FROM public.picker_weight_proposals_v3;
  SELECT count(*) INTO v_fp_before  FROM public.feedback_proposals_v3;
  SELECT count(*) INTO v_pin_before FROM public.planning_pins_v3;

  ------------------------------------------------------------- the run ------
  v_r := public.run_weekly_miners_v3('fixture', true, true);
  v_batch := (v_r ->> 'batch_id')::uuid;

  ------------------------------------------------- the log refuses edits ----
  BEGIN
    DELETE FROM public.miner_runs_v3 WHERE batch_id = v_batch;
  EXCEPTION WHEN OTHERS THEN v_del := SQLERRM; END;

  BEGIN
    UPDATE public.miner_runs_v3 SET status = 'error' WHERE batch_id = v_batch;
  EXCEPTION WHEN OTHERS THEN v_upd := SQLERRM; END;

  BEGIN
    TRUNCATE public.miner_runs_v3;
  EXCEPTION WHEN OTHERS THEN v_trc := SQLERRM; END;

  ------------------------------------- the dials cannot be walked around ----
  -- A uuid that is deliberately NOT in user_profiles: the guard must refuse an
  -- unknown authenticated caller, not merely a known non-admin one.
  -- ⛔ THE OVERRIDE PASSED HERE IS true/true, NOT false/false, ON PURPOSE. The
  --    guard fires on "an override was supplied at all", so true/true tests it
  --    exactly as well — and on the day someone deletes the guard, this probe
  --    degrades to a harmless extra dry run instead of MINTING LIVE PROPOSALS
  --    from inside a test.
  BEGIN
    PERFORM set_config('request.jwt.claims',
      '{"sub":"00000000-0000-0000-0000-000000000009","role":"authenticated"}', true);
    PERFORM public.run_weekly_miners_v3('manual', true, true);
  EXCEPTION WHEN OTHERS THEN v_esc := SQLERRM; END;
  PERFORM set_config('request.jwt.claims', '', true);

  -- Same reasoning, plus this pins the ORDER of the two guards: p_invoked_by is
  -- validated BEFORE the override check and before any miner runs, so the
  -- message that comes back must be the invoked_by one.
  BEGIN
    PERFORM public.run_weekly_miners_v3('weekly', true, true);
  EXCEPTION WHEN OTHERS THEN v_bad := SQLERRM; END;

  --------------------------------------------- every CHECK actually bites ---
  BEGIN
    INSERT INTO public.miner_runs_v3
      (batch_id, miner, invoked_by, dry_run, status, proposals_created, started_at)
    VALUES (v_batch, 'mine_pick_history_v3', 'fixture', true, 'ok', 1, now());
  EXCEPTION WHEN OTHERS THEN v_c1 := SQLERRM; END;

  BEGIN
    INSERT INTO public.miner_runs_v3
      (batch_id, miner, invoked_by, dry_run, status, started_at)
    VALUES (v_batch, 'mine_pick_history_v3', 'fixture', true, 'error', now());
  EXCEPTION WHEN OTHERS THEN v_c2 := SQLERRM; END;

  BEGIN
    INSERT INTO public.miner_runs_v3
      (batch_id, miner, invoked_by, dry_run, status, error_text, started_at)
    VALUES (v_batch, 'mine_pick_history_v3', 'fixture', true, 'ok', 'boom', now());
  EXCEPTION WHEN OTHERS THEN v_c3 := SQLERRM; END;

  BEGIN
    INSERT INTO public.miner_runs_v3
      (batch_id, miner, invoked_by, dry_run, status, started_at, finished_at)
    VALUES (v_batch, 'mine_pick_history_v3', 'fixture', true, 'ok',
            now(), now() - interval '1 hour');
  EXCEPTION WHEN OTHERS THEN v_c4 := SQLERRM; END;

  BEGIN
    INSERT INTO public.miner_runs_v3
      (batch_id, miner, invoked_by, dry_run, status, started_at)
    VALUES (v_batch, 'mine_something_else_v3', 'fixture', true, 'ok', now());
  EXCEPTION WHEN OTHERS THEN v_c5 := SQLERRM; END;

  BEGIN
    INSERT INTO public.miner_runs_v3
      (batch_id, miner, invoked_by, dry_run, status, started_at)
    VALUES (v_batch, 'mine_pick_history_v3', 'weekly', true, 'ok', now());
  EXCEPTION WHEN OTHERS THEN v_c6 := SQLERRM; END;

  BEGIN
    INSERT INTO public.miner_runs_v3
      (batch_id, miner, invoked_by, dry_run, status, refusals, started_at)
    VALUES (v_batch, 'mine_pick_history_v3', 'fixture', true, 'ok',
            '{"code":"x"}'::jsonb, now());
  EXCEPTION WHEN OTHERS THEN v_c7 := SQLERRM; END;

  ------------------------------------------------------------- snapshot -----
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES
    (60, 'batch_id', to_jsonb(v_batch::text)),
    (60, 'run',      v_r - 'runs'),
    (60, 'deltas',   jsonb_build_object(
       'miner_runs',  (SELECT count(*) FROM public.miner_runs_v3)                - v_mr_before,
       'pwp',         (SELECT count(*) FROM public.picker_weight_proposals_v3)   - v_pwp_before,
       'proposals',   (SELECT count(*) FROM public.feedback_proposals_v3)        - v_fp_before,
       'pins',        (SELECT count(*) FROM public.planning_pins_v3)             - v_pin_before)),
    (60, 'guards',   jsonb_build_object(
       'delete', v_del, 'update', v_upd, 'truncate', v_trc, 'escalation', v_esc,
       'bad_invoked_by', v_bad,
       'dry_mints', v_c1, 'error_null', v_c2, 'ok_with_error', v_c3,
       'time_travel', v_c4, 'bad_miner', v_c5, 'bad_invoked_col', v_c6,
       'refusals_not_array', v_c7)),
    (60, 'gucs',     jsonb_build_object(
       'via_rpc',  COALESCE(current_setting('app.via_rpc',  true), '<unset>'),
       'rpc_name', COALESCE(current_setting('app.rpc_name', true), '<unset>')));
END
$fx60$;
$fx60body$,
  'Leaves 2 permanent miner_runs_v3 rows per run, stamped invoked_by=fixture - the object under test refuses DELETE, so this is by design, not a leak. All counts are batch-scoped or deltas. ~150 ms.',
  true,
  'passing'
)
ON CONFLICT (fixture_id) DO UPDATE SET
  name            = EXCLUDED.name,
  source_incident = EXCLUDED.source_incident,
  phase_required  = EXCLUDED.phase_required,
  plan_date       = EXCLUDED.plan_date,
  scenario_sql    = EXCLUDED.scenario_sql,
  notes           = EXCLUDED.notes,
  enabled         = EXCLUDED.enabled,
  baseline_status = EXCLUDED.baseline_status;

DELETE FROM golden.assertions WHERE fixture_id = 60;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
SELECT 60, t.seq, t.descr, t.sql, t.op, t.expect, true, 'P4'
FROM (VALUES

-- A. the object exists in the shape Cody approved -------------------------
(1,'miner_runs_v3 has RLS enabled (Article 2)',
 $q$SELECT relrowsecurity::text FROM pg_class WHERE oid='public.miner_runs_v3'::regclass$q$,'eq','true'),
(2,'⭐ the WHOLE relacl string matches the v3 fleet convention (S-140: a "no anon" assertion passes straight over an over-granted authenticated)',
 $q$SELECT relacl::text FROM pg_class WHERE oid='public.miner_runs_v3'::regclass$q$,'eq',
 '{postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres,authenticated=r/postgres}'),
(3,'⛔ the WHOLE proacl of the runner: service_role only. authenticated must NOT hold EXECUTE - it can mint live proposals once the dials flip',
 $q$SELECT proacl::text FROM pg_proc WHERE oid='public.run_weekly_miners_v3(text,boolean,boolean)'::regprocedure$q$,'eq',
 '{postgres=X/postgres,service_role=X/postgres}'),
(4,'the pure tally helper is readable by authenticated and never by anon',
 $q$SELECT proacl::text FROM pg_proc WHERE oid='public.miner_refusal_tally_v3(text[])'::regprocedure$q$,'eq',
 '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
(5,'exactly ONE overload of the runner - a second one would be a silent fork of the schedule',
 $q$SELECT count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='run_weekly_miners_v3'$q$,'eq','1'),
(6,'exactly ONE overload of the tally helper',
 $q$SELECT count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='miner_refusal_tally_v3'$q$,'eq','1'),
(7,'the runner is SECURITY DEFINER with search_path pinned (Article 4)',
 $q$SELECT (p.prosecdef::text || '|' || COALESCE(array_to_string(p.proconfig,','),'<none>')) FROM pg_proc p WHERE p.oid='public.run_weekly_miners_v3(text,boolean,boolean)'::regprocedure$q$,'eq',
 'true|search_path=public, pg_temp'),
(8,'the tally helper is IMMUTABLE and INVOKER - it reads nothing, so DEFINER would be unearned privilege',
 $q$SELECT (p.provolatile::text || '|' || p.prosecdef::text) FROM pg_proc p WHERE p.oid='public.miner_refusal_tally_v3(text[])'::regprocedure$q$,'eq','i|false'),
(9,'both append-only triggers are installed, row-level AND statement-level (Article 7: a row trigger never sees a TRUNCATE)',
 $q$SELECT string_agg(tgname, ',' ORDER BY tgname) FROM pg_trigger WHERE tgrelid='public.miner_runs_v3'::regclass AND NOT tgisinternal$q$,'eq',
 'tg_miner_runs_v3_append_only,tg_miner_runs_v3_no_truncate'),
(10,'both access-path indexes exist (latest-run-per-miner, and one batch)',
 $q$SELECT string_agg(indexname, ',' ORDER BY indexname) FROM pg_indexes WHERE schemaname='public' AND tablename='miner_runs_v3' AND indexname LIKE 'idx_%'$q$,'eq',
 'idx_miner_runs_v3_batch,idx_miner_runs_v3_miner_started'),
(11,'exactly one policy, SELECT-only - no INSERT policy exists, so only the DEFINER runner can write',
 $q$SELECT string_agg(polname || ':' || polcmd::text, ',' ORDER BY polname) FROM pg_policy WHERE polrelid='public.miner_runs_v3'::regclass$q$,'eq','mr_v3_select:r'),

-- B. the parked decision is still parked ----------------------------------
(12,'⛔ THE PICK MINER''S LIVE-MINTING FLIP IS STILL PARKED. The day CS legitimately flips miner_weekly_pick_dry_run this goes RED - that is the assertion working. Re-baseline expect AND description together (S-103); never weaken to not_null.',
 $q$SELECT miner_weekly_pick_dry_run::text FROM public.refill_policy_params ORDER BY id LIMIT 1$q$,'eq','true'),
(13,'⛔ THE EDIT MINER''S LIVE-MINTING FLIP IS STILL PARKED. Same re-baseline contract as seq 12.',
 $q$SELECT miner_weekly_edit_dry_run::text FROM public.refill_policy_params ORDER BY id LIMIT 1$q$,'eq','true'),
(14,'the synthetic-universe epoch is the harness convention (LAW 12)',
 $q$SELECT miner_fixture_epoch::text FROM public.refill_policy_params ORDER BY id LIMIT 1$q$,'eq','2030-01-01'),

-- C. the schedule ----------------------------------------------------------
(15,'the weekly job exists and is ACTIVE',
 $q$SELECT (jobname || '|' || schedule || '|' || active::text) FROM cron.job WHERE jobname='prd110_p43d_weekly_miners_0530_dubai'$q$,'eq',
 'prd110_p43d_weekly_miners_0530_dubai|30 1 * * 1|true'),
(16,'⛔ the command is the EXACT bare RPC call with NO dry-run override (Article 11). An override here would put the parked decision in a cron body where nobody would look for it.',
 $q$SELECT command FROM cron.job WHERE jobname='prd110_p43d_weekly_miners_0530_dubai'$q$,'eq',
 'SELECT public.run_weekly_miners_v3(p_invoked_by => ''cron'');'),
(17,'exactly ONE cron job calls the runner - two schedules would double-log and double-mine',
 $q$SELECT count(*)::text FROM cron.job WHERE command LIKE '%run_weekly_miners_v3%'$q$,'eq','1'),
(18,'the job runs as postgres, which is the only role that holds EXECUTE besides service_role',
 $q$SELECT username FROM cron.job WHERE jobname='prd110_p43d_weekly_miners_0530_dubai'$q$,'eq','postgres'),

-- D. the wrapper did not touch the proven miners ---------------------------
(19,'⛔ S-122: mine_edit_history_v3 is BYTE-UNCHANGED. The whole justification for a wrapper is that neither proven miner is rewritten; if this md5 moves, that claim is false and fixture 57 must be re-run before this expect is updated.',
 $q$SELECT md5(prosrc) FROM pg_proc WHERE oid='public.mine_edit_history_v3(date,integer,integer,uuid,integer,boolean)'::regprocedure$q$,'eq',
 'a9db274c0e88048ea9825c13ed8caba8'),
(20,'⛔ S-122: mine_pick_history_v3 is BYTE-UNCHANGED. Same contract as seq 19, with fixture 58.',
 $q$SELECT md5(prosrc) FROM pg_proc WHERE oid='public.mine_pick_history_v3(date,integer,boolean)'::regprocedure$q$,'eq',
 '8d8d915c8bb85c1c4b9393a501c68ee9'),

-- E. the tally is pure and every branch is reachable without a miner -------
(21,'NULL input tallies to an empty ARRAY, not to NULL - a run with nothing to refuse and a run whose refusals were lost must not look the same',
 $q$SELECT public.miner_refusal_tally_v3(NULL)::text$q$,'eq','[]'),
(22,'empty input tallies to an empty array',
 $q$SELECT public.miner_refusal_tally_v3('{}'::text[])::text$q$,'eq','[]'),
(23,'repeats are counted and the result is ordered by n DESC',
 $q$SELECT public.miner_refusal_tally_v3(ARRAY['a','b','a'])::text$q$,'eq',
 '[{"n": 2, "code": "a"}, {"n": 1, "code": "b"}]'),
(24,'a NULL element is dropped rather than tallied as a code named NULL',
 $q$SELECT public.miner_refusal_tally_v3(ARRAY[NULL,NULL]::text[])::text$q$,'eq','[]'),
(25,'ties break on code ASC, so the output is deterministic and diffable run to run',
 $q$SELECT public.miner_refusal_tally_v3(ARRAY['b','a'])::text$q$,'eq',
 '[{"n": 1, "code": "a"}, {"n": 1, "code": "b"}]'),

-- F. the run itself --------------------------------------------------------
(26,'the run wrote exactly TWO rows, one per miner, sharing one batch_id',
 $q$SELECT count(*)::text FROM public.miner_runs_v3 WHERE batch_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=60 AND key='batch_id')$q$,'eq','2'),
(27,'both miners are represented - a batch that silently ran only one is the failure this column exists to catch',
 $q$SELECT string_agg(miner, ',' ORDER BY miner) FROM public.miner_runs_v3 WHERE batch_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=60 AND key='batch_id')$q$,'eq',
 'mine_edit_history_v3,mine_pick_history_v3'),
(28,'both rows completed ok',
 $q$SELECT string_agg(DISTINCT status, ',') FROM public.miner_runs_v3 WHERE batch_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=60 AND key='batch_id')$q$,'eq','ok'),
(29,'both rows are dry runs and both minted exactly nothing',
 $q$SELECT (bool_and(dry_run) AND sum(proposals_created)=0)::text FROM public.miner_runs_v3 WHERE batch_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=60 AND key='batch_id')$q$,'eq','true'),
(30,'the log grew by exactly 2 - the runner writes one row per miner and nothing else writes here',
 $q$SELECT (value ->> 'miner_runs') FROM golden.scratch WHERE fixture_id=60 AND key='deltas'$q$,'eq','2'),
(31,'⛔ ZERO picker weight proposals were minted by a dry run',
 $q$SELECT (value ->> 'pwp') FROM golden.scratch WHERE fixture_id=60 AND key='deltas'$q$,'eq','0'),
(32,'⛔ ZERO feedback proposals were minted by a dry run',
 $q$SELECT (value ->> 'proposals') FROM golden.scratch WHERE fixture_id=60 AND key='deltas'$q$,'eq','0'),
(33,'⛔ ZERO pins were created - the edit miner routes through the proposal queue, never straight to a pin',
 $q$SELECT (value ->> 'pins') FROM golden.scratch WHERE fixture_id=60 AND key='deltas'$q$,'eq','0'),
(34,'the batch echoes back which dials it ran under, so a log row can always be read against the decision in force at the time',
 $q$SELECT ((value ->> 'pick_dry_run') || '|' || (value ->> 'edit_dry_run') || '|' || (value ->> 'invoked_by')) FROM golden.scratch WHERE fixture_id=60 AND key='run'$q$,'eq',
 'true|true|fixture'),
(35,'every refusal element carries BOTH keys and a positive count - a tally that lost its shape would still be a jsonb array',
 $q$SELECT bool_and((e ->> 'code') IS NOT NULL AND (e ->> 'n')::int > 0)::text
      FROM public.miner_runs_v3 m, LATERAL jsonb_array_elements(m.refusals) e
     WHERE m.batch_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=60 AND key='batch_id')$q$,'eq','true'),
(36,'the edit miner''s refusals normalised out of skipped[].reason - a run that refused everything and a run with no candidates are different events',
 $q$SELECT (jsonb_array_length(refusals) >= 1)::text FROM public.miner_runs_v3 WHERE miner='mine_edit_history_v3' AND batch_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=60 AND key='batch_id')$q$,'eq','true'),
(37,'the pick miner''s refusals normalised out of TWO different places in its payload (refusals[] and targets[].refused)',
 $q$SELECT (jsonb_array_length(refusals) >= 2)::text FROM public.miner_runs_v3 WHERE miner='mine_pick_history_v3' AND batch_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=60 AND key='batch_id')$q$,'eq','true'),
(38,'the full miner payload is kept verbatim - this is the entire point of the table, and an empty payload means the dry run learned nothing that survived',
 $q$SELECT bool_and(jsonb_typeof(payload)='object' AND payload <> '{}'::jsonb)::text FROM public.miner_runs_v3 WHERE batch_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=60 AND key='batch_id')$q$,'eq','true'),
(39,'⭐ the environment warning is SCOPED to the miner it can explain: only the pick miner contends for ux_pwp_one_pending_per_param, and the expected value is recomputed independently here rather than hardcoded',
 $q$SELECT (m.warnings = CASE WHEN EXISTS (SELECT 1 FROM public.picker_weight_proposals_v3 p, public.refill_policy_params r
                                            WHERE p.status='pending' AND p.window_start >= r.miner_fixture_epoch)
                             THEN ARRAY['synthetic_pending_blocks_live_minting'] ELSE '{}'::text[] END)::text
      FROM public.miner_runs_v3 m
     WHERE m.miner='mine_pick_history_v3' AND m.batch_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=60 AND key='batch_id')$q$,'eq','true'),
(40,'⛔ the edit miner NEVER carries the picker warning - a warning attached to a run it cannot explain is how people learn to skip warnings',
 $q$SELECT (warnings = '{}'::text[])::text FROM public.miner_runs_v3 WHERE miner='mine_edit_history_v3' AND batch_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=60 AND key='batch_id')$q$,'eq','true'),
(41,'both runs recorded a real elapsed time - a 0 ms miner run means the call was skipped',
 $q$SELECT bool_and(duration_ms > 0 AND finished_at >= started_at)::text FROM public.miner_runs_v3 WHERE batch_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=60 AND key='batch_id')$q$,'eq','true'),

-- G. the log refuses to be edited -----------------------------------------
(42,'DELETE is refused (Article 7)',
 $q$SELECT (value ->> 'delete') FROM golden.scratch WHERE fixture_id=60 AND key='guards'$q$,'contains','append-only: DELETE refused'),
(43,'UPDATE is refused wholesale - unlike pipeline_runs_v3 there is no approval dimension, so no column may ever change',
 $q$SELECT (value ->> 'update') FROM golden.scratch WHERE fixture_id=60 AND key='guards'$q$,'contains','append-only: UPDATE refused'),
(44,'⛔ TRUNCATE is refused - a row-level trigger never sees it, and GRANT ALL TO service_role carries it',
 $q$SELECT (value ->> 'truncate') FROM golden.scratch WHERE fixture_id=60 AND key='guards'$q$,'contains','append-only: TRUNCATE refused'),

-- H. the dials cannot be walked around ------------------------------------
(45,'⛔ an authenticated caller who is not operator_admin/superadmin CANNOT override the dry-run dials. Without this the parked CS decision would be advisory.',
 $q$SELECT (value ->> 'escalation') FROM golden.scratch WHERE fixture_id=60 AND key='guards'$q$,'contains','requires operator_admin or superadmin'),
(46,'an unrecognised invoked_by is refused BEFORE either miner runs - a call that cannot be logged must not mine',
 $q$SELECT (value ->> 'bad_invoked_by') FROM golden.scratch WHERE fixture_id=60 AND key='guards'$q$,'contains','must be one of cron|manual|fixture'),

-- I. every CHECK bites (S-126: a CHECK that evaluates to NULL PASSES) ------
(47,'a dry run claiming to have minted something is refused',
 $q$SELECT (value ->> 'dry_mints') FROM golden.scratch WHERE fixture_id=60 AND key='guards'$q$,'contains','miner_runs_v3_dry_run_mints_nothing'),
(48,'status=error with no error text is refused, and so is status=ok WITH error text - the coherence check is two-directional',
 $q$SELECT ((value ->> 'error_null') LIKE '%miner_runs_v3_error_coherent%' AND (value ->> 'ok_with_error') LIKE '%miner_runs_v3_error_coherent%')::text FROM golden.scratch WHERE fixture_id=60 AND key='guards'$q$,'eq','true'),
(49,'a run that finished before it started is refused',
 $q$SELECT (value ->> 'time_travel') FROM golden.scratch WHERE fixture_id=60 AND key='guards'$q$,'contains','miner_runs_v3_finished_after_started'),
(50,'an unknown miner name is refused - the log may only describe the two miners that exist',
 $q$SELECT (value ->> 'bad_miner') FROM golden.scratch WHERE fixture_id=60 AND key='guards'$q$,'contains','miner_runs_v3_miner_check'),
(51,'an unknown invoked_by is refused at the column too, not only in the runner',
 $q$SELECT (value ->> 'bad_invoked_col') FROM golden.scratch WHERE fixture_id=60 AND key='guards'$q$,'contains','miner_runs_v3_invoked_by_check'),
(52,'refusals must be a jsonb ARRAY - an object would break every reader that iterates it',
 $q$SELECT (value ->> 'refusals_not_array') FROM golden.scratch WHERE fixture_id=60 AND key='guards'$q$,'contains','miner_runs_v3_refusals_check'),

-- J. the provenance GUC does not leak --------------------------------------
(53,'⛔ app.via_rpc is RESTORED after the runner logs. The GUC leaks across statements in this codebase; a runner that left it set would make the next unrelated write look like an RPC.',
 $q$SELECT (value ->> 'via_rpc') FROM golden.scratch WHERE fixture_id=60 AND key='gucs'$q$,'eq','false'),
(54,'app.rpc_name is cleared too, so the next writer names itself',
 $q$SELECT (value ->> 'rpc_name') FROM golden.scratch WHERE fixture_id=60 AND key='gucs'$q$,'eq','')

) AS t(seq, descr, sql, op, expect);
