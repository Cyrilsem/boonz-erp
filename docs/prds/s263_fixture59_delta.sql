-- PRD-110 · S-263 · fixture 59 ("proposal acceptance object") restated from ABSOLUTE
-- population counts to DELTAS / STABILITY / FORMULA / VERDICT-CONSISTENCY.
--
-- WHY (leg 141 + leg 142):
--   Fixture 59 was authored when it owned every population it measured. DR-5 flipped the
--   miners live, so `feedback_proposals_v3` and `picker_weight_proposals_v3` now carry REAL
--   pre-epoch rows that the fixture did not create. Its scenario RAISEd on exactly that
--   condition, which made it golden's only red.
--
--   S-266 is the sharper reason this must be fixed rather than tolerated: the RAISE aborts
--   the DO block, which ROLLS BACK the fixture's own `DELETE FROM golden.scratch`. Every
--   scratch-reading assertion therefore re-evaluated the PREVIOUS run's snapshot and PASSED.
--   A red fixture 59 reported "n_pass 53" while asserting nothing about the present.
--
-- THE ONE RULE APPLIED:
--   absolute live_*    -> DELTA      (after - before = this fixture's own contribution)
--   absolute fixture_* -> STABILITY  (after IS NOT DISTINCT FROM before)
--   rendered rate      -> FORMULA    (pct = round(100*accepted/decided,2), NULL iff decided=0)
--   literal verdict    -> VERDICT-CONSISTENCY against g12_min_decided + g12_bar_pct
--   FINAL: X = 0       -> final = before  (STRICTLY STRONGER: proves the baseline was RESTORED)
--
-- TWO DELIBERATE DEVIATIONS FROM THE BANKED DESIGN, both strictly stronger (logged, leg 143):
--   seq 6  — leg 142 mapped it to STABILITY, but seq 11 already is that exact claim on the
--            same family/column, so seq 6 would have become a literal duplicate. seq 6 is
--            instead the NON-VACUITY PARTNER for the whole stability family (S-48/S-52/S-55
--            mode): LEAST(fixture_rows over the three stability families) > 0, so seq 11/15/17
--            can never be satisfied by 0 = 0.
--   seq 12 — leg 142 mapped it to DELTA (=8). A delta of 8 is ALSO what a broken view that
--            reported total_rows = live_rows would produce, so the delta loses the original
--            claim. seq 12 is instead the SUM IDENTITY total = live + fixture, which is
--            population-independent AND catches both mis-wirings.
--
-- SAFETY (S-264 lesson, checked before writing): unlike fixture 57 this fixture's DELETEs key
-- on `plan_date = 1999-01-01` / `window_start = 1999-01-01`. No production writer can mint that
-- date, so the reclaim and the cleanup were never a live-data hazard and are LEFT AS THEY ARE.

------------------------------------------------------------------------------------------
-- 1) scenario_sql — delete the foreign-row RAISE, capture `before_sentinel`
------------------------------------------------------------------------------------------
UPDATE golden.fixtures SET scenario_sql = $SCEN$
DO $fx59$
DECLARE
  d_live  date := DATE '1999-01-01';
  v_m     uuid;
  v_bp    uuid;
  v_rev   uuid := '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d';
  v_epoch date;
  v_sent  jsonb;
  v_real_before jsonb; v_real_final jsonb;
  v_before jsonb; v_after jsonb; v_final jsonb;
