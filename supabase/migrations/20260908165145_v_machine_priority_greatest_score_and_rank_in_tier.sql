-- v_machine_priority: replace the weighted-sum urgency score with
-- GREATEST(s_runout, s_empty, s_lowfill, s_expiry, s_stale, s_holes) in
-- p_score and both tier CASEs, add rank_in_tier.
--
-- CS: the weighted sum (w_runout=0.35, w_capacity=0.10, w_expiry=0.12,
-- w_stale=0.13, w_empty=0.945, w_lowfill=0.5, w_holes=0.30, w_intents=0)
-- structurally dilutes a single catastrophic signal -- s_runout alone at
-- 100 (a shelf about to run dry) only contributed 35 to the old sum, never
-- enough alone to clear p1_threshold=50 no matter how bad it got. GREATEST
-- takes the worst of the six real urgency signals instead of blending them,
-- so one severe signal can no longer hide behind a low weighted average.
-- s_capacity and s_intents are deliberately excluded from the GREATEST list
-- (CS decision) -- they stay as exposed columns but no longer drive p_tier
-- or p_score.
--
-- This is the same "the weighted sum occurs FIVE times in the view body"
-- object PRD-110 D-40 documented (p_tier's P1 test, p_tier's P2 test,
-- p_score, urgency, and reasons_arr's high_urgency check) -- all five
-- replaced together via a single `replace()` call so none can drift out of
-- sync with the others.
--
-- rank_in_tier: ROW_NUMBER() OVER (PARTITION BY p_tier ORDER BY
-- units_last_7d DESC) -- a strict, gapless sequence for actually routing
-- drivers within a tier (CS: keep ROW_NUMBER, not RANK -- ties don't need to
-- share a slot). Added via a non-destructive outer wrapper (the existing
-- view body becomes a CTE) rather than duplicating the already-five-times-
-- repeated p_tier CASE a sixth time just to partition by it.
--
-- Hard overrides (hero_below+cooldown, stale_override_days, expired_now,
-- empty_ab_count, holes_a/holes_total) are byte-identical, untouched -- only
-- the final `OR (<score>) >= threshold` branch of each tier CASE changes.
--
-- Fleet impact measured live before this file was written (rolled back):
-- distribution P1=7/P2=1/P3=24 -> P1=7/P2=2/P3=23. Exactly one machine
-- changes tier: MPMCC-1058-0000-R0, P3_OK -> P2_MAINTAIN (score 5.80 ->
-- 28.57, s_stale=28.57 alone now clears p2_threshold=25; previously diluted
-- to ~3.7 by w_stale=0.13). AMZ-1038-3001-O1 does not move today (fully
-- healthy on all 6 terms post-delivery, 91 units delivered same-day) -- CS
-- confirmed the pre-delivery snapshot (s_runout=51.6, soonest_a_dos=0.65)
-- would have cleared P1 under this formula, matching intent.
--
-- Cody: approve, Article 16 (canonical object rewritten in place, same
-- pattern as PRD-063's own in-place rewrite of this exact view), Article 12
-- (forward-only, md5-guarded).
DO $mig$ DECLARE v_def text; v_new text; v_wrapped text; BEGIN
  SELECT pg_get_viewdef('public.v_machine_priority'::regclass, true) INTO v_def;
  IF md5(v_def) <> 'abeb38ea4763deaa116157b328cd679a' THEN
    RAISE EXCEPTION 'v_machine_priority drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;

  v_new := replace(v_def,
    'p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill + p.w_holes * ms.s_holes + p.w_intents * ms.s_intents',
    'GREATEST(ms.s_runout, ms.s_empty, ms.s_lowfill, ms.s_expiry, ms.s_stale, ms.s_holes)');
  IF v_new = v_def THEN
    RAISE EXCEPTION 'v_machine_priority: weighted-sum pattern not found';
  END IF;

  -- strip the trailing statement terminator pg_get_viewdef appends, so the
  -- body can be wrapped as a parenthesized CTE subquery
  v_new := regexp_replace(v_new, ';\s*$', '');

  v_wrapped := 'WITH v_machine_priority_base AS (' || v_new || ') '
    || 'SELECT *, ROW_NUMBER() OVER (PARTITION BY p_tier ORDER BY units_last_7d DESC) AS rank_in_tier '
    || 'FROM v_machine_priority_base';

  EXECUTE 'CREATE OR REPLACE VIEW public.v_machine_priority AS ' || v_wrapped;
END $mig$;
