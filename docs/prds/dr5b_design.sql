-- =============================================================================
-- PRD-110 · DR-5 part B of 2 · leg 141
-- "Apply the ruled w_empty weight and close the proposal that carries it."
--
-- CS RULING (PARKING-LOT, 2026-08-04): "DR-5 CLOSED: ACCEPT the w_empty
-- 0.900->0.945 proposal AND set both miner dry-run flags false."
--
-- RUN ORDER: dr5a  ->  run_weekly_miners_v3('manual')  ->  THIS FILE.
-- The proposal this closes was minted by the PRODUCTION path (the same RPC the
-- Sunday cron calls, reading the dials dr5a flipped), not hand-written here.
--
-- ⛔ THE 0.945 / 0.948 DIVERGENCE, STATED RATHER THAN SMOOTHED.
--    CS ruled 0.900 -> 0.945.  Re-mined live at execution time on the real
--    90-day window the number is 0.948 (69.31 % concordance, 1363 evaluable /
--    492 discriminating pairs, 25 learnable days) - the ruling's own figures
--    (68.57 %, 1318/474, 24 days -> 0.945) matured by one day of data.  Same
--    decision, same direction, same lead feature (empty_shelves_count); only the
--    magnitude moved by 0.003.
--    ⭐ THE RULED NUMBER IS WHAT SHIPS.  Applying 0.948 would mean the loop
--    re-derived a ruled magnitude at execution time and applied a number CS
--    never saw - the same class of drift S-261 caught, only with real data
--    instead of synthetic.  applied_weight exists as a column distinct from
--    proposed_weight precisely so this can be recorded rather than hidden:
--    proposed 0.948, applied 0.945, both readable, difference explained in the
--    review_note.
--
-- ⛔ FIXTURE 58 seq 33 IS RE-BASELINED IN THIS SAME TRANSACTION, for the DR-4
--    reason (leg 132): it pins max(pick_urgency_params.updated_at) to an
--    absolute timestamp, and this migration moves that timestamp.  Flipping
--    without it leaves golden red between two migrations.
--    ⭐ seq 33 is NOT weakened and NOT made redundant: seq 32 already proves the
--      miner leaves pick_urgency_params byte-unchanged ACROSS a run (pup_before =
--      pup_after, from the fixture's own scratch).  seq 33's separate job is to
--      pin the absolute last-write, so that ANY unattributed write to the picker
--      weights - by anything, at any time, inside a run or not - reddens it.
--      That brittleness IS the sensor.  Re-baselined per S-103: expect AND
--      description together, computed from the row this migration just wrote
--      rather than typed in.
--
-- ⭐ NEW: fixture 58 seq 43 is the standing DR-5 TELL, in the D-46 idiom (the
--    binder's 45ec06ab md5).  A ruled value with no sensor is a value nobody
--    notices reverting.  seq 43 reads w_empty itself and expects 0.945.
--    ⚠️ This CHANGES THE FIXTURE POPULATION (2150 -> 2151 enabled assertions),
--    which DONE-2 already prices in as an S7-style triple.
--
-- ⛔ WHAT THIS DOES NOT DO: it does not touch any other picker weight, does not
--    change any engine, view, cron or RPC, and writes no protected entity and no
--    live plan table (LAW 12).  Article 4: the CS ruling is quoted, not
--    paraphrased.  Article 8: both the params row and the proposal row carry an
--    identified actor (CS's own operator_admin id, whose ruling this is).
-- =============================================================================

DO $dr5b$
DECLARE
  c_ruled_weight  numeric := 0.945;   -- ⛔ the CS-ruled magnitude, not a re-derivation
  c_cs_uid        uuid    := '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d';  -- operator_admin, Cyril Semaan
  v_epoch         date;
  v_params_id     int;
  v_n             int;
  v_prop_id       uuid;
  v_proposed      numeric;
  v_current       numeric;
  v_conc          numeric;
  v_pairs         int;
  v_days          int;
  v_lead          text;
  v_dir           text;
  v_ws            date;
  v_we            date;
  v_before        numeric;
  v_after         numeric;
  v_new_stamp     text;
  v_rows          int;
BEGIN
  SELECT r.id, r.miner_fixture_epoch INTO v_params_id, v_epoch
    FROM public.refill_policy_params r ORDER BY r.id LIMIT 1;

  -- ⛔ dr5a must have run: the dials are the precondition, not a nice-to-have.
  --    A pending proposal minted while the dials were still true would mean
  --    somebody bypassed run_weekly_miners_v3.
  PERFORM 1 FROM public.refill_policy_params
   WHERE id = v_params_id
     AND miner_weekly_pick_dry_run = false
     AND miner_weekly_edit_dry_run = false;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DR-5b: the miner dry-run dials are not both false - run dr5a first';
  END IF;

  ------------------------------------------- the proposal, BY PREDICATE ------
  -- ⛔ Never by proposal_id: the id did not exist when this file was written,
  --    and a hand-copied uuid cannot be re-run or re-read.  The predicate is
  --    "pending, on w_empty, on a REAL (pre-epoch) window" - which is exactly
  --    "the one the production miner just minted", and excludes by construction
  --    any synthetic row a golden sweep may re-mint before this runs.
  SELECT count(*) INTO v_n
    FROM public.picker_weight_proposals_v3
   WHERE status = 'pending' AND target_param = 'w_empty' AND window_start < v_epoch;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'DR-5b: expected exactly 1 pending live-window w_empty proposal to accept, found % - refusing to guess which one CS ruled on', v_n;
  END IF;

  SELECT p.proposal_id, p.current_weight, p.proposed_weight, p.concordance_pct,
         p.pairs, p.days_covered, p.lead_feature, p.direction, p.window_start, p.window_end
    INTO v_prop_id, v_current, v_proposed, v_conc, v_pairs, v_days, v_lead, v_dir, v_ws, v_we
    FROM public.picker_weight_proposals_v3 p
   WHERE p.status = 'pending' AND p.target_param = 'w_empty' AND p.window_start < v_epoch
   FOR UPDATE;

  -- ⛔ The ruling is a RAISE from 0.900.  If the proposal disagrees about either
  --    the base or the direction, it is not the decision CS made.
  IF v_current <> 0.900 THEN
    RAISE EXCEPTION 'DR-5b: proposal reads current_weight % but CS ruled on a move FROM 0.900 - the dial moved since the ruling', v_current;
  END IF;
  IF v_dir <> 'raise' THEN
    RAISE EXCEPTION 'DR-5b: proposal direction is %, CS ruled a raise', v_dir;
  END IF;
  IF v_lead <> 'empty_shelves_count' THEN
    RAISE EXCEPTION 'DR-5b: proposal lead_feature is %, the ruled proposal was led by empty_shelves_count', v_lead;
  END IF;
  -- ⛔ The ruled magnitude must sit between the base and what the evidence
  --    currently supports.  Applying MORE than the live evidence proposes would
  --    be over-applying a ruling; applying less than the base is not a raise.
  IF NOT (c_ruled_weight > v_current AND c_ruled_weight <= v_proposed) THEN
    RAISE EXCEPTION 'DR-5b: ruled weight % is not within (current %, proposed %] - the live evidence no longer supports the ruled magnitude; take this back to CS rather than applying it',
      c_ruled_weight, v_current, v_proposed;
  END IF;

  ------------------------------------------------------------ apply ----------
  SELECT w_empty INTO v_before FROM public.pick_urgency_params WHERE id = 1;
  IF v_before <> 0.900 THEN
    RAISE EXCEPTION 'DR-5b: pick_urgency_params.w_empty reads % , expected the ruled base 0.900', v_before;
  END IF;

  UPDATE public.pick_urgency_params
     SET w_empty    = c_ruled_weight,
         updated_at = now(),
         updated_by = c_cs_uid
   WHERE id = 1;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'DR-5b: weight application touched % rows, expected exactly 1', v_rows;
  END IF;

  SELECT w_empty INTO v_after FROM public.pick_urgency_params WHERE id = 1;
  IF v_after <> c_ruled_weight THEN
    RAISE EXCEPTION 'DR-5b: read-back says w_empty is % after the write, expected %', v_after, c_ruled_weight;
  END IF;

  -- ⛔ NOTHING ELSE ON THE DIAL ROW MOVED.  w_stale is the one to watch: the
  --    residue superseded in dr5a carried a w_stale proposal too, and the live
  --    miner refuses w_stale outright (below_concordance_band, 51.76 %).
  PERFORM 1 FROM public.pick_urgency_params
   WHERE id = 1 AND w_stale = 0.13 AND w_runout = 0.35 AND w_expiry = 0.12
     AND w_lowfill = 0.5 AND w_capacity = 0.10 AND w_holes = 0.30;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DR-5b: a picker weight other than w_empty moved - DR-5 authorises exactly one dial';
  END IF;

  ------------------------------------------------- close the proposal --------
  UPDATE public.picker_weight_proposals_v3
     SET status         = 'applied',
         applied_at     = now(),
         applied_weight = c_ruled_weight,
         reviewed_by    = c_cs_uid,
         reviewed_at    = now(),
         review_note    = 'PRD-110 DR-5 EXECUTED (leg 141), per the CS ruling of 2026-08-04: '
                       || '"ACCEPT the w_empty 0.900->0.945 proposal AND set both miner dry-run '
                       || 'flags false." APPLIED ' || v_current || ' -> ' || c_ruled_weight
                       || ', which is the RULED magnitude. This proposal, re-mined live on '
                       || v_ws || '..' || v_we || ' (' || v_conc || '% concordance, ' || v_pairs
                       || ' evaluable pairs, ' || v_days || ' learnable days, led by ' || v_lead
                       || '), proposes ' || v_proposed || ' - the ruling''s own window matured by '
                       || 'a day. The 0.003 difference is deliberate and is NOT a haircut: the '
                       || 'loop applies what CS ruled, never a magnitude re-derived at execution '
                       || 'time (S-261). If CS wants the live figure instead, that is a one-line '
                       || 'follow-up, not a silent correction.'
   WHERE proposal_id = v_prop_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'DR-5b: closing the proposal touched % rows, expected exactly 1', v_rows;
  END IF;

  -- ⛔ The one-pending-per-dial slot must be free again, or the next weekly run
  --    is refused pending_exists and DR-5 has bought nothing.
  SELECT count(*) INTO v_n FROM public.picker_weight_proposals_v3 WHERE status = 'pending';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'DR-5b: % pending proposal(s) remain after closing the accepted one', v_n;
  END IF;

  ------------------------------------------- fixture 58 seq 33 re-baseline ---
  -- Computed from the row just written, never typed in.
  -- ⛔ CODY REVISION (leg 141): seq 33 previously rendered the stamp as
  --    `max(updated_at)::text`, which goes through the SESSION TimeZone. The old
  --    baseline read '...+00' only because the migration session and the harness
  --    session both happen to run UTC - a coincidence, not a guarantee, and
  --    exactly the S-260 class ("never assert a server-rendered value by an
  --    intuited literal"). The rendering is now pinned to UTC explicitly, and
  --    `expect` is computed by the IDENTICAL expression the assertion runs, so
  --    the two cannot drift apart by construction.
  SELECT to_char(max(updated_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US "UTC"')
    INTO v_new_stamp FROM public.pick_urgency_params;

  UPDATE golden.assertions
     SET expect      = v_new_stamp,
         check_sql   = 'SELECT to_char(max(updated_at) AT TIME ZONE ''UTC'', ''YYYY-MM-DD HH24:MI:SS.US "UTC"'')'
                    || E'\n     FROM public.pick_urgency_params',
         description = 'S-138(a) - and it still sits at the weights CS last set: '
                    || 'w_empty 0.900 -> 0.945 on ' || left(v_new_stamp, 10)
                    || ', the PRD-110 DR-5 application of the pick miner''s own proposal '
                    || '(ruling of 2026-08-04). ⛔ Re-baselined per S-103, expect AND '
                    || 'description together, and NOT weakened: seq 32 proves the miner leaves '
                    || 'these weights byte-unchanged across a run, while this pins the absolute '
                    || 'last write so that ANY unattributed touch of the picker weights - by '
                    || 'anything, at any time - reddens it. The brittleness is the sensor. '
                    || '⚠️ The stamp is rendered AT TIME ZONE ''UTC'' on purpose: ::text would '
                    || 'render through the session TimeZone and rot the day a session is not UTC.'
   WHERE fixture_id = 58 AND seq = 33;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'DR-5b: fixture 58 seq 33 re-baseline touched % rows, expected 1', v_rows;
  END IF;

  ---------------------------------------------- the standing DR-5 tell -------
  INSERT INTO golden.assertions
    (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
  VALUES
    (58, 43,
     '⭐ THE DR-5 TELL (leg 141). w_empty carries the value CS ruled on 2026-08-04 and this '
     || 'migration applied: 0.945, up from 0.900, on the pick miner''s evidence '
     || '(empty_shelves_count, ~69% concordance over a real 90-day window). ⛔ If this ever '
     || 'reads 0.900 again, DR-5 has been reverted; if it reads anything else, a picker weight '
     || 'was changed outside a ruling. Same idiom as D-46''s bind_dispatch_fefo md5 tell.',
     'SELECT w_empty::text FROM public.pick_urgency_params ORDER BY id LIMIT 1',
     'eq', '0.945', true,
     (SELECT phase_required FROM golden.assertions WHERE fixture_id = 58 AND seq = 33));

  RAISE NOTICE 'DR-5b: w_empty % -> % (ruled); proposal % closed as applied; fixture 58 seq 33 re-baselined to %, seq 43 minted',
    v_before, v_after, v_prop_id, v_new_stamp;
END
$dr5b$;

-- ⛔ Independent read-back, outside the DO block, so a mistake inside it cannot
--    also write its own all-clear.
DO $dr5b_verify$
DECLARE
  v_w numeric; v_n_applied int; v_n_pending int; v_n_43 int; v_expect text; v_stamp text;
BEGIN
  SELECT w_empty INTO v_w FROM public.pick_urgency_params ORDER BY id LIMIT 1;
  IF v_w <> 0.945 THEN RAISE EXCEPTION 'DR-5b verify: w_empty is %', v_w; END IF;

  SELECT count(*) INTO v_n_applied FROM public.picker_weight_proposals_v3
   WHERE status = 'applied' AND target_param = 'w_empty' AND applied_weight = 0.945;
  IF v_n_applied <> 1 THEN RAISE EXCEPTION 'DR-5b verify: % applied w_empty proposal(s)', v_n_applied; END IF;

  SELECT count(*) INTO v_n_pending FROM public.picker_weight_proposals_v3 WHERE status = 'pending';
  IF v_n_pending <> 0 THEN RAISE EXCEPTION 'DR-5b verify: % pending proposal(s) remain', v_n_pending; END IF;

  SELECT count(*) INTO v_n_43 FROM golden.assertions WHERE fixture_id = 58 AND seq = 43 AND enabled;
  IF v_n_43 <> 1 THEN RAISE EXCEPTION 'DR-5b verify: the DR-5 tell did not land'; END IF;

  SELECT a.expect INTO v_expect FROM golden.assertions a WHERE a.fixture_id = 58 AND a.seq = 33;
  SELECT to_char(max(updated_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US "UTC"')
    INTO v_stamp FROM public.pick_urgency_params;
  IF v_expect IS DISTINCT FROM v_stamp THEN
    RAISE EXCEPTION 'DR-5b verify: fixture 58 seq 33 expects % but the table reads %', v_expect, v_stamp;
  END IF;
END
$dr5b_verify$;
