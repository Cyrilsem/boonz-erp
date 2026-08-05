-- PRD-110 P4.3b · FIXTURE 58 v2 — `pairs` means EVALUABLE pairs, and the fixture
-- must be able to tell that from "non-tied pairs".
--
-- WHY THIS EXISTS. Leg 86 recorded the expected live yield as "1318 pairs, 68.6%".
-- Leg 87 reproduced 68.57% exactly but got 474 pairs. Measured live, over the same
-- 24 learnable days and 1653 ordered (kept, dropped) pairs:
--     1318 = pairs where empty_shelves_count is non-null on BOTH sides (EVALUABLE)
--      474 = pairs that are not ties            (concordant 325 + discordant 149)
--      844 = ties, i.e. 64% of the evidence base
-- The prediction was the evaluable count; the first implementation stored the
-- non-tied count. `pwp_pairs_coherent` settles which was intended - Cody wrote it
-- as `concordant + discordant <= pairs`, and a `<=` is only meaningful if pairs
-- carries the ties.
--
-- ⛔ AND THE ORIGINAL FIXTURE COULD NOT TELL THE DIFFERENCE. Its population had no
-- ties and no NULLs, so evaluable = non-tied = 120 and it passed under EITHER
-- definition. That is the S-132 failure mode: an assertion that reads strict and
-- discriminates nothing. v2 adds a fifth kept machine, K5, which:
--   · TIES with D2 on empty_shelves_count and days_since_visit  -> pairs > conc+disc
--   · is NULL on empty_shelf_pct and expired_skus_now           -> pairs 120 < 150
-- so the two counts now differ in BOTH directions and no single definition
-- satisfies the whole fixture by accident.
--
-- Hiding the ties is not a rounding matter. "474 pairs at 68.6%" and "1318 pairs
-- at 68.6%, 64% of them ties" are different claims about how much CS's selection
-- actually discriminates, and only the second one is checkable.

UPDATE golden.fixtures SET
  notes = 'Synthetic machines_to_visit rows on 2030-03-05..2030-03-14 - 8 machines x 10 days = 80 rows, 5 kept across 2 route clusters and 3 dropped, so every day classifies mixed_capacity and is_learnable. 15 ordered pairs/day, 150 over the window. K5 exists to separate EVALUABLE pairs from NON-TIED pairs: it ties with D2 on two features and is NULL on the other two. Leaves 2 pending picker_weight_proposals_v3 rows behind by design, reclaimed by the fixture''s own window marker on every re-run.',
  scenario_sql =
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
  -- Article 8 (Cody, leg 87): this fixture fires tg_audit_machines_to_visit 160
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
    FROM (SELECT machine_id FROM public.machines ORDER BY machine_id LIMIT 8) t;
  IF v_m IS NULL OR array_length(v_m, 1) <> 8 THEN
    RAISE EXCEPTION 'FX58 setup: needed 8 machines, got % - the fixture would assert over nothing',
      COALESCE(array_length(v_m, 1), 0);
  END IF;

  ------------------------------------------------ plant the pick history -----
  -- Per day: 5 kept (2 clusters, so kept_clusters > 1 => is_learnable) and 3
  -- dropped => 15 ordered (kept, dropped) pairs, 150 over the window.
  --
  --   empty_shelves_count  K 0,5,6,7,[2] vs D 1,2,3  -> 100c/40d/10 TIES
  --                        pairs 150, comparable 140, 71.43%
  --   days_since_visit     K 10,1,2,3,[6] vs D 5,6,7 ->  40c/100d/10 TIES
  --                        pairs 150, comparable 140, 28.57%
  --   empty_shelf_pct      K 5,15,40,50,[NULL] vs D 10,20,30 -> 70c/50d
  --                        pairs 120 - K5's NULL is not evidence, so 30 of the
  --                        same 150 pairs are not evaluable at all
  --   expired_skus_now     K 5,15,40,50,[NULL] vs D 10,20,30 -> 70c/50d
  --                        pairs 120, 58.33% - deliberately just over the band so
  --                        w_expiry's move rounds back onto 0.120 (S-137)
  --
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
        (1, 'K1', 'AMAZON', false, 0,  5.0::numeric, 10,  5::int, 50.0),
        (2, 'K2', 'AMAZON', false, 5, 15.0,          1, 15,       51.0),
        (3, 'K3', 'WPP',    false, 6, 40.0,          2, 40,       52.0),
        (4, 'K4', 'WPP',    false, 7, 50.0,          3, 50,       53.0),
        -- K5: ties with D2 on two features, NULL on the other two. It is the
        -- entire reason this fixture can distinguish evaluable from non-tied.
        (5, 'K5', 'AMAZON', false, 2, NULL,          6, NULL,     49.0),
        (6, 'D1', 'AMAZON', true,  1, 10.0,          5, 10,       54.0),
        (7, 'D2', 'AMAZON', true,  2, 20.0,          6, 20,       55.0),
        (8, 'D3', 'AMAZON', true,  3, 30.0,          7, 30,       56.0)
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

  -- 5 days: below pl_min_days (8) AND below pl_min_pairs (70 comparable < 100).
  -- Both gates must be reported, not just the first one the code happens to test.
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
WHERE fixture_id = 58;

