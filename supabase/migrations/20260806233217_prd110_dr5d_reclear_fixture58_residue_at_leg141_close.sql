-- PRD-110 · DR-5 part D · leg 141 close
-- Cody: class (f) - no protected entity, no DDL. Same predicate, same rationale
-- as dr5a; this is the treadmill, not a new decision.
--
-- ⛔ S-262 (third part) - THE RESIDUE IS A TREADMILL, NOT A ONE-OFF. dr5a cleared
--    it; running fixture 58 twice during this same leg re-minted it, because
--    run_fixture does not roll back (S-258) and the fixture mints into the GLOBAL
--    one-pending-per-dial slot. Left as-is, the FIRST live weekly miner run
--    (Monday 2026-08-10, 05:30 Dubai) is refused 'pending_exists' on w_empty and
--    warns 'synthetic_pending_blocks_live_minting' - visible, not silent, but it
--    would make DR-5's first real run a no-op.
--    ⭐ THIS CLEARS IT AGAIN AND WILL NOT BE THE LAST TIME. Any leg that runs
--      fixture 58 (including the S7-style triple DONE-2 owes) re-dirties it and
--      MUST re-run this same predicate afterwards.
--    ⛔ THE STRUCTURAL FIX IS NOT ATTEMPTED HERE (LAW 10): scoping
--      ux_pwp_one_pending_per_param so synthetic (window_start >=
--      miner_fixture_epoch) and live proposals stop contending is a Dara+Cody
--      schema unit in its own right, and it changes a miner predicate. Parked and
--      named, not smuggled into a cleanup.

DO $dr5d$
DECLARE v_epoch date; v_moved int; v_n int;
BEGIN
  SELECT miner_fixture_epoch INTO v_epoch
    FROM public.refill_policy_params ORDER BY id LIMIT 1;

  UPDATE public.picker_weight_proposals_v3 p
     SET status      = 'superseded',
         review_note = 'PRD-110 DR-5/S-262 (leg 141 close): golden fixture 58 residue, re-minted by '
                    || 'this leg''s own fixture-58 runs. Cleared by the same predicate dr5a used '
                    || '(window_start >= miner_fixture_epoch ' || v_epoch || '), so the first live '
                    || 'weekly miner run is not refused pending_exists. Superseded, never deleted: '
                    || 'fixture 58 seq 9-15 and seq 40 read this row by window with no status '
                    || 'predicate. ⛔ Re-run this after ANY future fixture-58 run.'
   WHERE p.status = 'pending'
     AND p.window_start >= v_epoch;
  GET DIAGNOSTICS v_moved = ROW_COUNT;

  IF v_moved <> 2 THEN
    RAISE EXCEPTION 'DR-5d: expected exactly 2 re-minted synthetic residue rows, moved %', v_moved;
  END IF;

  -- ⛔ The applied live proposal must NOT have been caught by this.
  SELECT count(*) INTO v_n FROM public.picker_weight_proposals_v3
   WHERE status = 'applied' AND target_param = 'w_empty' AND applied_weight = 0.945;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'DR-5d: the applied DR-5 proposal is no longer intact (found %)', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM public.picker_weight_proposals_v3 WHERE status = 'pending';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'DR-5d: % pending proposal(s) remain', v_n;
  END IF;
END
$dr5d$;
