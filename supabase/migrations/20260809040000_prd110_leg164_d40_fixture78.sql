-- PRD-110 · leg 164 · D-40 · FIXTURE 78 (red baseline)
--
-- CS ruling D-40 (2026-08-01): "ADD THE w_intents DIAL as its own Dara/Cody-reviewed unit,
-- with a monotonicity probe proving dial-controls-feature before the miner may map to it."
--
-- LAW 1: this lands BEFORE the dial. Every sensor below is written to work on BOTH sides of
-- the change - the column is read through to_jsonb, the view through pg_get_viewdef, and every
-- write is inside a rolled-back subtransaction whose SQLSTATE is captured. A scenario that
-- throws would make the assertions lie green off the previous snapshot, so it must not throw.

DELETE FROM golden.assertions WHERE fixture_id = 78;
DELETE FROM golden.fixtures   WHERE fixture_id = 78;

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes, enabled, baseline_status)
VALUES (
  78,
  'D-40: the second-strongest signal CS gives the picker finally has a dial. w_intents ships at 0 so the live score is byte-identical, s_intents is an urgency term that is HIGH when few intents are open (matching the measured inverse direction) and can never be NULL at any column value - because 0 * NULL is NULL and would take p_score down fleet-wide. The dial-controls-feature probe and the dial-controls-score probe both run inside rolled-back subtransactions, and the map row stays INACTIVE by name: a multiplicative miner cannot move a dial that starts at zero.',
  'D-40 (leg 86 finding, CS ruling 2026-08-01). active_intent_count: 38.2% concordance over 1653 same-day pairs = 61.8% INVERSE (CS drops machines carrying more open intents). Second-strongest signal in the feature set, refused for want of a dial.',
  'P4',
  DATE '2030-03-20',
$scen$
DO $do$
DECLARE
  ---- premise --------------------------------------------------------------
  v_cols           int  := -1;
  v_checks         int  := -1;
  v_w              text := 'absent';
  v_norm           text := 'absent';
  v_fleet_n        int  := -1;
  v_levels         int  := -1;
  v_intent_max     text := 'absent';

  ---- structure ------------------------------------------------------------
  v_def            text := '';
  v_sites_runout   int  := -1;
  v_sites_intents  int  := -1;
  v_sites_equal    text := 'absent';
  v_out_col        int  := -1;

  ---- dial controls FEATURE ------------------------------------------------
  v_corr_feature   text := 'absent';
  v_s_min          text := 'absent';
  v_s_max          text := 'absent';
  v_null_s         int  := -1;
  v_null_score     int  := -1;
  v_null_urgency   int  := -1;
  v_neg_s          int  := -1;

  ---- dial controls SCORE (rolled back) ------------------------------------
  v_probe_err      text := '';
  v_probe_state    text := 'absent';
  v_n_decreased    int  := -1;
  v_n_increased    int  := -1;
  v_n_offby        int  := -1;
  v_corr_dial      text := 'absent';
  v_n_tier_up      int  := -1;
  v_inert0_diff    int  := -1;

  ---- constraint guards (rolled back) --------------------------------------
  v_norm_zero      text := 'absent';
  v_w_negative     text := 'absent';

  ---- the map row ----------------------------------------------------------
  v_map_target     text := 'absent';
  v_map_sterm      text := 'absent';
  v_map_rewards    text := 'absent';
  v_map_active     text := 'absent';
  v_map_mono       text := 'absent';
  v_map_mono_ok    text := 'absent';
  v_map_note_zero  text := 'absent';
  v_dial_reachable text := 'absent';
  v_zero_frozen    text := 'absent';

  ---- residue --------------------------------------------------------------
  v_ua_before      text := 'absent';
  v_ua_after       text := 'absent';
  v_rpo_before     int  := -1;
  v_rpo_after      int  := -1;
  v_w_after        text := 'absent';
  v_norm_after     text := 'absent';
  v_w_empty        text := 'absent';
  v_law4_clusters  int  := -1;

  c_w  numeric := 0.25;
  v_st text;
BEGIN
  DELETE FROM golden.scratch WHERE fixture_id = 78;

  ------------------------------------------------------------------ 0. PREMISE --
  -- Read through to_jsonb, never as a bare column: this scenario has to survive the
  -- run where the dial does not exist yet, and that run is the whole point of LAW 1.
  SELECT count(*)::int INTO v_cols
    FROM information_schema.columns
   WHERE table_schema='public' AND table_name='pick_urgency_params'
     AND column_name IN ('w_intents','intents_norm');

  SELECT count(*)::int INTO v_checks
    FROM pg_constraint
   WHERE conrelid='public.pick_urgency_params'::regclass AND contype='c'
     AND conname IN ('pick_urgency_params_w_intents_check','pick_urgency_params_intents_norm_check');

  SELECT COALESCE(to_jsonb(p)->>'w_intents','absent'),
         COALESCE(to_jsonb(p)->>'intents_norm','absent'),
         COALESCE(to_jsonb(p)->>'w_empty','absent'),
         to_char(p.updated_at AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI:SS.US')
    INTO v_w, v_norm, v_w_empty, v_ua_before
    FROM public.pick_urgency_params p ORDER BY p.id LIMIT 1;

  -- ⛔ PREMISE, not decoration: with a single level the correlation below is NULL and
  --    every monotonicity claim in this fixture is vacuous (S-289). It must fail loudly.
  SELECT count(*)::int, count(DISTINCT s.active_intent_count)::int, max(s.active_intent_count)::text
    INTO v_fleet_n, v_levels, v_intent_max
    FROM public.v_machine_health_signals s;

  SELECT count(*)::int INTO v_rpo_before FROM public.refill_plan_output;

  --------------------------------------------------------------- 1. STRUCTURE --
  v_def := pg_get_viewdef('public.v_machine_priority'::regclass, true);

  v_sites_runout  := (length(v_def) - length(replace(v_def, 'p.w_runout * ms.s_runout', '')))
                     / length('p.w_runout * ms.s_runout');
  v_sites_intents := (length(v_def) - length(replace(v_def, 'p.w_intents * ms.s_intents', '')))
                     / length('p.w_intents * ms.s_intents');

  -- ⭐ The guard is an EQUALITY against a sibling term, never the literal 5. The parking lot
  --    said the weighted sum occurs SIX times; pg_get_viewdef says five. A hard-coded count
  --    would pass a view that later gains a sixth site without the new term - which is the
  --    exact failure this guard exists to catch (S-299: an enumeration is a claim).
  v_sites_equal := CASE WHEN v_sites_intents = v_sites_runout AND v_sites_runout > 0
                        THEN 'yes' ELSE 'no' END;

  SELECT count(*)::int INTO v_out_col
    FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_machine_priority' AND column_name='s_intents';

  ------------------------------------------------- 2. THE TERM, ON THE LIVE FLEET --
  CREATE TEMP TABLE _base ON COMMIT DROP AS
    SELECT v.machine_id,
           v.p_score,
           v.urgency,
           v.p_tier,
           (to_jsonb(v)->>'s_intents')::numeric AS s_intents,
           h.active_intent_count
      FROM public.v_machine_priority v
      JOIN public.v_machine_health_signals h ON h.machine_id = v.machine_id;

  SELECT count(*) FILTER (WHERE s_intents IS NULL),
         count(*) FILTER (WHERE p_score IS NULL),
         count(*) FILTER (WHERE urgency IS NULL),
         count(*) FILTER (WHERE s_intents < 0),
         COALESCE(min(s_intents)::text,'absent'),
         COALESCE(max(s_intents)::text,'absent'),
         COALESCE(to_char(corr(s_intents, active_intent_count::numeric),'FM0.000'),'absent')
    INTO v_null_s, v_null_score, v_null_urgency, v_neg_s, v_s_min, v_s_max, v_corr_feature
    FROM _base;

  ------------------------------------- 3. DIAL CONTROLS SCORE (rolled back) --
  -- ⛔ Every number is taken into a VARIABLE inside the subtransaction. Rows written here
  --    would be discarded by the very rollback they measure (fixture 73's lesson).
  BEGIN
    EXECUTE format('UPDATE public.pick_urgency_params SET w_intents = %s WHERE id = 1', c_w);

    SELECT count(*) FILTER (WHERE cur.p_score < b.p_score),
           count(*) FILTER (WHERE cur.p_score > b.p_score),
           count(*) FILTER (WHERE abs(cur.p_score - (b.p_score + c_w * b.s_intents)) > 0.02),
           COALESCE(to_char(corr(cur.p_score - b.p_score, b.s_intents),'FM0.000'),'absent'),
           count(*) FILTER (WHERE cur.p_tier <> b.p_tier)
      INTO v_n_decreased, v_n_increased, v_n_offby, v_corr_dial, v_n_tier_up
      FROM public.v_machine_priority cur JOIN _base b ON b.machine_id = cur.machine_id;

    -- and back to 0: the score set must return to the byte it came from. This is the
    -- inertness proof stated as a round trip rather than as a claim about the past.
    EXECUTE 'UPDATE public.pick_urgency_params SET w_intents = 0 WHERE id = 1';
    SELECT count(*)::int INTO v_inert0_diff
      FROM public.v_machine_priority cur JOIN _base b ON b.machine_id = cur.machine_id
     WHERE cur.p_score IS DISTINCT FROM b.p_score
        OR cur.urgency IS DISTINCT FROM b.urgency
        OR cur.p_tier  IS DISTINCT FROM b.p_tier;

    RAISE EXCEPTION 'D40_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'D40_ROLLBACK' THEN
      v_probe_err := SQLERRM; v_probe_state := SQLSTATE;
    ELSE
      v_probe_state := 'rolled_back';
    END IF;
  END;

  ------------------------------------------ 4. THE CONSTRAINTS ACTUALLY REFUSE --
  -- SQLSTATE is captured, not just "it errored": 23514 means the CHECK refused, 42703
  -- means the column is not there yet. Collapsing the two would let the red baseline
  -- masquerade as a passing guard.
  BEGIN
    EXECUTE 'UPDATE public.pick_urgency_params SET intents_norm = 0 WHERE id = 1';
    v_norm_zero := 'accepted';
    RAISE EXCEPTION 'D40_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'D40_ROLLBACK' THEN NULL;
    ELSE
      v_st := SQLSTATE;
      v_norm_zero := CASE WHEN v_st='23514' THEN 'refused'
                          WHEN v_st='42703' THEN 'no_column'
                          ELSE 'other:'||v_st END;
    END IF;
  END;

  BEGIN
    EXECUTE 'UPDATE public.pick_urgency_params SET w_intents = -1 WHERE id = 1';
    v_w_negative := 'accepted';
    RAISE EXCEPTION 'D40_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'D40_ROLLBACK' THEN NULL;
    ELSE
      v_st := SQLSTATE;
      v_w_negative := CASE WHEN v_st='23514' THEN 'refused'
                           WHEN v_st='42703' THEN 'no_column'
                           ELSE 'other:'||v_st END;
    END IF;
  END;

  ------------------------------------------------------------------ 5. THE MAP --
  SELECT COALESCE(m.target_param,'absent'),
         COALESCE(m.s_term,'absent'),
         COALESCE(m.param_rewards,'absent'),
         COALESCE(m.is_active::text,'absent'),
         COALESCE(m.monotonicity::text,'absent'),
         CASE WHEN m.monotonicity IS NULL THEN 'absent'
              WHEN abs(m.monotonicity) >= 0.70 THEN 'yes' ELSE 'no' END,
         CASE WHEN m.note IS NULL THEN 'absent'
              WHEN m.note ILIKE '%zero%' AND m.note ILIKE '%multiplicative%' THEN 'yes'
              ELSE 'no' END
    INTO v_map_target, v_map_sterm, v_map_rewards, v_map_active,
         v_map_mono, v_map_mono_ok, v_map_note_zero
    FROM public.picker_feature_param_map_v3 m
   WHERE m.feature = 'active_intent_count';

  -- The miner's own dial lookup, reproduced exactly: (to_jsonb(p) ->> target)::numeric,
  -- and its 'no_such_dial' gate fires when that is NULL. Cheaper and more precise than
  -- running the miner, and it is the same expression.
  SELECT COALESCE(((to_jsonb(p) ->> 'w_intents')::numeric IS NOT NULL)::text,'absent')
    INTO v_dial_reachable
    FROM public.pick_urgency_params p ORDER BY p.id LIMIT 1;

  -- ⛔⛔ WHY THE MAP STAYS INACTIVE, pinned as arithmetic rather than as a comment.
  --    The miner proposes multiplicatively: v_prop := v_cur * (1 +/- delta/100). At
  --    v_cur = 0 that is 0 for every delta, so the proposal rounds back onto itself and
  --    is refused as 'round_to_equal' - a refusal naming the wrong cause. Activating the
  --    map before CS supplies a non-zero starting value would ship that silence.
  SELECT COALESCE((round(COALESCE((to_jsonb(p)->>'w_intents')::numeric, -1) * 1.05, 3)
                   = round(COALESCE((to_jsonb(p)->>'w_intents')::numeric, -1), 3))::text,'absent')
    INTO v_zero_frozen
    FROM public.pick_urgency_params p ORDER BY p.id LIMIT 1;

  ----------------------------------------------------------------- 6. RESIDUE --
  SELECT COALESCE(to_jsonb(p)->>'w_intents','absent'),
         COALESCE(to_jsonb(p)->>'intents_norm','absent'),
         to_char(p.updated_at AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI:SS.US')
    INTO v_w_after, v_norm_after, v_ua_after
    FROM public.pick_urgency_params p ORDER BY p.id LIMIT 1;

  SELECT count(*)::int INTO v_rpo_after FROM public.refill_plan_output;

  SELECT count(*)::int INTO v_law4_clusters
    FROM public.engine_cutover_authority_v3 a WHERE a.authoritative_engine = 'v3';

  ----------------------------------------------------------------- 7. SCRATCH --
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES
    (78, 'premise', jsonb_build_object(
       'cols', v_cols, 'checks', v_checks, 'w_intents', v_w, 'intents_norm', v_norm,
       'fleet_n', v_fleet_n, 'levels', v_levels, 'intent_max', v_intent_max)),
    (78, 'structure', jsonb_build_object(
       'sites_runout', v_sites_runout, 'sites_intents', v_sites_intents,
       'sites_equal', v_sites_equal, 'out_col', v_out_col)),
    (78, 'feature', jsonb_build_object(
       'corr', v_corr_feature, 's_min', v_s_min, 's_max', v_s_max,
       'null_s', v_null_s, 'null_score', v_null_score, 'null_urgency', v_null_urgency,
       'neg_s', v_neg_s)),
    (78, 'dial', jsonb_build_object(
       'probe_err', v_probe_err, 'probe_state', v_probe_state,
       'decreased', v_n_decreased, 'increased', v_n_increased, 'off_by', v_n_offby,
       'corr', v_corr_dial, 'tier_moved', v_n_tier_up, 'inert0_diff', v_inert0_diff,
       'w_probed', c_w::text)),
    (78, 'guards', jsonb_build_object(
       'norm_zero', v_norm_zero, 'w_negative', v_w_negative)),
    (78, 'map', jsonb_build_object(
       'target', v_map_target, 's_term', v_map_sterm, 'rewards', v_map_rewards,
       'active', v_map_active, 'monotonicity', v_map_mono, 'mono_ok', v_map_mono_ok,
       'note_names_zero', v_map_note_zero, 'dial_reachable', v_dial_reachable,
       'zero_frozen', v_zero_frozen)),
    (78, 'residue', jsonb_build_object(
       'w_after', v_w_after, 'norm_after', v_norm_after,
       'updated_at_unchanged', CASE WHEN v_ua_before = v_ua_after THEN 'yes' ELSE 'no' END,
       'updated_at', v_ua_after,
       'rpo_delta', v_rpo_after - v_rpo_before,
       'w_empty', v_w_empty, 'law4_clusters', v_law4_clusters));
END $do$;
$scen$,
  'Leg 164. Red baseline taken before the dial exists: every sensor reads through to_jsonb / pg_get_viewdef / information_schema so the scenario cannot throw on the pre-change image. Two rolled-back subtransactions (fixture 73 device) carry every write; the live params row is byte-unchanged, updated_at included.',
  true,
  'failing_expected'
);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES

--------------------------------------------------------------------- PREMISE --
(78, 1, 'D-40 PREMISE: the live fleet supplies at least TWO distinct active_intent_count levels. ⛔ This is a premise, not a nicety - at one level corr() is NULL and every monotonicity assertion below goes vacuously green over a degenerate sample (S-289). If this reddens, the correlation evidence is gone, not merely weaker.',
 $q$SELECT COALESCE((SELECT value->>'levels' FROM golden.scratch WHERE fixture_id=78 AND key='premise'),'absent')$q$,
 'gte', '2', true, 'P4'),

(78, 2, 'D-40 PREMISE: the correlation is computed over a real fleet, not over three rows left behind by another fixture.',
 $q$SELECT COALESCE((SELECT value->>'fleet_n' FROM golden.scratch WHERE fixture_id=78 AND key='premise'),'absent')$q$,
 'gte', '20', true, 'P4'),

(78, 3, 'D-40: both dial columns exist on pick_urgency_params - the weight and the norm that scales it. One without the other is a dial with no units.',
 $q$SELECT COALESCE((SELECT value->>'cols' FROM golden.scratch WHERE fixture_id=78 AND key='premise'),'absent')$q$,
 'eq', '2', true, 'P4'),

(78, 4, '⭐ THE D-40 TELL. w_intents ships at 0 and STAYS at 0 until CS rules a value. Same idiom as fixture 58 seq 43 for w_empty: if this ever reads anything else, the picker was re-weighted outside a ruling - and unlike every other dial this one has never been sanctioned at any non-zero value.',
 $q$SELECT COALESCE((SELECT value->>'w_intents' FROM golden.scratch WHERE fixture_id=78 AND key='premise'),'absent')$q$,
 'eq', '0', true, 'P4'),

(78, 5, 'D-40: intents_norm carries its designed default - the open-intent count at which a machine reads as fully attended.',
 $q$SELECT COALESCE((SELECT value->>'intents_norm' FROM golden.scratch WHERE fixture_id=78 AND key='premise'),'absent')$q$,
 'eq', '3', true, 'P4'),

(78, 6, 'D-40: both CHECK constraints are present by name. The norm CHECK is what makes a zero divisor impossible; the weight CHECK is what keeps the direction in the TERM instead of in a sign CS could typo.',
 $q$SELECT COALESCE((SELECT value->>'checks' FROM golden.scratch WHERE fixture_id=78 AND key='premise'),'absent')$q$,
 'eq', '2', true, 'P4'),

------------------------------------------------------------------- STRUCTURE --
(78, 7, '⛔⛔ THE SITE GUARD, AND IT IS AN EQUALITY ON PURPOSE. The new term must appear at EVERY site that carries the weighted sum, counted against a sibling term rather than against a literal. The parking lot said SIX sites; pg_get_viewdef says five. A hard-coded 5 would pass a view that later gains a sixth site without w_intents - the exact drift this guard exists to catch (S-299: an enumeration is a claim, not a site list).',
 $q$SELECT COALESCE((SELECT value->>'sites_equal' FROM golden.scratch WHERE fixture_id=78 AND key='structure'),'absent')$q$,
 'eq', 'yes', true, 'P4'),

(78, 8, 'D-40: and the count is not zero on either side - an equality of two zeroes would satisfy seq 7 over a view that lost the weighted sum entirely.',
 $q$SELECT COALESCE((SELECT value->>'sites_intents' FROM golden.scratch WHERE fixture_id=78 AND key='structure'),'absent')$q$,
 'gte', '1', true, 'P4'),

(78, 9, 'D-40: s_intents is EXPOSED as a view column, not merely summed into the score. A term nobody can read is a term nobody can audit - and it is what makes the dial-controls-score probe below arithmetic rather than assertion.',
 $q$SELECT COALESCE((SELECT value->>'out_col' FROM golden.scratch WHERE fixture_id=78 AND key='structure'),'absent')$q$,
 'eq', '1', true, 'P4'),

-------------------------------------------------------- DIAL CONTROLS FEATURE --
(78, 10, '⭐⭐ THE MONOTONICITY PROBE CS ASKED FOR, HALF ONE: the s_term tracks the feature. corr(s_intents, active_intent_count) over the live fleet is -1.000 - NEGATIVE by design, because CS DROPS machines carrying more open intents (38.2% concordance = 61.8% inverse). This is the same idiom as fill_pct -> w_capacity at -0.458, and it is why the map row reads param_rewards = low.',
 $q$SELECT COALESCE((SELECT value->>'corr' FROM golden.scratch WHERE fixture_id=78 AND key='feature'),'absent')$q$,
 'eq', '-1.000', true, 'P4'),

(78, 11, '⛔⛔ 0 * NULL IS NULL, AND THAT IS THE ONE FAILURE AN INERT DIAL CANNOT SURVIVE. A NULL s_intents does not contribute nothing at w_intents = 0 - it propagates through the whole weighted sum and takes p_score, urgency and both tier gates with it, on every machine in the fleet. Zero NULLs, and the CHECK plus the COALESCE fallback are why.',
 $q$SELECT COALESCE((SELECT value->>'null_s' FROM golden.scratch WHERE fixture_id=78 AND key='feature'),'absent')$q$,
 'eq', '0', true, 'P4'),

(78, 12, 'D-40: and the score itself survived - stated separately from seq 11 because "the term is null" and "the sum is null" are different failures and a single counter would blur which one fired.',
 $q$SELECT COALESCE((SELECT value->>'null_score' FROM golden.scratch WHERE fixture_id=78 AND key='feature'),'absent')$q$,
 'eq', '0', true, 'P4'),

(78, 13, 'D-40: urgency too. It is a second cast of the same sum and a fixture that checked only p_score would miss a site.',
 $q$SELECT COALESCE((SELECT value->>'null_urgency' FROM golden.scratch WHERE fixture_id=78 AND key='feature'),'absent')$q$,
 'eq', '0', true, 'P4'),

(78, 14, 'D-40: s_intents is never negative. It is an urgency contribution and a negative one would silently subtract from the score of a machine nobody has an intent on - the opposite of what the measured signal says.',
 $q$SELECT COALESCE((SELECT value->>'neg_s' FROM golden.scratch WHERE fixture_id=78 AND key='feature'),'absent')$q$,
 'eq', '0', true, 'P4'),

(78, 15, 'D-40: the term saturates at 100 for a machine with nothing open on it - the top of the same 0..100 scale every sibling s_term uses.',
 $q$SELECT COALESCE((SELECT value->>'s_max' FROM golden.scratch WHERE fixture_id=78 AND key='feature'),'absent')$q$,
 'eq', '100.00', true, 'P4'),

---------------------------------------------------------- DIAL CONTROLS SCORE --
(78, 16, 'D-40 PREMISE for the whole dial probe: the subtransaction reached its sentinel and rolled back cleanly. Any other state means the numbers below were measured against something that errored, and every one of them is meaningless.',
 $q$SELECT COALESCE((SELECT value->>'probe_state' FROM golden.scratch WHERE fixture_id=78 AND key='dial'),'absent')$q$,
 'eq', 'rolled_back', true, 'P4'),

(78, 17, 'D-40: and it raised no error on the way there.',
 $q$SELECT COALESCE((SELECT value->>'probe_err' FROM golden.scratch WHERE fixture_id=78 AND key='dial'),'absent')$q$,
 'eq', '', true, 'P4'),

(78, 18, '⭐⭐ THE MONOTONICITY PROBE, HALF TWO: THE DIAL CONTROLS THE SCORE. Raising w_intents to 0.25 moves every machine p_score by exactly w * s_intents - zero machines off the identity, to a 0.02 tolerance that covers the two numeric(6,2) roundings. ⛔ This is what "dial-controls-feature" has to mean before the miner may map to it: not that the number exists, but that turning it moves the thing it claims to move. The fill_pct -> w_lowfill mapping died on exactly this test at corr -0.042.',
 $q$SELECT COALESCE((SELECT value->>'off_by' FROM golden.scratch WHERE fixture_id=78 AND key='dial'),'absent')$q$,
 'eq', '0', true, 'P4'),

(78, 19, 'D-40: the delta correlates perfectly with s_intents, which is the same fact as seq 18 read as a shape rather than as a residual. Both are kept: an off-by count of 0 with a NULL correlation would mean the dial moved nothing at all.',
 $q$SELECT COALESCE((SELECT value->>'corr' FROM golden.scratch WHERE fixture_id=78 AND key='dial'),'absent')$q$,
 'eq', '1.000', true, 'P4'),

(78, 20, 'D-40: a non-negative weight on an urgency term can only RAISE a score. Zero machines went down.',
 $q$SELECT COALESCE((SELECT value->>'decreased' FROM golden.scratch WHERE fixture_id=78 AND key='dial'),'absent')$q$,
 'eq', '0', true, 'P4'),

(78, 21, '⛔ AND IT IS NOT DECORATION: turning the dial moved at least one machine. A term that satisfies every identity above while moving nobody would be a dial wired to nothing, and every count-based assertion here would still be green.',
 $q$SELECT COALESCE((SELECT value->>'increased' FROM golden.scratch WHERE fixture_id=78 AND key='dial'),'absent')$q$,
 'gte', '1', true, 'P4'),

(78, 22, '⭐ THE INERTNESS PROOF, STATED AS A ROUND TRIP. Back at w_intents = 0, every machine returns to the exact p_score, urgency AND p_tier it had before the dial was touched. Not "the count matched" - the identity did, per machine, across all three (D-29 seq idiom: pin the set, not its size).',
 $q$SELECT COALESCE((SELECT value->>'inert0_diff' FROM golden.scratch WHERE fixture_id=78 AND key='dial'),'absent')$q$,
 'eq', '0', true, 'P4'),

------------------------------------------------------------- THE CONSTRAINTS --
(78, 23, 'D-40: intents_norm = 0 is REFUSED by the CHECK, with SQLSTATE 23514 read back rather than "it errored". ⛔ The distinction matters: 42703 (no such column) is what the red baseline returns, and a guard that accepted any error would have called the missing column a working constraint.',
 $q$SELECT COALESCE((SELECT value->>'norm_zero' FROM golden.scratch WHERE fixture_id=78 AND key='guards'),'absent')$q$,
 'eq', 'refused', true, 'P4'),

(78, 24, 'D-40: a negative w_intents is REFUSED. The measured direction lives in the TERM (s_intents is high when few intents are open), so a signed weight would be a second, contradictory place to express it - and the only dial in the set whose sign is load-bearing.',
 $q$SELECT COALESCE((SELECT value->>'w_negative' FROM golden.scratch WHERE fixture_id=78 AND key='guards'),'absent')$q$,
 'eq', 'refused', true, 'P4'),

-------------------------------------------------------------------- THE MAP --
(78, 25, 'D-40: active_intent_count is no longer refused FOR WANT OF A DIAL - the map names the dial it targets.',
 $q$SELECT COALESCE((SELECT value->>'target' FROM golden.scratch WHERE fixture_id=78 AND key='map'),'absent')$q$,
 'eq', 'w_intents', true, 'P4'),

(78, 26, 'D-40: and the s_term that carries it, so a reader can get from the CS signal to the arithmetic in one hop.',
 $q$SELECT COALESCE((SELECT value->>'s_term' FROM golden.scratch WHERE fixture_id=78 AND key='map'),'absent')$q$,
 'eq', 's_intents', true, 'P4'),

(78, 27, '⛔ POLARITY COMES FROM THE TABLE SO THE SIGN IS FALSIFIABLE (fixture 58 idiom). param_rewards = low: the dial rewards a LOW intent count, which is what 61.8% inverse concordance means. Written as low with a -1.000 monotonicity, the miner computes direction from evidence rather than from a hunch.',
 $q$SELECT COALESCE((SELECT value->>'rewards' FROM golden.scratch WHERE fixture_id=78 AND key='map'),'absent')$q$,
 'eq', 'low', true, 'P4'),

(78, 28, 'D-40: the measured monotonicity is recorded on the map row, not just in a leg report, and it clears the 0.70 bar that refused fill_pct, runway_days and dead_slot_pct.',
 $q$SELECT COALESCE((SELECT value->>'mono_ok' FROM golden.scratch WHERE fixture_id=78 AND key='map'),'absent')$q$,
 'eq', 'yes', true, 'P4'),

(78, 29, '⛔⛔ AND THE MAP STAYS INACTIVE, DELIBERATELY. CS ruled the probe must pass "before the miner may map to it"; the probe passes and the miner still must not. The miner proposes multiplicatively - v_prop := v_cur * (1 +/- delta/100) - so a dial at 0 computes 0 for every delta and is refused as round_to_equal, a refusal naming the wrong cause. Activating this row would ship that silence. The blocker is a NUMBER from CS, not a re-decision.',
 $q$SELECT COALESCE((SELECT value->>'active' FROM golden.scratch WHERE fixture_id=78 AND key='map'),'absent')$q$,
 'eq', 'false', true, 'P4'),

(78, 30, 'D-40: and the note says WHY in the words a future leg will search for, so nobody flips is_active without meeting the arithmetic first.',
 $q$SELECT COALESCE((SELECT value->>'note_names_zero' FROM golden.scratch WHERE fixture_id=78 AND key='map'),'absent')$q$,
 'eq', 'yes', true, 'P4'),

(78, 31, 'D-40: the miner CAN now find the dial - (to_jsonb(p) ->> target)::numeric IS NOT NULL, which is verbatim the expression behind its no_such_dial gate. That gate is what stood between this feature and a proposal for eight legs.',
 $q$SELECT COALESCE((SELECT value->>'dial_reachable' FROM golden.scratch WHERE fixture_id=78 AND key='map'),'absent')$q$,
 'eq', 'true', true, 'P4'),

(78, 32, '⛔ THE ARITHMETIC BEHIND seq 29, PINNED RATHER THAN COMMENTED: at the shipped value, a 5% multiplicative move rounds back onto the current weight. As long as this reads true, activating the map yields a refusal and nothing else. When CS supplies a non-zero start it reads false, and that flip is the signal to revisit is_active.',
 $q$SELECT COALESCE((SELECT value->>'zero_frozen' FROM golden.scratch WHERE fixture_id=78 AND key='map'),'absent')$q$,
 'eq', 'true', true, 'P4'),

---------------------------------------------------------------------- RESIDUE --
(78, 33, 'D-40 residue: the probe left w_intents at 0. Two subtransactions wrote this row and both rolled back.',
 $q$SELECT COALESCE((SELECT value->>'w_after' FROM golden.scratch WHERE fixture_id=78 AND key='residue'),'absent')$q$,
 'eq', '0', true, 'P4'),

(78, 34, 'D-40 residue: and intents_norm at 3.',
 $q$SELECT COALESCE((SELECT value->>'norm_after' FROM golden.scratch WHERE fixture_id=78 AND key='residue'),'absent')$q$,
 'eq', '3', true, 'P4'),

(78, 35, '⛔ THIS FIXTURE IS NOT THE ONE TO BREAK S-138. fixture 58 seq 33 pins max(updated_at) on pick_urgency_params to an exact microsecond so that ANY unattributed touch of the picker weights reddens it. This fixture writes that row twice and must leave the stamp exactly where it found it - which it does, because the probe never sets updated_at and both writes roll back.',
 $q$SELECT COALESCE((SELECT value->>'updated_at_unchanged' FROM golden.scratch WHERE fixture_id=78 AND key='residue'),'absent')$q$,
 'eq', 'yes', true, 'P4'),

(78, 36, 'D-40 residue: w_empty still carries the value DR-5 applied on the CS ruling. Named here because this fixture is the second thing in the build that writes pick_urgency_params, and the first one that does it twice.',
 $q$SELECT COALESCE((SELECT value->>'w_empty' FROM golden.scratch WHERE fixture_id=78 AND key='residue'),'absent')$q$,
 'eq', '0.945', true, 'P4'),

(78, 37, 'D-40 LAW 12: this fixture wrote no plan row. The picker view is read-only here and a delta of anything but zero means a probe reached a live plan table.',
 $q$SELECT COALESCE((SELECT value->>'rpo_delta' FROM golden.scratch WHERE fixture_id=78 AND key='residue'),'absent')$q$,
 'eq', '0', true, 'P4'),

(78, 38, 'D-40 LAW 4: zero clusters are authoritative for v3 at the end of this fixture. The dial is a picker dial, not an engine flag - but every unit in this sprint states the flag position it left behind, and a unit that touched the canonical priority view states it louder.',
 $q$SELECT COALESCE((SELECT value->>'law4_clusters' FROM golden.scratch WHERE fixture_id=78 AND key='residue'),'absent')$q$,
 'eq', '0', true, 'P4');