BEGIN
  -- Article 8 (leg 87's lesson): name the harness write, do not claim it was an RPC.
  PERFORM set_config('app.rpc_name', 'golden.fixture_59', true);

  ------------------------------- CODY (leg 143): THE SENSOR RUNS FIRST -------
  -- ⛔ Captured BEFORE the first DELETE, because a sensor that fires after the
  -- reclaim proves the reclaim WORKED, not that it was SAFE TO RUN. This counts
  -- exactly the rows this fixture is never allowed to touch: the real,
  -- CS-facing, pre-epoch, non-sentinel population in both queues. seq 54 asserts
  -- it UNMOVED at 'final'; seq 55 is its non-vacuity partner (fixture 57's
  -- seq 40/41 pattern). This is the evidence S-264 had to be established BY HAND.
  -- Note: unlike fixture 57 this fixture needs no "guard the guard" on
  -- g12_fixture_epoch - its DELETEs key on the 1999 sentinel and do not consult
  -- the dial at all, so moving the dial can weaken this sensor but can never
  -- widen a DELETE onto live data.
  SELECT g12_fixture_epoch INTO v_epoch
    FROM public.refill_policy_params ORDER BY id LIMIT 1;

  v_real_before := jsonb_build_object(
    'feedback_pins',  (SELECT count(*) FROM public.feedback_proposals_v3
                        WHERE plan_date    < v_epoch AND plan_date    <> d_live),
    'picker_weights', (SELECT count(*) FROM public.picker_weight_proposals_v3
                        WHERE window_start < v_epoch AND window_start <> d_live));
  v_real_before := v_real_before || jsonb_build_object('total',
              (v_real_before->>'feedback_pins')::int + (v_real_before->>'picker_weights')::int);

  ------------------------------------------------------------------ reclaim --
  -- S-134: reclaim by THIS fixture's own marker (the 1999 sentinel), never a
  -- shared anchor. Survives a hard session kill in the previous run.
  -- S-264: these two DELETEs can never reach a real row - no production writer
  -- mints plan_date/window_start = 1999-01-01. That is why they stay unscoped.
  DELETE FROM public.feedback_proposals_v3      WHERE plan_date    = d_live;
  DELETE FROM public.picker_weight_proposals_v3 WHERE window_start = d_live;
  DELETE FROM golden.scratch WHERE fixture_id = 59;

  ------------------------------------------------- S-263: the ONE absolute ---
  -- Recorded IMMEDIATELY after the reclaim and before anything is planted. This
  -- is the durable form of the old seq 5 ("nothing of OURS survived the last
  -- run") - the only claim in this fixture that does not depend on a population
  -- it no longer owns. Every other population claim is now a DELTA vs 'before'.
  v_sent := jsonb_build_object(
    'feedback_pins',  (SELECT count(*) FROM public.feedback_proposals_v3      WHERE plan_date    = d_live),
    'picker_weights', (SELECT count(*) FROM public.picker_weight_proposals_v3 WHERE window_start = d_live));
  v_sent := v_sent || jsonb_build_object('total',
              (v_sent->>'feedback_pins')::int + (v_sent->>'picker_weights')::int);
  INSERT INTO golden.scratch(fixture_id, key, value) VALUES (59, 'before_sentinel', v_sent);
  INSERT INTO golden.scratch(fixture_id, key, value) VALUES (59, 'real_before', v_real_before);

  ------------------------------------------------------------------------------
  -- ⛔ THE FOREIGN-ROW RAISE IS GONE ON PURPOSE (S-263/S-266). Real pre-epoch
  -- proposals are now the NORMAL state of the world: DR-5 flipped both miners
  -- live on 2026-08-06. Guarding against them made the fixture red, and by
  -- S-266 it also made the other 52 assertions lie GREEN off a stale snapshot.
  ------------------------------------------------------------------------------

  SELECT machine_id INTO v_m  FROM public.machines       ORDER BY machine_id LIMIT 1;
  SELECT product_id INTO v_bp FROM public.boonz_products ORDER BY product_id LIMIT 1;
  IF v_m IS NULL OR v_bp IS NULL THEN
    RAISE EXCEPTION 'FX59 setup: no machine/product to hang proposals on - the fixture would assert over nothing';
  END IF;

  v_before := (SELECT jsonb_object_agg(family, to_jsonb(v))
                 FROM public.v_proposal_acceptance_v3 v);
  INSERT INTO golden.scratch(fixture_id, key, value) VALUES (59, 'before', v_before);

  BEGIN
    ------------------------------------------------------------------ plant --
    -- feedback_pins: 4 approved + 1 rejected + 2 pending + 1 superseded.
    -- decided = 5, which is EXACTLY g12_min_decided, at 80% -> pass.
    -- The superseded row is the S-139 member-of-the-difference: it proves
    -- 'withdrawn' is excluded from the denominator rather than counted a reject.
    INSERT INTO public.feedback_proposals_v3
      (plan_date, machine_id, boonz_product_id, pin_kind, pin_value, pin_mode,
       feedback_ids, trigger_reason, status, reviewed_by, reviewed_at)
    SELECT d_live, v_m, v_bp, 'min_facing', 2, 'perpetual',
           ARRAY[gen_random_uuid()], 'FX59 ' || t.st, t.st,
           CASE WHEN t.st IN ('approved','rejected') THEN v_rev END,
           CASE WHEN t.st IN ('approved','rejected') THEN now() END
      FROM (VALUES ('approved'),('approved'),('approved'),('approved'),
                   ('rejected'),('pending'),('pending'),('superseded')) AS t(st);

    -- picker_weights: 1 applied + 4 rejected -> decided = 5 at 20% -> fail.
    -- The applied row proves 'applied' maps to accepted, not to a fourth state.
    -- ⛔ NOT ONE PENDING ROW: fixture 58 hard-RAISEs on any pending
    --    picker_weight_proposals_v3 row outside its own window, and
    --    ux_pwp_one_pending_per_param would collide with a live miner proposal.
    INSERT INTO public.picker_weight_proposals_v3
      (window_start, window_end, target_param, current_weight, proposed_weight,
       direction, lead_feature, concordance_pct, pairs, concordant, discordant,
       days_covered, status, reviewed_by, reviewed_at, applied_at, applied_weight)
    SELECT d_live, d_live + 9, t.param, 0.900, 0.945, 'raise',
           'empty_shelves_count', 68.57, 100, 60, 40, 24, t.st,
           CASE WHEN t.st = 'rejected' THEN v_rev END,
           CASE WHEN t.st = 'rejected' THEN now() END,
           CASE WHEN t.st = 'applied'  THEN now() END,
           CASE WHEN t.st = 'applied'  THEN 0.945 END
      FROM (VALUES ('w_empty','applied'), ('w_expiry','rejected'),
                   ('w_stale','rejected'), ('w_holes','rejected'),
                   ('w_runout','rejected')) AS t(param, st);

    v_after := (SELECT jsonb_object_agg(family, to_jsonb(v))
                  FROM public.v_proposal_acceptance_v3 v);
    INSERT INTO golden.scratch(fixture_id, key, value) VALUES (59, 'after', v_after);
  EXCEPTION WHEN OTHERS THEN
    -- The subtransaction rolls the plants back on its own; re-raise so the
    -- harness records a THROWN scenario (S-135) instead of green-over-nothing.
    RAISE;
  END;

  ---------------------------------------------------------------- cleanup ----
  -- No live-looking proposal may outlive this fixture. Proven by seq 45-47:
  -- FINAL must return to the BEFORE baseline, not merely to zero.
  DELETE FROM public.feedback_proposals_v3      WHERE plan_date    = d_live;
  DELETE FROM public.picker_weight_proposals_v3 WHERE window_start = d_live;

  v_final := (SELECT jsonb_object_agg(family, to_jsonb(v))
                FROM public.v_proposal_acceptance_v3 v);
  INSERT INTO golden.scratch(fixture_id, key, value) VALUES (59, 'final', v_final);

  -- CODY (leg 143): the other half of the safety sensor. Same predicate, after
  -- everything this fixture does. seq 54 compares the two.
  v_real_final := jsonb_build_object(
    'feedback_pins',  (SELECT count(*) FROM public.feedback_proposals_v3
                        WHERE plan_date    < v_epoch AND plan_date    <> d_live),
    'picker_weights', (SELECT count(*) FROM public.picker_weight_proposals_v3
                        WHERE window_start < v_epoch AND window_start <> d_live));
  v_real_final := v_real_final || jsonb_build_object('total',
              (v_real_final->>'feedback_pins')::int + (v_real_final->>'picker_weights')::int);
  INSERT INTO golden.scratch(fixture_id, key, value) VALUES (59, 'real_final', v_real_final);
END
$fx59$;
$SCEN$
WHERE fixture_id = 59;

------------------------------------------------------------------------------------------
-- 2) the assertions
------------------------------------------------------------------------------------------
DO $mig$
DECLARE
  aft text := '(SELECT value FROM golden.scratch WHERE fixture_id=59 AND key=''after'')';
  bef text := '(SELECT value FROM golden.scratch WHERE fixture_id=59 AND key=''before'')';
  fin text := '(SELECT value FROM golden.scratch WHERE fixture_id=59 AND key=''final'')';

  t_delta text := E'SELECT ( ({AFT} -> ''{FAM}'' ->> ''{COL}'')::int\n       - ({BEF} -> ''{FAM}'' ->> ''{COL}'')::int )::text';

  t_stable_int text := E'SELECT ( ({AFT} -> ''{FAM}'' ->> ''{COL}'')::int\n         IS NOT DISTINCT FROM\n         ({BEF} -> ''{FAM}'' ->> ''{COL}'')::int )::text';

  t_stable_num text := E'SELECT ( ({AFT} -> ''{FAM}'' ->> ''{COL}'')::numeric\n         IS NOT DISTINCT FROM\n         ({BEF} -> ''{FAM}'' ->> ''{COL}'')::numeric )::text';

  t_final text := E'SELECT ( ({FIN} -> ''{FAM}'' ->> ''{COL}'')::int\n         IS NOT DISTINCT FROM\n         ({BEF} -> ''{FAM}'' ->> ''{COL}'')::int )::text';

  t_formula text := E'SELECT ( ({K} -> ''{FAM}'' ->> ''{P}_acceptance_pct'')::numeric\n         IS NOT DISTINCT FROM\n         CASE WHEN ({K} -> ''{FAM}'' ->> ''{P}_decided'')::int > 0\n              THEN round(100.0 * ({K} -> ''{FAM}'' ->> ''{P}_accepted'')::numeric\n                               / ({K} -> ''{FAM}'' ->> ''{P}_decided'')::numeric, 2)\n              ELSE NULL END )::text';

  t_verdict text := E'SELECT ( ({K} -> ''{FAM}'' ->> ''live_verdict'')\n         IS NOT DISTINCT FROM\n         public.g12_verdict_v3(\n           ({K} -> ''{FAM}'' ->> ''live_accepted'')::int,\n           ({K} -> ''{FAM}'' ->> ''live_decided'')::int,\n           ({K} -> ''{FAM}'' ->> ''g12_min_decided'')::int,\n           ({K} -> ''{FAM}'' ->> ''g12_bar_pct'')::numeric) )::text';

  t_counter text := E'SELECT public.g12_verdict_v3(\n         ( ({AFT} -> ''{FAM}'' ->> ''live_accepted'')::int - ({BEF} -> ''{FAM}'' ->> ''live_accepted'')::int ),\n         ( ({AFT} -> ''{FAM}'' ->> ''live_decided'')::int  - ({BEF} -> ''{FAM}'' ->> ''live_decided'')::int ),\n         ({AFT} -> ''{FAM}'' ->> ''g12_min_decided'')::int,\n         ({AFT} -> ''{FAM}'' ->> ''g12_bar_pct'')::numeric )';

  r  record;
  s  text;
BEGIN
  ---------------------------------------------------------------- seq 5 ------
  -- The one surviving absolute, and the only one that is durably true.
  UPDATE golden.assertions SET
    description = '⛔ THE ONE ABSOLUTE LEFT IN THIS FIXTURE, AND IT IS DELIBERATE (S-263). Immediately after the reclaim, NOTHING OF OURS survives from the previous run: zero rows on the 1999 sentinel in either queue. Every other population claim below is a DELTA, because DR-5 put real pre-epoch proposals in both queues and this fixture owns none of them.',
    check_sql   = 'SELECT (SELECT value FROM golden.scratch WHERE fixture_id=59 AND key=''before_sentinel'') ->> ''total''',
    expect_op   = 'eq', expect = '0'
  WHERE fixture_id=59 AND seq=5;
  IF NOT FOUND THEN RAISE EXCEPTION 'S-263: seq 5 missing'; END IF;

  ---------------------------------------------------------------- seq 6 ------
  -- DEVIATION (logged): non-vacuity partner for the STABILITY family, not a
  -- duplicate of seq 11. Guards seq 11/15/17 against being 0 = 0.
  UPDATE golden.assertions SET
    description = '⛔ NON-VACUITY PARTNER for every STABILITY assertion (seq 11/15/17): all three fixture-side populations are non-empty BEFORE the plant, so "after = before" can never be satisfied on 0 = 0 (S-48/S-52/S-55 mode).',
    check_sql   = replace(replace(
      E'SELECT LEAST( ({BEF} -> ''feedback_pins''  ->> ''fixture_rows'')::int,\n               ({BEF} -> ''picker_weights'' ->> ''fixture_rows'')::int,\n               ({BEF} -> ''rotation''       ->> ''fixture_rows'')::int )::text',
      '{BEF}', bef), '{BEF}', bef),
    expect_op   = 'gt', expect = '0'
  WHERE fixture_id=59 AND seq=6;
  IF NOT FOUND THEN RAISE EXCEPTION 'S-263: seq 6 missing'; END IF;

  --------------------------------------------------------------- seq 12 ------
  -- DEVIATION (logged): SUM IDENTITY beats the delta. A delta of 8 is also what
  -- a view that reported total_rows = live_rows would produce.
  UPDATE golden.assertions SET
    description = 'AFTER: total_rows IS the sum of both populations, never one of them - stated as an identity so it holds at any live population (a delta of 8 would also be produced by a view that reported total_rows = live_rows).',
    check_sql   = replace(replace(
      E'SELECT ( ({AFT} -> ''feedback_pins'' ->> ''total_rows'')::int\n       = ({AFT} -> ''feedback_pins'' ->> ''live_rows'')::int\n       + ({AFT} -> ''feedback_pins'' ->> ''fixture_rows'')::int )::text',
      '{AFT}', aft), '{AFT}', aft),
    expect_op   = 'eq', expect = 'true'
  WHERE fixture_id=59 AND seq=12;
  IF NOT FOUND THEN RAISE EXCEPTION 'S-263: seq 12 missing'; END IF;

  --------------------------------------------------------------- seq 33 ------
  UPDATE golden.assertions SET
    description = 'the passing family sat EXACTLY on g12_min_decided - the boundary is inclusive and was exercised, not stepped over. Restated as a DELTA: it is THIS FIXTURE''S OWN contribution to live_decided that equals g12_min_decided, whatever CS has already decided elsewhere.',
    check_sql   = replace(replace(
      E'SELECT ( ( ({AFT} -> ''feedback_pins'' ->> ''live_decided'')::int\n         - ({BEF} -> ''feedback_pins'' ->> ''live_decided'')::int )\n       = ({AFT} -> ''feedback_pins'' ->> ''g12_min_decided'')::int )::text',
      '{AFT}', aft), '{BEF}', bef),
    expect_op   = 'eq', expect = 'true'
  WHERE fixture_id=59 AND seq=33;
  IF NOT FOUND THEN RAISE EXCEPTION 'S-263: seq 33 missing'; END IF;

  ------------------------------------------------------------- the DELTAS ----
  FOR r IN SELECT * FROM (VALUES
      (10,'feedback_pins', 'live_rows',      '8', 'AFTER-BEFORE: the 8 planted pre-epoch rows land in live_rows. Delta, not absolute: the queue already holds real CS-facing proposals (DR-5).'),
      (14,'picker_weights','live_rows',      '5', 'AFTER-BEFORE: picker_weights picks up its 5 planted live rows, on top of whatever the live miner has already minted.'),
      (16,'rotation',      'live_rows',      '0', 'AFTER-BEFORE: a family nobody planted into gains ZERO live rows - families do not leak into each other. Delta, so DR-7''s first real rotation proposals (2026-08-09) cannot redden it.'),
      (18,'feedback_pins', 'live_accepted',  '4', 'approved maps to accepted: this fixture adds exactly 4 accepted.'),
      (19,'feedback_pins', 'live_rejected',  '1', 'rejected maps to rejected: this fixture adds exactly 1 rejected.'),
      (20,'feedback_pins', 'live_undecided', '2', 'pending maps to undecided: this fixture adds exactly 2 undecided.'),
      (21,'feedback_pins', 'live_withdrawn', '1', 'S-139 member-of-the-difference: superseded maps to withdrawn, NOT to rejected - this fixture adds exactly 1 withdrawn.'),
      (22,'feedback_pins', 'live_decided',   '5', 'and withdrawn is therefore EXCLUDED from the denominator: of the 8 rows this fixture adds, exactly 5 land in decided.'),
      (23,'picker_weights','live_accepted',  '1', 'S-139 member-of-the-difference: applied maps to accepted, not to a fourth state - this fixture adds exactly 1 accepted.'),
      (24,'picker_weights','live_rejected',  '4', 'picker_weights: this fixture adds exactly 4 rejected.')
    ) AS t(seq,fam,col,exp,descr)
  LOOP
    s := replace(replace(replace(replace(t_delta,'{AFT}',aft),'{BEF}',bef),'{FAM}',r.fam),'{COL}',r.col);
    UPDATE golden.assertions
       SET check_sql = s, expect_op = 'eq', expect = r.exp, description = r.descr
     WHERE fixture_id=59 AND seq=r.seq;
    IF NOT FOUND THEN RAISE EXCEPTION 'S-263: delta seq % missing', r.seq; END IF;
  END LOOP;

  ---------------------------------------------------------- the STABILITY ----
  FOR r IN SELECT * FROM (VALUES
      (11,'feedback_pins', 'fixture_rows','int','AFTER: the fixture side is UNMOVED - planting live rows must not disturb the fixture population. Stated as after = before, so other fixtures'' rows cannot redden it (non-vacuity: seq 6).'),
      (15,'picker_weights','fixture_rows','int','AFTER: picker_weights'' fixture side is likewise UNMOVED. Was pinned at 2; fixture 58''s superseded pairs grow that population on every S-262 turn (non-vacuity: seq 6).'),
      (17,'rotation',      'fixture_rows','int','AFTER: the untouched family still reports its own fixture rows, UNMOVED. Was pinned at 25 (non-vacuity: seq 6).'),
      (13,'feedback_pins', 'fixture_acceptance_pct','num','AFTER: the fixture acceptance rate is UNMOVED while the live rate is something else entirely. Its VALUE is derived by seq 8; this asserts only that planting live rows does not move it.')
    ) AS t(seq,fam,col,kind,descr)
  LOOP
    s := CASE WHEN r.kind='num' THEN t_stable_num ELSE t_stable_int END;
    s := replace(replace(replace(replace(s,'{AFT}',aft),'{BEF}',bef),'{FAM}',r.fam),'{COL}',r.col);
    UPDATE golden.assertions
       SET check_sql = s, expect_op = 'eq', expect = 'true', description = r.descr
     WHERE fixture_id=59 AND seq=r.seq;
    IF NOT FOUND THEN RAISE EXCEPTION 'S-263: stability seq % missing', r.seq; END IF;
  END LOOP;

  -------------------------------------------------------------- the FINAL ----
  FOR r IN SELECT * FROM (VALUES
      (45,'feedback_pins', 'live_rows','FINAL: the planted feedback rows are gone AND THE BASELINE IS RESTORED - final = before, which is strictly stronger than the old "= 0": it proves the cleanup removed exactly this fixture''s rows and nothing else.'),
      (46,'picker_weights','live_rows','FINAL: the planted picker_weight rows are gone AND THE BASELINE IS RESTORED - final = before, not merely zero.')
    ) AS t(seq,fam,descr)
  LOOP
    s := replace(replace(replace(replace(t_final,'{FIN}',fin),'{BEF}',bef),'{FAM}',r.fam),'{COL}','live_rows');
    UPDATE golden.assertions
       SET check_sql = s, expect_op = 'eq', expect = 'true', description = r.descr
     WHERE fixture_id=59 AND seq=r.seq;
    IF NOT FOUND THEN RAISE EXCEPTION 'S-263: final seq % missing', r.seq; END IF;
  END LOOP;

  ------------------------------------------------------------ the FORMULA ----
  FOR r IN SELECT * FROM (VALUES
      ( 8,'before','feedback_pins', 'fixture','BEFORE: the fixture-side rate a naive acceptance view would have headlined is quarantined in the fixture column AND correctly derived there: pct = round(100*accepted/decided,2). Was pinned at 75.00, which is a population fixtures 55/56/57 move.'),
      ( 9,'before','picker_weights','fixture','BEFORE: a family whose fixture rows are all undecided yields NO acceptance rate at all - NULL, never 0.00. Stated as the full formula so it survives the day fixture 58 leaves a decided row behind.'),
      (27,'after', 'feedback_pins', 'live',   'AFTER: the live acceptance rate is the decided-denominator rate, correctly rounded: pct = round(100*live_accepted/live_decided,2). With this fixture''s 4-of-5 that renders 80.00 today.'),
      (29,'after', 'picker_weights','live',   'AFTER: same formula on picker_weights - this fixture''s 1-of-5 renders 20.00 today.'),
      (32,'after', 'rotation',      'live',   'AFTER: and a family with zero decided rows renders NULL rather than 0.00 - zero of zero is not zero percent. The formula states both halves at once.')
    ) AS t(seq,k,fam,p,descr)
  LOOP
    s := replace(replace(replace(t_formula,'{K}', CASE r.k WHEN 'after' THEN aft ELSE bef END),'{FAM}',r.fam),'{P}',r.p);
    UPDATE golden.assertions
       SET check_sql = s, expect_op = 'eq', expect = 'true', description = r.descr
     WHERE fixture_id=59 AND seq=r.seq;
    IF NOT FOUND THEN RAISE EXCEPTION 'S-263: formula seq % missing', r.seq; END IF;
  END LOOP;

  ------------------------------------------------------------ the VERDICT ----
  FOR r IN SELECT * FROM (VALUES
      ( 7,'before','feedback_pins','BEFORE: the published live_verdict is exactly what g12_verdict_v3 returns for the live counts the view itself published - the view wires the helper with the right four arguments. (That no evidence renders insufficient_evidence and NEVER fail is pinned independently at seq 35.)'),
      (31,'after', 'rotation',     '⛔ THE DISTINCTION THAT PROTECTS A WORKING MINER, restated as consistency: the untouched family''s published verdict is exactly g12_verdict_v3 of its own published counts. Seq 35 pins that 0-of-0 is insufficient_evidence, so this stays true when DR-7 starts minting real rotation proposals.')
    ) AS t(seq,k,fam,descr)
  LOOP
    s := replace(replace(t_verdict,'{K}', CASE r.k WHEN 'after' THEN aft ELSE bef END),'{FAM}',r.fam);
    UPDATE golden.assertions
       SET check_sql = s, expect_op = 'eq', expect = 'true', description = r.descr
     WHERE fixture_id=59 AND seq=r.seq;
    IF NOT FOUND THEN RAISE EXCEPTION 'S-263: verdict seq % missing', r.seq; END IF;
  END LOOP;

  ----------------------------------------------------- the COUNTERFACTUALS ---
  -- seq 28/30 keep their ORIGINAL claim exactly (pass / fail), by feeding the
  -- helper this fixture's OWN contribution instead of the live totals.
  FOR r IN SELECT * FROM (VALUES
      (28,'feedback_pins', 'pass','AFTER: 4 accepted of 5 decided is 80%, which CLEARS the 60% bar - pass. Evaluated on THIS FIXTURE''S OWN delta, so a CS decision on a real proposal cannot change the verdict this fixture is asserting.'),
      (30,'picker_weights','fail','AFTER: 1 accepted of 5 decided is 20% with enough evidence to judge - a real fail, the miner IS noise on this showing. Evaluated on THIS FIXTURE''S OWN delta.')
    ) AS t(seq,fam,exp,descr)
  LOOP
    s := replace(replace(replace(t_counter,'{AFT}',aft),'{BEF}',bef),'{FAM}',r.fam);
    UPDATE golden.assertions
       SET check_sql = s, expect_op = 'eq', expect = r.exp, description = r.descr
     WHERE fixture_id=59 AND seq=r.seq;
    IF NOT FOUND THEN RAISE EXCEPTION 'S-263: counterfactual seq % missing', r.seq; END IF;
  END LOOP;

  ------------------------------------------------- CODY's REQUIRED SENSOR ----
  -- seq 54/55 are NEW (fixture 57 seq 40/41 pattern). They are the only
  -- assertions in this fixture that speak about rows it does not own, and they
  -- say the one thing that matters: it did not touch them.
  INSERT INTO golden.assertions(fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
  VALUES
    (59, 54,
     '⛔⛔ THE SAFETY SENSOR (Cody, leg 143). The real, CS-facing, pre-epoch, non-sentinel proposal population in BOTH queues is captured BEFORE the first DELETE and compared AFTER everything this fixture does. UNMOVED. This is the S-264 evidence - that a harness fixture destroyed none of the proposals CS is meant to review - stated inside the harness instead of counted by hand.',
     'SELECT ( ((SELECT value FROM golden.scratch WHERE fixture_id=59 AND key=''real_final'')  ->> ''total'')::int
        = ((SELECT value FROM golden.scratch WHERE fixture_id=59 AND key=''real_before'') ->> ''total'')::int )::text',
     'eq', 'true', true, 'P4'),
    (59, 55,
     '⛔ NON-VACUITY PARTNER for seq 54: there is a real population to protect, so seq 54 can never be satisfied by 0 = 0 (S-48/S-52/S-55 mode). Goes red the day the live queues empty, which is the correct moment to re-read seq 54.',
     'SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=59 AND key=''real_before'') ->> ''total'')',
     'gt', '0', true, 'P4')
  ON CONFLICT (fixture_id, seq) DO UPDATE
    SET description = EXCLUDED.description, check_sql = EXCLUDED.check_sql,
        expect_op = EXCLUDED.expect_op, expect = EXCLUDED.expect,
        enabled = EXCLUDED.enabled, phase_required = EXCLUDED.phase_required;
END
$mig$;

------------------------------------------------------------------------------------------
-- 3) verification — the migration refuses to land if it did not do what it says
------------------------------------------------------------------------------------------
DO $vfy$
DECLARE
  v_scen text;
  v_n    int;
