-- PRD-110 · leg 164 · D-40 · THE MAP ROW, AND WHY IT STAYS INACTIVE
--
-- CS ruling: the monotonicity probe must prove dial-controls-feature "before the miner may map
-- to it". The probe passes on both halves - corr(s_intents, active_intent_count) = -1.000 over
-- the live fleet, and turning the dial moves p_score by exactly w * s_intents (fixture 78).
--
-- ⛔⛔ AND THE MINER STILL MUST NOT BE LET AT IT. mine_pick_history_v3 proposes MULTIPLICATIVELY:
--     v_prop := v_cur * (1 +/- v_delta/100). At v_cur = 0 that is 0 for every delta, so the
--     proposal rounds back onto the current weight and is refused as `round_to_equal` - a
--     refusal that names the wrong cause. Activating this row would ship a silence: a reader
--     would conclude the evidence was too thin, when the truth is the dial has no starting
--     value. The evidence is recorded; is_active waits on a NUMBER from CS, not a re-decision.

DO $g$
DECLARE
  v_corr    numeric;
  v_levels  int;
  v_n       int;
  v_before  jsonb;
  v_after   jsonb;
BEGIN
  -- ---------------------------------------------------------------- PREMISE --
  SELECT count(*), count(DISTINCT h.active_intent_count)
    INTO v_n, v_levels
    FROM public.v_machine_health_signals h;

  IF v_levels < 2 THEN
    RAISE EXCEPTION 'D-40 map: active_intent_count carries % level(s) on the live fleet - corr is NULL and there is nothing to record', v_levels;
  END IF;

  SELECT round(corr(v.s_intents, h.active_intent_count::numeric)::numeric, 3)
    INTO v_corr
    FROM public.v_machine_priority v
    JOIN public.v_machine_health_signals h ON h.machine_id = v.machine_id;

  IF v_corr IS NULL OR abs(v_corr) < 0.70 THEN
    RAISE EXCEPTION 'D-40 map: monotonicity is % - below the 0.70 bar that refused fill_pct, runway_days and dead_slot_pct. The mapping is NOT recorded', v_corr;
  END IF;

  -- ⛔ The measured value is WRITTEN, never a literal. fill_pct sits on this table at -0.458
  --    because somebody measured it and wrote down what came back; a hand-typed -1.000 here
  --    would be the one number on the row nobody had checked.
  SELECT to_jsonb(m) INTO v_before
    FROM public.picker_feature_param_map_v3 m WHERE m.feature = 'active_intent_count';

  IF v_before IS NULL THEN
    RAISE EXCEPTION 'D-40 map: no map row for active_intent_count to update';
  END IF;

  IF (v_before->>'is_active')::boolean THEN
    RAISE EXCEPTION 'D-40 map: the row is already active - this migration would silently re-inactivate a mapping somebody turned on';
  END IF;

  UPDATE public.picker_feature_param_map_v3 m
     SET target_param  = 'w_intents',
         s_term        = 's_intents',
         param_rewards = 'low',
         monotonicity  = v_corr,
         is_active     = false,
         note = format(
           '⏸️ MAPPED, NOT ACTIVE - and the blocker is a NUMBER, not evidence. D-40 (CS 2026-08-01) '
           'built the dial this feature was refused for want of: w_intents, with s_intents as its '
           'urgency term. corr(s_intents, active_intent_count) = %s over %s machines and %s levels, '
           'well clear of the 0.70 bar; turning the dial moves p_score by exactly w * s_intents '
           '(golden fixture 78). param_rewards = low because CS DROPS machines carrying more open '
           'intents - 38.2%% concordance over 1653 pairs, i.e. 61.8%% inverse, the second-strongest '
           'signal in this table. ⛔ is_active stays FALSE because w_intents SHIPPED AT ZERO and the '
           'miner proposes multiplicatively: v_cur * (1 +/- delta/100) is 0 for every delta at a '
           'zero dial, so activation buys a round_to_equal refusal naming the wrong cause. '
           'THE ASK FOR CS: a non-zero starting value for w_intents. At 0.30 a machine with nothing '
           'open on it gains a flat +30 on a scale whose P1 gate is 50 - that is the size of the '
           'decision, and it is why it is a ruling and not a default.',
           v_corr::text, v_n::text, v_levels::text)
   WHERE m.feature = 'active_intent_count';

  SELECT to_jsonb(m) INTO v_after
    FROM public.picker_feature_param_map_v3 m WHERE m.feature = 'active_intent_count';

  -- ------------------------------------------------------------- POST-IMAGE --
  IF (v_after->>'is_active')::boolean THEN
    RAISE EXCEPTION 'D-40 map: is_active went true';
  END IF;
  IF v_after->>'target_param' <> 'w_intents' OR v_after->>'s_term' <> 's_intents'
     OR v_after->>'param_rewards' <> 'low' THEN
    RAISE EXCEPTION 'D-40 map: the row did not take the mapping';
  END IF;
  IF (v_after->>'note') NOT ILIKE '%zero%' OR (v_after->>'note') NOT ILIKE '%multiplicative%' THEN
    RAISE EXCEPTION 'D-40 map: the note does not name the blocker in the words a future leg will search for';
  END IF;

  -- ⛔ The eleven-row map is a census, not a bag: an UPDATE that touched a sibling would be a
  --    silent re-polarisation of a dial CS never discussed.
  IF (SELECT count(*) FROM public.picker_feature_param_map_v3) <> 11 THEN
    RAISE EXCEPTION 'D-40 map: the map is % rows, expected 11', (SELECT count(*) FROM public.picker_feature_param_map_v3);
  END IF;
  IF (SELECT count(*) FROM public.picker_feature_param_map_v3 WHERE is_active) <> 4 THEN
    RAISE EXCEPTION 'D-40 map: % active mappings, expected the same 4 as before', (SELECT count(*) FROM public.picker_feature_param_map_v3 WHERE is_active);
  END IF;

  RAISE NOTICE 'D-40 map: active_intent_count -> w_intents / s_intents, monotonicity %, INACTIVE', v_corr;
