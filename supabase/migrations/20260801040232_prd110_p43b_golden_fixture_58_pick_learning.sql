-- PRD-110 P4.3b · GOLDEN FIXTURE 58 — the WS-H4 pick-learning miner
--
-- LAW 1: this fixture lands BEFORE mine_pick_history_v3 exists. Its acceptance
-- gate is the miner's existence, so every assertion below is an "expected red"
-- until the miner ships and a TRUE red the moment it regresses afterwards.
--
-- WHAT IT PROVES
--   · the arithmetic, end to end, against a population whose concordance is
--     constructed to the pair — 75.00 / 58.33 / 25.00 / 58.33
--   · TWO features on ONE dial collapse to ONE proposal whose `pairs` is the
--     LEAD's 120 and never the sum 240 (summing double-counts the same machines)
--   · polarity is read from picker_feature_param_map_v3.param_rewards, so a
--     one-row UPDATE can falsify the sign (the mutant test)
--   · S-137: a candidate that rounds back onto its current weight is SKIPPED by
--     name and does NOT abort the run that carries the other proposals
--   · S-138 (a) and (b): the parked weight application is re-proven EVERY run,
--     because "the function doesn't write it" is a comment until something checks
--
-- HERMETICITY: the mining window 2030-03-05..2030-03-14 is FX58's private band.
-- No other fixture and no live row occupies it (verified at build: 0 rows). The
-- scenario refuses to run if anything foreign appears there — a fixture that
-- silently measures someone else's population is worse than a red one.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, notes, enabled, baseline_status, scenario_sql)
VALUES (
  58,
  'The WS-H4 pick-learning miner turns CS''s keep/drop history into weight proposals it can honestly defend: two features on one dial collapse to a single proposal led by the stronger, a dial whose move rounds back onto itself is refused by name instead of crashing the run, polarity comes from a table so the sign is falsifiable, and the parked weight application is re-proven every single run (P4.3b)',
  'PRD-110 P4.3 / charter WS-H4. Calibration at leg 86 found the picker''s own composite score is a coin flip (50.0%) against CS''s judgment while empty_shelves_count reaches 68.6%; S-137 (a correct CHECK is also a crash path) and S-138 (parking by construction is not parking by structure) were both raised out of that review.',
  'P4',
  DATE '2030-02-28',
  'Synthetic machines_to_visit rows on 2030-03-05..2030-03-14 — 7 machines x 10 days = 70 rows, 4 kept across 2 route clusters and 3 dropped, so every day classifies mixed_capacity and is_learnable. 12 pairs/day, 120 per feature. Leaves 2 pending picker_weight_proposals_v3 rows behind by design, reclaimed by the fixture''s own window marker on every re-run, so the counters are stable.',
  true,
  'failing_expected',
$scenario$
DO $fx58$
DECLARE
  d0 date := DATE '2030-03-05';
  dN date := DATE '2030-03-14';
  v_m uuid[];
  v_day date;
  v_alien int; v_planted int; v_foreign_pending int;
  v_pwp_before int; v_pwp_after_dry int; v_pwp_after_main int; v_pwp_after_second int;
  v_pup_before timestamptz; v_pup_after timestamptz;
  r_dry jsonb; r_main jsonb; r_second jsonb; r_narrow jsonb;
  v_rpc_name text; v_zero_refusal text;
BEGIN
  -- Article 8 (Cody, leg 87): this fixture fires tg_audit_machines_to_visit 140
  -- times per run. Without a name every one of those write_audit_log rows reads
  -- as an unexplained hand-write on the picker's own table. via_rpc stays false
  -- because that is the truth - this is a harness write, not an RPC - but it
  -- says who it was. The miner overwrites rpc_name with its own when it runs.
  PERFORM set_config('app.rpc_name', 'golden.fixture_58', true);

  ------------------------------------------------------------------ reclaim --
  -- S-134: reclaim by FX58's OWN marker, never a shared anchor. The proposals
  -- are keyed by the fixture's private mining window; the visit rows by 'FX58'.
  DELETE FROM public.picker_weight_proposals_v3
   WHERE window_start = d0 AND window_end = dN;
  DELETE FROM public.machines_to_visit
   WHERE plan_date BETWEEN d0 AND dN AND 'FX58' = ANY(picked_reasons);
  DELETE FROM golden.scratch WHERE fixture_id = 58;

  ------------------------------------------------- the window must be OURS ---
  SELECT count(*) INTO v_alien FROM public.machines_to_visit
   WHERE plan_date BETWEEN d0 AND dN AND NOT ('FX58' = ANY(picked_reasons));
  IF v_alien > 0 THEN
    RAISE EXCEPTION 'FX58: % foreign machines_to_visit row(s) sit inside the mining window %..% - this fixture would silently measure a population it did not build. Move the other fixture; ids 59-104 are unused.',
      v_alien, d0, dN;
  END IF;

  -- The dedup gate the miner applies is GLOBAL (one pending row per dial), so a
  -- foreign pending proposal would make the main run refuse and redden this
  -- fixture for a reason that has nothing to do with the miner.
  SELECT count(*) INTO v_foreign_pending
    FROM public.picker_weight_proposals_v3
   WHERE status = 'pending' AND NOT (window_start = d0 AND window_end = dN);
  IF v_foreign_pending > 0 THEN
    RAISE EXCEPTION 'FX58: % pending picker_weight_proposals_v3 row(s) outside this fixture''s window. Review or reject them (or park them) before running 58 - the miner''s one-pending-row-per-dial rule would otherwise refuse this fixture''s proposals.',
      v_foreign_pending;
  END IF;

  SELECT array_agg(machine_id ORDER BY machine_id) INTO v_m
    FROM (SELECT machine_id FROM public.machines ORDER BY machine_id LIMIT 7) t;
  IF v_m IS NULL OR array_length(v_m, 1) <> 7 THEN
    RAISE EXCEPTION 'FX58 setup: needed 7 machines, got % - the fixture would assert over nothing',
      COALESCE(array_length(v_m, 1), 0);
  END IF;

  ------------------------------------------------ plant the pick history -----
  -- Per day: 4 kept (2 clusters, so kept_clusters > 1 => is_learnable) and 3
  -- dropped => 12 ordered (kept, dropped) pairs. Values chosen so that across
  -- the 10 days each feature lands on an exact, hand-checkable concordance:
  --   empty_shelves_count  K 0,5,6,7   vs D 1,2,3    ->  90c/30d = 75.00%
  --   empty_shelf_pct      K 5,15,40,50 vs D 10,20,30 -> 70c/50d = 58.33%
  --   days_since_visit     K 10,1,2,3  vs D 5,6,7    ->  30c/90d = 25.00%
  --   expired_skus_now     K 5,15,40,50 vs D 10,20,30 -> 70c/50d = 58.33%
  -- priority_score runs deliberately BACKWARDS (every kept below every dropped)
  -- to prove the composite is never mined: it is an output, not an input.
  FOR v_day IN SELECT generate_series(d0, dN, INTERVAL '1 day')::date LOOP
    INSERT INTO public.machines_to_visit
      (plan_date, machine_id, official_name, route_cluster, service_track, add_source,
       status, dropped_at, dropped_by, dropped_reason,
       empty_shelves_count, empty_shelf_pct, days_since_visit, expired_skus_now,
       priority_score, active_intent_count, is_ramping, picked_reasons, picked_at,
       is_included, fill_pct, dead_slot_pct, hero_slot_count, units_last_7d, runway_days)
    SELECT v_day, v_m[r.idx], 'FX58-' || r.role, r.cluster, 'main', 'picker',
           CASE WHEN r.dropped THEN 'cs_dropped' ELSE 'picked' END,
           CASE WHEN r.dropped THEN now() END,
           CASE WHEN r.dropped THEN 'FX58' END,
           CASE WHEN r.dropped THEN 'FX58 synthetic same-day capacity drop' END,
           r.esc, r.esp, r.dsv, r.exp, r.prio, 1, false, ARRAY['FX58'], now(),
           NOT r.dropped, 50, 10, 2, 100, 5
      FROM (VALUES
        (1, 'K1', 'AMAZON', false, 0,  5.0, 10,  5, 50.0),
        (2, 'K2', 'AMAZON', false, 5, 15.0,  1, 15, 51.0),
        (3, 'K3', 'WPP',    false, 6, 40.0,  2, 40, 52.0),
        (4, 'K4', 'WPP',    false, 7, 50.0,  3, 50, 53.0),
        (5, 'D1', 'AMAZON', true,  1, 10.0,  5, 10, 54.0),
        (6, 'D2', 'AMAZON', true,  2, 20.0,  6, 20, 55.0),
        (7, 'D3', 'AMAZON', true,  3, 30.0,  7, 30, 56.0)
      ) AS r(idx, role, cluster, dropped, esc, esp, dsv, exp, prio);
  END LOOP;

  SELECT count(*) INTO v_planted FROM public.machines_to_visit
   WHERE plan_date BETWEEN d0 AND dN AND 'FX58' = ANY(picked_reasons);

  SELECT max(updated_at) INTO v_pup_before FROM public.pick_urgency_params;
  SELECT count(*) INTO v_pwp_before FROM public.picker_weight_proposals_v3;

  ---------------------------------------------------------------------- run --
  -- S-121: the harness runs as postgres, so auth.uid() is NULL and the Article 4
  -- role gate short-circuits - proving the gate EXISTS but never that it ADMITS.
  PERFORM set_config('request.jwt.claims',
    '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);

  -- dry first: must compute the same answer and write nothing
  r_dry := public.mine_pick_history_v3(dN, 10, true);
  SELECT count(*) INTO v_pwp_after_dry FROM public.picker_weight_proposals_v3;

  r_main := public.mine_pick_history_v3(dN, 10, false);
  v_rpc_name := current_setting('app.rpc_name', true);
  SELECT count(*) INTO v_pwp_after_main FROM public.picker_weight_proposals_v3;

  -- unchanged inputs, second time: one pending row per dial, so nothing new
  r_second := public.mine_pick_history_v3(dN, 10, false);
  SELECT count(*) INTO v_pwp_after_second FROM public.picker_weight_proposals_v3;

  -- 5 days: below pl_min_days (8) AND below pl_min_pairs (60 < 100). Both gates
  -- must be reported, not just the first one the code happens to test.
  r_narrow := public.mine_pick_history_v3(dN, 5, true);

  BEGIN
    PERFORM public.mine_pick_history_v3(dN, 0, true);
    v_zero_refusal := 'NOT_REFUSED';
  EXCEPTION WHEN OTHERS THEN
    v_zero_refusal := SQLERRM;
  END;

  SELECT max(updated_at) INTO v_pup_after FROM public.pick_urgency_params;

  INSERT INTO golden.scratch(fixture_id, key, value) VALUES
    (58, 'run_dry',     r_dry),
    (58, 'run_main',    r_main),
    (58, 'run_second',  r_second),
    (58, 'run_narrow',  r_narrow),
    (58, 'planted',            to_jsonb(v_planted)),
    (58, 'foreign_pending',    to_jsonb(v_foreign_pending)),
    (58, 'pwp_before',         to_jsonb(v_pwp_before)),
    (58, 'pwp_after_dry',      to_jsonb(v_pwp_after_dry)),
    (58, 'pwp_after_main',     to_jsonb(v_pwp_after_main)),
    (58, 'pwp_after_second',   to_jsonb(v_pwp_after_second)),
    (58, 'pup_before',         to_jsonb(v_pup_before::text)),
    (58, 'pup_after',          to_jsonb(v_pup_after::text)),
    (58, 'rpc_name_after_run', to_jsonb(v_rpc_name)),
    (58, 'window_days_0_refusal', to_jsonb(v_zero_refusal));
END $fx58$;
$scenario$
);

-- ---------------------------------------------------------------------------
-- Assertions. Every one is gated on the miner existing, so the fixture reads as
-- an expected red today and as a true red the day it regresses.
-- ---------------------------------------------------------------------------
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required, acceptance_gate_sql)
VALUES
(58, 1, 'the mining window contains no row this fixture did not create',
 $q$SELECT count(*)::text FROM public.machines_to_visit
     WHERE plan_date BETWEEN DATE '2030-03-05' AND DATE '2030-03-14'
       AND NOT ('FX58' = ANY(picked_reasons))$q$,
 'eq', '0', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 2, 'the fixture planted exactly 7 machines x 10 days of pick history',
 $q$SELECT (value #>> '{}') FROM golden.scratch WHERE fixture_id = 58 AND key = 'planted'$q$,
 'eq', '70', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 3, 'no pending proposal outside this fixture window could have suppressed its dials',
 $q$SELECT (value #>> '{}') FROM golden.scratch WHERE fixture_id = 58 AND key = 'foreign_pending'$q$,
 'eq', '0', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 4, 'all 10 planted days classify mixed_capacity and are learnable',
 $q$SELECT count(*)::text FROM public.v_pick_decision_cohorts_v3
     WHERE plan_date BETWEEN DATE '2030-03-05' AND DATE '2030-03-14'
       AND is_learnable AND cohort = 'mixed_capacity'$q$,
 'eq', '10', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 5, 'the miner reads its learnable days from the cohort view and finds all 10',
 $q$SELECT value ->> 'learnable_days' FROM golden.scratch WHERE fixture_id = 58 AND key = 'run_main'$q$,
 'eq', '10', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 6, 'S-137 - the round-to-equal candidate did NOT abort the run that carried the others',
 $q$SELECT value ->> 'ok' FROM golden.scratch WHERE fixture_id = 58 AND key = 'run_main'$q$,
 'eq', 'true', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 7, 'the main run creates exactly two proposals',
 $q$SELECT value ->> 'proposals_created' FROM golden.scratch WHERE fixture_id = 58 AND key = 'run_main'$q$,
 'eq', '2', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 8, 'and exactly two rows persist in the fixture window',
 $q$SELECT count(*)::text FROM public.picker_weight_proposals_v3
     WHERE window_start = DATE '2030-03-05' AND window_end = DATE '2030-03-14'$q$,
 'eq', '2', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 9, 'w_empty: CS keeps the emptier machine, so the dial is raised',
 $q$SELECT direction FROM public.picker_weight_proposals_v3
     WHERE window_start = DATE '2030-03-05' AND target_param = 'w_empty'$q$,
 'eq', 'raise', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 10, 'w_empty is led by the STRONGER of its two features, not the first one',
 $q$SELECT lead_feature FROM public.picker_weight_proposals_v3
     WHERE window_start = DATE '2030-03-05' AND target_param = 'w_empty'$q$,
 'eq', 'empty_shelves_count', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 11, 'w_empty carries the LEAD feature''s 120 pairs and never the sum 240 - the two features compare the same machines',
 $q$SELECT pairs::text FROM public.picker_weight_proposals_v3
     WHERE window_start = DATE '2030-03-05' AND target_param = 'w_empty'$q$,
 'eq', '120', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 12, 'w_empty concordant/discordant split is exactly 90/30',
 $q$SELECT concordant::text || '/' || discordant::text FROM public.picker_weight_proposals_v3
     WHERE window_start = DATE '2030-03-05' AND target_param = 'w_empty'$q$,
 'eq', '90/30', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 13, 'w_empty concordance is 75.00 percent',
 $q$SELECT concordance_pct::text FROM public.picker_weight_proposals_v3
     WHERE window_start = DATE '2030-03-05' AND target_param = 'w_empty'$q$,
 'eq', '75.00', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 14, 'w_empty covers all 10 days',
 $q$SELECT days_covered::text FROM public.picker_weight_proposals_v3
     WHERE window_start = DATE '2030-03-05' AND target_param = 'w_empty'$q$,
 'eq', '10', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 15, 'w_empty moves 0.900 -> 0.973, which is 20pct scaled by (25.00-8)/(50-8)',
 $q$SELECT current_weight::text || ' -> ' || proposed_weight::text FROM public.picker_weight_proposals_v3
     WHERE window_start = DATE '2030-03-05' AND target_param = 'w_empty'$q$,
 'eq', '0.900 -> 0.973', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 16, 'w_stale: CS keeps the RECENTLY visited machine, so a high-rewarding dial is LOWERED',
 $q$SELECT direction FROM public.picker_weight_proposals_v3
     WHERE window_start = DATE '2030-03-05' AND target_param = 'w_stale'$q$,
 'eq', 'lower', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 17, 'w_stale is led by days_since_visit at 25.00 percent',
 $q$SELECT lead_feature || ' ' || concordance_pct::text FROM public.picker_weight_proposals_v3
     WHERE window_start = DATE '2030-03-05' AND target_param = 'w_stale'$q$,
 'eq', 'days_since_visit 25.00', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 18, 'w_stale moves 0.130 -> 0.119 - the same 8.095pct magnitude, applied downward',
 $q$SELECT current_weight::text || ' -> ' || proposed_weight::text FROM public.picker_weight_proposals_v3
     WHERE window_start = DATE '2030-03-05' AND target_param = 'w_stale'$q$,
 'eq', '0.130 -> 0.119', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 19, 'w_expiry mints NO proposal - at 0.120 its 0.157pct move rounds back onto itself',
 $q$SELECT count(*)::text FROM public.picker_weight_proposals_v3
     WHERE window_start = DATE '2030-03-05' AND target_param = 'w_expiry'$q$,
 'eq', '0', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 20, 'and the run says so BY NAME - silence would be indistinguishable from a bug',
 $q$SELECT t ->> 'refused' FROM golden.scratch s, jsonb_array_elements(s.value -> 'targets') t
     WHERE s.fixture_id = 58 AND s.key = 'run_main' AND t ->> 'target_param' = 'w_expiry'$q$,
 'eq', 'round_to_equal', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 21, 'no proposal is led by a feature the map has refused - priority_score runs backwards here and is still never mined',
 $q$SELECT count(*)::text FROM public.picker_weight_proposals_v3 p
     JOIN public.picker_feature_param_map_v3 m ON m.feature = p.lead_feature
     WHERE p.window_start = DATE '2030-03-05' AND NOT m.is_active$q$,
 'eq', '0', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 22, 'every proposal is internally coherent: concordant + discordant = pairs',
 $q$SELECT count(*)::text FROM public.picker_weight_proposals_v3
     WHERE window_start = DATE '2030-03-05' AND concordant + discordant <> pairs$q$,
 'eq', '0', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 23, 'every proposal records the window it was mined from',
 $q$SELECT count(*)::text FROM public.picker_weight_proposals_v3
     WHERE window_start = DATE '2030-03-05' AND window_end = DATE '2030-03-14'
       AND status = 'pending' AND reviewed_at IS NULL AND applied_at IS NULL
       AND applied_weight IS NULL$q$,
 'eq', '2', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 24, 'the dry run wrote nothing',
 $q$SELECT ((SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id = 58 AND key = 'pwp_after_dry')
        = (SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id = 58 AND key = 'pwp_before'))::text$q$,
 'eq', 'true', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 25, 'the dry run computed the same two proposals it declined to write',
 $q$SELECT (value ->> 'proposals_would_create') || '/' || (value ->> 'proposals_created')
     FROM golden.scratch WHERE fixture_id = 58 AND key = 'run_dry'$q$,
 'eq', '2/0', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 26, 'a second identical run mints nothing - one pending row per dial',
 $q$SELECT value ->> 'proposals_created' FROM golden.scratch WHERE fixture_id = 58 AND key = 'run_second'$q$,
 'eq', '0', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 27, 'and it refuses both dials by name rather than silently',
 $q$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value -> 'targets') t
     WHERE s.fixture_id = 58 AND s.key = 'run_second' AND t ->> 'refused' = 'pending_exists'$q$,
 'eq', '2', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 28, 'the row count is unchanged after the second run',
 $q$SELECT (value #>> '{}') FROM golden.scratch WHERE fixture_id = 58 AND key = 'pwp_after_second'$q$,
 'eq', '2', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 29, 'a 5-day window proposes nothing at all',
 $q$SELECT (value ->> 'proposals_would_create') FROM golden.scratch
     WHERE fixture_id = 58 AND key = 'run_narrow'$q$,
 'eq', '0', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 30, 'and it names BOTH failed gates, not merely the first one tested',
 $q$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value -> 'targets') t
     WHERE s.fixture_id = 58 AND s.key = 'run_narrow'
       AND t ->> 'refused' LIKE '%below_min_days%'
       AND t ->> 'refused' LIKE '%below_min_pairs%'$q$,
 'gte', '2', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 31, 'a non-positive window is refused by name',
 $q$SELECT (value #>> '{}') FROM golden.scratch WHERE fixture_id = 58 AND key = 'window_days_0_refusal'$q$,
 'contains', 'window_days must be positive', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 32, 'S-138(a) - the parked weight application: pick_urgency_params is byte-unchanged across a real mining run',
 $q$SELECT ((SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id = 58 AND key = 'pup_after')
        = (SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id = 58 AND key = 'pup_before'))::text$q$,
 'eq', 'true', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 33, 'S-138(a) - and it still sits at the weights CS last set on 2026-07-13',
 $q$SELECT max(updated_at)::text FROM public.pick_urgency_params$q$,
 'eq', '2026-07-13 17:36:38.481583+00', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 34, 'S-138(b) - the miner body contains no write of any kind against pick_urgency_params',
 $q$SELECT (prosrc !~* '(insert[[:space:]]+into|update|delete[[:space:]]+from)[[:space:]]+(public\.)?pick_urgency_params')::text
     FROM pg_proc WHERE proname = 'mine_pick_history_v3'$q$,
 'eq', 'true', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 35, 'the miner is SECURITY DEFINER with search_path pinned',
 $q$SELECT (p.prosecdef AND EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%'))::text
     FROM pg_proc p WHERE p.proname = 'mine_pick_history_v3'$q$,
 'eq', 'true', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 36, 'and grants EXECUTE to nobody anonymous - Supabase default privileges name anon explicitly',
 $q$SELECT (COALESCE(proacl::text, '') NOT LIKE '%anon=%')::text
     FROM pg_proc WHERE proname = 'mine_pick_history_v3'$q$,
 'eq', 'true', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 37, 'exactly one overload exists - an accidental second signature is a foot-gun',
 $q$SELECT count(*)::text FROM pg_proc WHERE proname = 'mine_pick_history_v3'$q$,
 'eq', '1', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 38, 'Article 4 - the run stamped its own name for the write-audit trigger',
 $q$SELECT (value #>> '{}') FROM golden.scratch WHERE fixture_id = 58 AND key = 'rpc_name_after_run'$q$,
 'eq', 'mine_pick_history_v3', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 39, 'every active feature->dial mapping still clears the monotonicity bar it was admitted under',
 $q$SELECT count(*)::text FROM public.picker_feature_param_map_v3 m, public.refill_policy_params r
     WHERE m.is_active AND (m.monotonicity IS NULL OR abs(m.monotonicity) < r.pl_monotonicity_bar)$q$,
 'eq', '0', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$);