-- ---------------------------------------------------------------------------
-- Revised assertions. S-103: an assertion edit is TWO fields - the expect AND
-- the description, or the next reader trusts a sentence the check no longer makes.
-- ---------------------------------------------------------------------------
UPDATE golden.assertions SET
  description = 'the fixture planted exactly 8 machines x 10 days of pick history',
  expect = '80'
WHERE fixture_id = 58 AND seq = 2;

UPDATE golden.assertions SET
  description = 'w_empty carries 150 EVALUABLE pairs: the lead feature''s own count, never the 270 sum across both features on this dial, and never the 140 non-tied subset',
  expect = '150'
WHERE fixture_id = 58 AND seq = 11;

UPDATE golden.assertions SET
  description = 'w_empty concordant/discordant split is exactly 100/40 - which leaves 10 pairs unaccounted for, and that is the point',
  expect = '100/40'
WHERE fixture_id = 58 AND seq = 12;

UPDATE golden.assertions SET
  description = 'w_empty concordance is 71.43 percent, computed over the 140 pairs that discriminate and not over all 150',
  expect = '71.43'
WHERE fixture_id = 58 AND seq = 13;

UPDATE golden.assertions SET
  description = 'w_empty moves 0.900 -> 0.958, which is 20pct scaled by (21.43-8)/(50-8)',
  expect = '0.900 -> 0.958'
WHERE fixture_id = 58 AND seq = 15;

UPDATE golden.assertions SET
  description = 'w_stale is led by days_since_visit at 28.57 percent',
  expect = 'days_since_visit 28.57'
WHERE fixture_id = 58 AND seq = 17;

UPDATE golden.assertions SET
  description = 'w_stale moves 0.130 -> 0.122 - the same 6.395pct magnitude, applied downward',
  expect = '0.130 -> 0.122'
WHERE fixture_id = 58 AND seq = 18;

-- seq 22 was `concordant + discordant = pairs`. Under the corrected semantics
-- that equality is FALSE whenever a tie exists, and asserting it would lock in
-- the defect. It becomes the constraint Cody actually wrote.
UPDATE golden.assertions SET
  description = 'every proposal satisfies pwp_pairs_coherent: the discriminating pairs are a subset of the evaluable ones',
  check_sql = $q$SELECT count(*)::text FROM public.picker_weight_proposals_v3
     WHERE window_start = DATE '2030-03-05' AND concordant + discordant > pairs$q$,
  expect = '0'
WHERE fixture_id = 58 AND seq = 22;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required, acceptance_gate_sql)
VALUES
(58, 40, 'TIES ARE EVIDENCE AND ARE COUNTED: w_empty''s 150 evaluable pairs less its 140 discriminating ones leaves exactly the 10 pairs where a kept and a dropped machine had the same empty-shelf count',
 $q$SELECT (pairs - concordant - discordant)::text FROM public.picker_weight_proposals_v3
     WHERE window_start = DATE '2030-03-05' AND target_param = 'w_empty'$q$,
 'eq', '10', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 41, 'A NULL IS NOT EVIDENCE: over the identical 150 pairs, empty_shelf_pct is evaluable on only 120 because K5 has no value - so the two features on this dial legitimately disagree about how much evidence exists',
 $q$SELECT (c ->> 'pairs') || '/' || (c ->> 'comparable_pairs')
     FROM golden.scratch s, jsonb_array_elements(s.value -> 'candidates') c
    WHERE s.fixture_id = 58 AND s.key = 'run_main' AND c ->> 'feature' = 'empty_shelf_pct'$q$,
 'eq', '120/120', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$),

(58, 42, 'and the gate is applied to the DISCRIMINATING count, not the evaluable one - w_empty reports both and they differ',
 $q$SELECT (t ->> 'pairs') || '/' || (t ->> 'comparable_pairs')
     FROM golden.scratch s, jsonb_array_elements(s.value -> 'targets') t
    WHERE s.fixture_id = 58 AND s.key = 'run_main' AND t ->> 'target_param' = 'w_empty'$q$,
 'eq', '150/140', 'P4', $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'mine_pick_history_v3')$g$);
