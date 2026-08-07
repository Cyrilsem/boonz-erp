-- PRD-110 · DR-5 part C of 3 · leg 141
-- Cody: class (f) - golden.assertions is harness metadata, not a protected entity.
-- No DDL, no RLS, no DEFINER, no business data. Fast-path approve. Neither claim
-- below is weakened; both are asserted more precisely than before.
--
-- ⛔ S-262: FIXTURE 58 HAD TWO HIDDEN DEPENDENCIES ON LIVE PRODUCTION STATE, and
--    DR-5 is what exposed them. The fixture plants its own synthetic pick history
--    but reads the LIVE pick_urgency_params dial and the LIVE proposal table, so
--    two of its assertions were only ever true while (a) w_empty was 0.900 and
--    (b) fixture 58 was the proposal table's sole occupant. DR-5 legitimately
--    ended both conditions.
--
-- ⭐ NEITHER IS A RE-BASELINE IN THE S-103 SENSE. In both cases the DESCRIPTION
--    already stated a RELATIVE claim while the `expect` pinned an ABSOLUTE. The
--    fix makes the check say what the description always said. The idiom is
--    fixture 58's OWN (seq 24 and seq 32 are already written this way), so this
--    is following the fixture's convention, not inventing one.

DO $dr5c$
DECLARE v_rows int; v_n int;
BEGIN
  ------------------------------------------------------------------ seq 15 ---
  -- WAS: expect '0.900 -> 0.958', check = current::text || ' -> ' || proposed::text.
  -- Read '0.945 -> 1.005' after DR-5, because the miner scales the LIVE dial.
  -- The claim was never about the pair - the description says so itself: "20pct
  -- scaled by (21.43-8)/(50-8)". That formula is now asserted directly, against
  -- the live gates, and it binds current_weight, concordance_pct, the band, the
  -- max-delta and the 3dp rounding TOGETHER. Strictly more than the pair did.
  -- ⭐ The CASE on direction means it also holds for a LOWER proposal, so the
  --    same property could be pointed at w_stale without being rewritten.
  UPDATE golden.assertions
     SET expect_op = 'eq',
         expect    = 'true',
         check_sql = 'SELECT (p.proposed_weight = round(p.current_weight * (1 +'
                  || E'\n         CASE WHEN p.direction = ''raise'' THEN 1 ELSE -1 END *'
                  || E'\n         r.pl_max_weight_delta_pct * LEAST(1.0,'
                  || E'\n           (abs(p.concordance_pct - 50) - r.pl_concordance_band)'
                  || E'\n           / (50 - r.pl_concordance_band)) / 100), 3))::text'
                  || E'\n     FROM public.picker_weight_proposals_v3 p,'
                  || E'\n          (SELECT pl_max_weight_delta_pct, pl_concordance_band'
                  || E'\n             FROM public.refill_policy_params ORDER BY id LIMIT 1) r'
                  || E'\n    WHERE p.window_start = DATE ''2030-03-05'' AND p.target_param = ''w_empty''',
         description = 'w_empty''s move IS the documented scaling formula, recomputed here against '
                    || 'the live gates: max_delta_pct scaled by (|concordance-50| - band)/(50 - band), '
                    || 'applied to current_weight and rounded to 3dp. At the fixture''s 71.43% that '
                    || 'is 6.395%, which read 0.900 -> 0.958 while the dial sat at 0.900 and reads '
                    || '0.945 -> 1.005 after PRD-110 DR-5 raised it. ⛔ S-262: the old form pinned '
                    || 'the PAIR, so a legitimate CS weight change reddened it - this fixture plants '
                    || 'its own pick history but reads the LIVE dial. The property is strictly '
                    || 'stronger (it binds current_weight, concordance, band, max_delta and the '
                    || 'rounding together) and cannot rot on a ruled dial move.'
   WHERE fixture_id = 58 AND seq = 15;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN RAISE EXCEPTION 'DR-5c: seq 15 update touched % rows', v_rows; END IF;

  ------------------------------------------------------------------ seq 28 ---
  -- WAS: expect '2', check = the ABSOLUTE table count after the second run.
  -- Read 3 after DR-5, because the applied live w_empty proposal now lives in
  -- the table permanently. The description already said "UNCHANGED after the
  -- second run" - a DELTA. Both scratch keys needed are already captured by the
  -- scenario, so this needs no scenario change.
  -- ⭐ Mint coverage is NOT lost: seq 23 already asserts exactly 2 rows on this
  --    fixture's OWN window, pending, unreviewed and unapplied - window-scoped,
  --    so it is immune to production rows in a way the raw count never was.
  UPDATE golden.assertions
     SET expect_op = 'eq',
         expect    = 'true',
         check_sql = 'SELECT ((SELECT value #>> ''{}'' FROM golden.scratch'
                  || E'\n         WHERE fixture_id = 58 AND key = ''pwp_after_second'')'
                  || E'\n        = (SELECT value #>> ''{}'' FROM golden.scratch'
                  || E'\n         WHERE fixture_id = 58 AND key = ''pwp_after_main''))::text',
         description = 'the row count is unchanged after the second run - asserted as the DELTA the '
                    || 'description always claimed (after_second = after_main), in fixture 58''s own '
                    || 'seq-24/seq-32 idiom. ⛔ S-262: the old form pinned the ABSOLUTE count at 2, '
                    || 'which was only true while this fixture was the proposal table''s sole '
                    || 'occupant. PRD-110 DR-5 applied a real w_empty proposal that stays there '
                    || 'forever, so the count is now 3 and will keep growing - a harness assertion '
                    || 'must not be a hostage to production row counts.'
   WHERE fixture_id = 58 AND seq = 28;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN RAISE EXCEPTION 'DR-5c: seq 28 update touched % rows', v_rows; END IF;

  -- ⛔ Neither assertion may end up disabled or op-weakened by this edit.
  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE fixture_id = 58 AND seq IN (15, 28) AND enabled AND expect_op = 'eq' AND expect = 'true';
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'DR-5c: expected both seq 15 and 28 enabled, eq, expecting true - found %', v_n;
  END IF;
END
$dr5c$;
