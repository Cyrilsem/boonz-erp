-- =============================================================================
-- PRD-110 · DR-5 part A of 2 · leg 141
-- "Clear the synthetic residue, then flip both miner dry-run dials."
--
-- CS RULING (PARKING-LOT, 2026-08-04): "DR-5 CLOSED: ACCEPT the w_empty
-- 0.900->0.945 proposal AND set both miner dry-run flags false. Proposals remain
-- human-review-gated."
--
-- WHY TWO MIGRATIONS.  Part A frees the global one-pending-per-dial slot and
-- arms the miners.  Between A and B the pick miner is invoked ONCE, manually,
-- through run_weekly_miners_v3 - so the proposal that gets applied is one the
-- production path actually minted, not one this migration hand-wrote.  Part B
-- then applies the ruled weight and closes the proposal.
--
-- S-261 (leg 140) IS THE REASON THIS IS NOT A ONE-LINER.  The two rows sitting
-- `pending` in picker_weight_proposals_v3 are NOT the proposal CS ruled on.
-- They carry window 2030-03-05..2030-03-14 - the synthetic universe - and were
-- minted by golden fixture 58 during leg 140's own sweep, because run_fixture
-- does not roll back.  Accepting "what is there" would apply 0.958 derived from
-- a 10-day / 150-pair synthetic window and call it the CS decision.
--
-- ⛔ CLEARED BY STATUS, NEVER BY DELETE.  Fixture 58 seq 9-15 and seq 40 read
--    these rows BY WINDOW with no status predicate; deleting them would redden
--    seven green assertions.  'superseded' is in the CHECK domain, and
--    pwp_reviewed_shape only demands a reviewer for approved/rejected - so a
--    superseded row honestly carries no human reviewer, because none reviewed it.
--
-- ⛔ SELECTED BY PREDICATE, NEVER BY proposal_id.  The predicate is the SAME one
--    run_weekly_miners_v3 already uses to raise its
--    'synthetic_pending_blocks_live_minting' warning: window_start >=
--    refill_policy_params.miner_fixture_epoch (2030-01-01).  A proposal_id list
--    would rot the next time a sweep re-mints.
--
-- ⛔ FIXTURE 60 seq 12 AND seq 13 ARE RE-BASELINED IN THIS SAME TRANSACTION.
--    They are the ONLY two assertions in the whole harness that read these dials
--    (established by predicate over golden.assertions.check_sql, not by memory).
--    Flipping alone would leave golden red between two migrations - the DR-4
--    precedent from leg 132.  Their own descriptions pre-authorise exactly this:
--    "The day CS legitimately flips miner_weekly_pick_dry_run this goes RED -
--    that is the assertion working.  Re-baseline expect AND description together
--    (S-103); never weaken to not_null."  Neither is weakened: both keep
--    expect_op 'eq' on a boolean literal, and both keep guarding an unattributed
--    move of the same dial - now in the other direction.
--
-- ⭐ FIXTURE 60 DOES NOT START MINTING LIVE because of this flip.  Its scenario
--    calls run_weekly_miners_v3('fixture', true, true) with EXPLICIT overrides,
--    and says why in its own comment.  Verified by reading scenario_sql, not
--    assumed from the dial.
--
-- Article touchpoints: 4 (a parked CS decision is being executed, with the
-- ruling quoted), 8 (every mutation names itself in a review_note or a log line),
-- 12 (no protected entity is written; refill_policy_params and
-- picker_weight_proposals_v3 are policy/proposal tables - the DR-4 precedent).
-- NO live plan table is touched (LAW 12).  No engine, view, RPC or cron changes.
-- =============================================================================

DO $dr5a$
DECLARE
  v_epoch       date;
  v_pick_before boolean;
  v_edit_before boolean;
  v_params_id   int;
  v_moved       int;
  v_still_pend  int;
  v_touched_live int;
  v_rows        int;