BEGIN
  SELECT scenario_sql INTO v_scen FROM golden.fixtures WHERE fixture_id = 59;

  IF v_scen LIKE '%pre-epoch proposal row(s) this fixture did not create%' THEN
    RAISE EXCEPTION 'S-263 FAILED: the foreign-row RAISE is still in fixture 59''s scenario';
  END IF;
  IF v_scen NOT LIKE '%before_sentinel%' THEN
    RAISE EXCEPTION 'S-263 FAILED: before_sentinel was not captured';
  END IF;
  -- the reclaim and cleanup must be untouched (2 x 2 sentinel DELETEs)
  IF (length(v_scen) - length(replace(v_scen, 'WHERE plan_date    = d_live', ''))) / length('WHERE plan_date    = d_live') <> 2
  THEN RAISE EXCEPTION 'S-263 FAILED: expected exactly 2 feedback sentinel DELETEs (reclaim + cleanup)'; END IF;

  -- every population assertion must now read BOTH snapshots (delta/stability/final)
  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE fixture_id=59 AND seq IN (10,14,16,18,19,20,21,22,23,24,33,28,30)
     AND check_sql LIKE '%key=''before''%' AND check_sql LIKE '%key=''after''%';
  IF v_n <> 13 THEN RAISE EXCEPTION 'S-263 FAILED: only % of 13 delta-form assertions read both snapshots', v_n; END IF;

  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE fixture_id=59 AND seq IN (11,13,15,17) AND check_sql LIKE '%IS NOT DISTINCT FROM%'
     AND check_sql LIKE '%key=''before''%' AND check_sql LIKE '%key=''after''%';
  IF v_n <> 4 THEN RAISE EXCEPTION 'S-263 FAILED: only % of 4 stability assertions are after-vs-before', v_n; END IF;

  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE fixture_id=59 AND seq IN (45,46)
     AND check_sql LIKE '%key=''final''%' AND check_sql LIKE '%key=''before''%';
  IF v_n <> 2 THEN RAISE EXCEPTION 'S-263 FAILED: seq 45/46 are not final-vs-before'; END IF;

  -- ⛔ CODY's REQUIRED SENSOR: it must be CAPTURED BEFORE THE FIRST DELETE, or it
  -- proves the reclaim worked rather than that it was safe to run. Positional,
  -- because that ordering IS the whole guarantee.
  IF position('v_real_before := jsonb_build_object' in v_scen) = 0
     OR position('v_real_before := jsonb_build_object' in v_scen)
        > position('DELETE FROM public.feedback_proposals_v3' in v_scen)
  THEN RAISE EXCEPTION 'S-263 FAILED: the real-population sensor is not captured BEFORE the first reclaim DELETE'; END IF;
  IF v_scen NOT LIKE '%real_final%' THEN
    RAISE EXCEPTION 'S-263 FAILED: real_final was not captured';
  END IF;

  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE fixture_id=59 AND seq IN (54,55) AND enabled
     AND check_sql LIKE '%real_before%';
  IF v_n <> 2 THEN RAISE EXCEPTION 'S-263 FAILED: seq 54/55 (Cody safety sensor) not installed'; END IF;

  SELECT count(*) INTO v_n FROM golden.assertions WHERE fixture_id=59 AND enabled;
  IF v_n <> 55 THEN RAISE EXCEPTION 'S-263 FAILED: fixture 59 assertion count moved to % (expected 55)', v_n; END IF;

  RAISE NOTICE 'S-263: fixture 59 restated - 55 assertions, 13 deltas, 4 stability, 2 final-vs-before, safety sensor 54/55, RAISE removed';
END
$vfy$;
