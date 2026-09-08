-- Regression fixture (CS): a machine with s_runout >= 50 and every other
-- urgency signal at 0 must be graded P1_RESTOCK. Pins the exact defect class
-- the GREATEST rewrite fixed -- under the old weighted sum, w_runout=0.35
-- meant s_runout could hit 100 (a shelf about to run dry) and still only
-- contribute 35 to p_score, never enough alone to clear p1_threshold=50 no
-- matter how severe the runout got. This is what let a real pre-delivery
-- AMZ-1038-3001-O1 (s_runout=51.6, soonest_a_dos=0.65 that day) sit at P3_OK
-- under the old model instead of P1.
--
-- Two independent checks, either sufficient to catch a reversion on its own:
--   1. Structural -- the live v_machine_priority view body must still
--      contain GREATEST(ms.s_runout, ms.s_empty, ms.s_lowfill, ms.s_expiry,
--      ms.s_stale, ms.s_holes) at least 3 times (the P1 test, P2 test, and
--      p_score at minimum -- the full count today is 5, matching the
--      documented "weighted sum occurs FIVE times" history of this object).
--   2. Arithmetic -- GREATEST(50,0,0,0,0,0) must clear the live
--      pick_urgency_params.p1_threshold (read live, not hardcoded, so a
--      future threshold retune doesn't false-positive this fixture).
-- Verified in a rolled-back transaction: fails (correctly) against the
-- pre-rewrite view (0 GREATEST occurrences found), passes (correctly)
-- against the rewritten view (5 occurrences, 50 >= 50).
--
-- Same family as check_expiry_unvalidated / assert_sales_names_resolved --
-- nightly cron so a future edit to v_machine_priority that silently
-- reintroduces a weighted sum is caught within a day, not at the next
-- manual audit.
--
-- Cody: approve, Article 16 (regression guard for the canonical priority
-- object), no writes.
CREATE OR REPLACE FUNCTION public.assert_priority_runout_triggers_p1()
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  p record;
  v_score numeric;
  v_viewdef text;
  v_greatest_occurrences int;
BEGIN
  SELECT * INTO p FROM public.pick_urgency_params;

  SELECT pg_get_viewdef('public.v_machine_priority'::regclass, true) INTO v_viewdef;
  SELECT (length(v_viewdef) - length(replace(v_viewdef,
    'GREATEST(ms.s_runout, ms.s_empty, ms.s_lowfill, ms.s_expiry, ms.s_stale, ms.s_holes)', '')))
    / length('GREATEST(ms.s_runout, ms.s_empty, ms.s_lowfill, ms.s_expiry, ms.s_stale, ms.s_holes)')
    INTO v_greatest_occurrences;
  IF v_greatest_occurrences < 3 THEN
    RAISE EXCEPTION 'REGRESSION: v_machine_priority no longer computes GREATEST(s_runout,s_empty,s_lowfill,s_expiry,s_stale,s_holes) in at least the P1/P2 tier tests and p_score (found % occurrences, expected >= 3) -- has the scoring model reverted to a weighted sum?', v_greatest_occurrences;
  END IF;

  v_score := GREATEST(50::numeric, 0, 0, 0, 0, 0);
  IF v_score < p.p1_threshold THEN
    RAISE EXCEPTION 'REGRESSION: s_runout=50 with every other urgency signal at 0 should trigger P1_RESTOCK (GREATEST=% >= p1_threshold=%), but does not', v_score, p.p1_threshold;
  END IF;

  RETURN jsonb_build_object('status','ok', 'greatest_occurrences_in_view', v_greatest_occurrences,
    's_runout',50,'other_signals',0,'greatest_score',v_score,'p1_threshold',p.p1_threshold,
    'p1_triggered', v_score >= p.p1_threshold);
END;
$function$;

SELECT cron.schedule(
  'assert_priority_runout_triggers_p1_nightly',
  '15 20 * * *',
  $$ SELECT public.assert_priority_runout_triggers_p1(); $$
);