BEGIN
  SELECT r.id, r.miner_fixture_epoch,
         r.miner_weekly_pick_dry_run, r.miner_weekly_edit_dry_run
    INTO v_params_id, v_epoch, v_pick_before, v_edit_before
    FROM public.refill_policy_params r
   ORDER BY r.id          -- ⛔ one row by convention, not by structure (S-138)
   LIMIT 1;

  IF v_epoch IS NULL THEN
    RAISE EXCEPTION 'DR-5a: refill_policy_params.miner_fixture_epoch is NULL - refusing to classify synthetic residue by a boundary that does not exist';
  END IF;

  -- ⛔ The pre-state is asserted, not assumed.  If either dial is already false
  --    this migration has already run, or something flipped it unattributed;
  --    either way the fixture-60 re-baseline below would be writing over a
  --    baseline it did not establish.
  IF v_pick_before IS DISTINCT FROM true OR v_edit_before IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'DR-5a: expected BOTH miner dry-run dials true before the ruled flip, found pick=% edit=% - refusing to re-baseline fixture 60 against a state I did not verify',
      v_pick_before, v_edit_before;
  END IF;

  ---------------------------------------------------------------- residue ----
  UPDATE public.picker_weight_proposals_v3 p
     SET status      = 'superseded',
         review_note = 'PRD-110 DR-5 (leg 141): golden fixture 58 residue, not a live proposal. '
                    || 'window ' || p.window_start || '..' || p.window_end
                    || ' lies at/after refill_policy_params.miner_fixture_epoch ('
                    || v_epoch || '), i.e. the synthetic universe. run_fixture does not roll '
                    || 'back (S-258), so every golden sweep re-mints these into the GLOBAL '
                    || 'one-pending-per-dial slot and the live miner is refused pending_exists '
                    || '(S-261). Superseded rather than deleted: fixture 58 seq 9-15 and seq 40 '
                    || 'read this row by window with no status predicate and must keep finding it.'
   WHERE p.status = 'pending'
     AND p.window_start >= v_epoch;
  GET DIAGNOSTICS v_moved = ROW_COUNT;

  -- ⛔ NON-VACUITY.  S-261 measured the table's ENTIRE contents as exactly two
  --    pending synthetic rows (w_empty and w_stale).  A zero here would mean the
  --    residue is gone and the premise of this migration is stale; anything else
  --    means the population moved under me.  Either way, stop.
  IF v_moved <> 2 THEN
    RAISE EXCEPTION 'DR-5a: expected to supersede exactly the 2 synthetic residue rows S-261 measured, moved % - the proposal population changed since the probe; re-measure before executing',
      v_moved;
  END IF;

  -- ⛔ ...and nothing on a REAL window was collateral damage.
  SELECT count(*) INTO v_touched_live
    FROM public.picker_weight_proposals_v3
   WHERE status = 'superseded' AND window_start < v_epoch;
  IF v_touched_live <> 0 THEN
    RAISE EXCEPTION 'DR-5a: % superseded proposal(s) carry a REAL (pre-epoch) window - the residue predicate caught a live proposal',
      v_touched_live;
  END IF;

  -- ⛔ The point of the exercise: the slot is actually free now.  Without this
  --    the flip below would be a no-op that looks like a decision - the exact
  --    trap the CS ruling names.
  SELECT count(*) INTO v_still_pend
    FROM public.picker_weight_proposals_v3 WHERE status = 'pending';
  IF v_still_pend <> 0 THEN
    RAISE EXCEPTION 'DR-5a: % pending picker weight proposal(s) remain - the live miner would still be refused pending_exists',
      v_still_pend;
  END IF;

  ------------------------------------------------------------- the ruling ----
  UPDATE public.refill_policy_params
     SET miner_weekly_pick_dry_run = false,
         miner_weekly_edit_dry_run = false
   WHERE id = v_params_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'DR-5a: dial flip touched % param rows, expected exactly 1', v_rows;
  END IF;

  RAISE NOTICE 'DR-5a: superseded % synthetic residue row(s); miner dials pick %->false edit %->false',
    v_moved, v_pick_before, v_edit_before;
END
$dr5a$;

-- ---------------------------------------------------------------------------
-- Fixture 60 seq 12 - the pick dial sensor, re-baselined per its own contract.
-- ---------------------------------------------------------------------------
UPDATE golden.assertions
   SET expect      = 'false',
       description = '⭐ DR-5 EXECUTED (leg 141): the pick miner mints LIVE. '
                  || 'miner_weekly_pick_dry_run was flipped true->false under the CS ruling of '
                  || '2026-08-04 ("set both miner dry-run flags false"), after the fixture-58 '
                  || 'synthetic residue was superseded so the flip was not a no-op (S-261). '
                  || '⛔ This sensor now guards the REVERSE move: if it ever reads true again, '
                  || 'DR-5 has been reverted without a ruling. Re-baseline expect AND '
                  || 'description together (S-103); never weaken to not_null.'
 WHERE fixture_id = 60 AND seq = 12;

UPDATE golden.assertions
   SET expect      = 'false',
       description = '⭐ DR-5 EXECUTED (leg 141): the edit miner mints LIVE. '
                  || 'miner_weekly_edit_dry_run was flipped true->false in the same ruled unit '
                  || 'as seq 12. A dry re-mine measured 9 proposals it would create, and they '
                  || 'stay human-review-gated in feedback_proposals_v3 - minting is not applying. '
                  || '⛔ Same contract as seq 12: this now guards the reverse move.'
 WHERE fixture_id = 60 AND seq = 13;

-- ⛔ Prove the re-baseline landed on exactly two rows and that both now agree
--    with the database.  An assertion silently not updated is how a "green"
--    harness stops measuring.
DO $dr5a_verify$
DECLARE
  v_n int;
  v_pick text; v_edit text;
BEGIN
  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE fixture_id = 60 AND seq IN (12, 13) AND expect = 'false' AND enabled;
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'DR-5a: expected fixture 60 seq 12 and 13 both re-baselined to false and enabled, found %', v_n;
  END IF;

  SELECT miner_weekly_pick_dry_run::text, miner_weekly_edit_dry_run::text
    INTO v_pick, v_edit FROM public.refill_policy_params ORDER BY id LIMIT 1;
  IF v_pick <> 'false' OR v_edit <> 'false' THEN
    RAISE EXCEPTION 'DR-5a: dials read pick=% edit=% after the flip', v_pick, v_edit;
  END IF;
END
$dr5a_verify$;