END $g$;

-- ============================================ FIXTURE 78: THE CHIP COUPLING ==
-- Cody's Article-16 revision, pinned. These read live objects directly rather than scratch -
-- the fixture-58 idiom (seq 33/34/43) for a fact that is about the catalogue, not about a run.

DELETE FROM golden.assertions WHERE fixture_id = 78 AND seq IN (39, 40, 41);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES

(78, 39, '⛔⛔ THE COUPLING CODY REFUSED TO LET WAIT. urgency_breakdown''s `runout` chip is a RESIDUAL - urgency minus the explicit terms - so an eighth term in urgency lands inside the chip LABELLED RUNOUT. And check_priority_surface_consistency() derives ITS chip_runout by subtracting the same list, so both sides move together and the guard is blind by construction (S-315). Both functions now carry the intents term. If either is ever regenerated from an older image, this reddens - which is the only way the surface stays honest on the day CS turns the dial.',
 $q$SELECT ((SELECT prosrc FROM pg_proc WHERE proname = 'get_machine_health') LIKE '%w_intents%'
       AND (SELECT prosrc FROM pg_proc WHERE proname = 'check_priority_surface_consistency') LIKE '%chip_intents%')::text$q$,
 'eq', 'true', true, 'P4'),

(78, 40, 'D-40: and the standing consistency guard agrees - zero machines where the chip surface and the canonical view disagree on any field, with the eighth term in the sum. This is the invariant "pts sum == v_machine_priority.urgency" measured rather than asserted.',
 $q$SELECT count(*)::text FROM public.check_priority_surface_consistency()$q$,
 'eq', '0', true, 'P4'),

(78, 41, '⭐ AND THE SURFACE FE RENDERS IS BYTE-UNCHANGED TODAY: at w_intents = 0 the intents chip is worth 0 points and the pre-existing `WHERE t.pts <> 0` filters it out entirely, so no chip appeared for a dial nobody has turned. ⛔ This assertion is EXPECTED to change the day CS supplies a value - it reads 0 chips because the dial is 0, not because the chip is missing, and seq 39 is what tells those two apart.',
 $q$SELECT count(*)::text FROM public.get_machine_health() g,
        LATERAL jsonb_array_elements(COALESCE(g.urgency_breakdown, '[]'::jsonb)) e
   WHERE e->>'label' = 'intents'$q$,
 'eq', '0', true, 'P4');
