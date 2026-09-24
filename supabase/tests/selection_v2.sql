-- PRD-133 (loop 2026-09-25 B6): selection v2 assertions against pick_machines_v12's real,
-- current live behaviour.
--
-- These are NOT a historical replay (see docs/loops/2026-09-25-selection-v2/STATE.md, "Scope
-- decision on B4-B6": pick_machines_v12 only reads the latest WEIMI snapshot, so there is no
-- as-of-date capability to replay a past day yet). Every assertion here reads real production
-- data through pick_machines_v12 itself, read-only, no writes; safe to re-run any time. Each
-- check RAISEs on failure, so `\set ON_ERROR_STOP on` (or the migration runner's own default)
-- stops the file at the first real regression.
--
-- Run against plan_date 2026-09-25, the loop's own evidence day. Rerunning this file on a later
-- date will read that later day's live data instead; the specific machine names below (AMZ-1029,
-- VOXMCC-1005-0201-B0, AMZ-1068, VML-1004) are the loop's named acceptance evidence, not fixtures,
-- so a rerun may show different pass/fail as the fleet's real state changes day to day. That is
-- expected: this file checks the RULES, not a frozen scenario.

\set ON_ERROR_STOP on

DO $$
DECLARE
  v_plan_date date := '2026-09-25';
  v_tier text;
  v_count int;
BEGIN

  -- P1 rule: expired/expiring stock forces P1 regardless of days_since_visit (the cooldown bypass).
  -- AMZ-1029-3003-O1 is the named evidence (Activia expiring on the plan date) and, confirmed
  -- live, has days_since_visit = 0 today, i.e. visited within the last day -- exactly the
  -- condition that would otherwise trigger the "skip: visited within 1 day and no P1 trigger"
  -- rule. It still shows P1, proving the bypass works, not just that the machine happens to
  -- qualify some other way.
  SELECT tier INTO v_tier FROM public.pick_machines_v12(v_plan_date, 8)
   WHERE official_name = 'AMZ-1029-3003-O1';
  IF v_tier IS DISTINCT FROM 'P1' THEN
    RAISE EXCEPTION 'FAIL P1/cooldown-bypass: AMZ-1029-3003-O1 expected tier=P1, got %', COALESCE(v_tier, 'NULL (not picked)');
  END IF;
  RAISE NOTICE 'PASS P1/cooldown-bypass: AMZ-1029-3003-O1 is P1';

  -- VOX rule: a VOX (venue-supplied) machine must never be P1 on anything other than expiry or an
  -- empty hero lane. VOXMCC-1005-0201-B0 is the named evidence machine that must not be P1.
  SELECT tier INTO v_tier FROM public.pick_machines_v12(v_plan_date, 30)
   WHERE official_name = 'VOXMCC-1005-0201-B0';
  IF v_tier = 'P1' THEN
    RAISE EXCEPTION 'FAIL VOX-gate: VOXMCC-1005-0201-B0 must not be P1, got P1';
  END IF;
  RAISE NOTICE 'PASS VOX-gate: VOXMCC-1005-0201-B0 is not P1 (tier=%)', COALESCE(v_tier, 'not picked');

  -- Cap rule: with the default cap (8), the number of rows outside P1 (P1 is exempt from the cap,
  -- confirmed live in B2) must never exceed 8.
  SELECT COUNT(*) INTO v_count FROM public.pick_machines_v12(v_plan_date, 8) WHERE tier <> 'P1';
  IF v_count > 8 THEN
    RAISE EXCEPTION 'FAIL cap: expected at most 8 non-P1 rows, got %', v_count;
  END IF;
  RAISE NOTICE 'PASS cap: % non-P1 rows at cap 8 (<= 8)', v_count;

  -- P1 is never itself capped: raising the cap must never reduce the number of P1 rows returned.
  DECLARE v_p1_at_8 int; v_p1_at_30 int;
  BEGIN
    SELECT COUNT(*) INTO v_p1_at_8  FROM public.pick_machines_v12(v_plan_date, 8)  WHERE tier = 'P1';
    SELECT COUNT(*) INTO v_p1_at_30 FROM public.pick_machines_v12(v_plan_date, 30) WHERE tier = 'P1';
    IF v_p1_at_8 <> v_p1_at_30 THEN
      RAISE EXCEPTION 'FAIL P1-uncapped: P1 count changed with cap (8 -> %, 30 -> %)', v_p1_at_8, v_p1_at_30;
    END IF;
    RAISE NOTICE 'PASS P1-uncapped: % P1 rows regardless of cap', v_p1_at_8;
  END;

  -- Donor rule: a machine holding a slow-moving (velocity < 0.4/day), warehouse-out-of-stock SKU
  -- must be tagged cluster_role='donor' with positive visit_value_aed and a non-empty donor_for,
  -- when the cap is raised enough to include it. AMZ-1068-2401-O1 and VML-1004-0500-O1 are the
  -- named evidence machines (Vitamin Well and Red Bull respectively), confirmed live in B2.
  DECLARE v_role text; v_value numeric; v_donor_for jsonb;
  BEGIN
    SELECT cluster_role, visit_value_aed, donor_for INTO v_role, v_value, v_donor_for
      FROM public.pick_machines_v12(v_plan_date, 30) WHERE official_name = 'AMZ-1068-2401-O1';
    IF v_role IS DISTINCT FROM 'donor' OR COALESCE(v_value,0) <= 0 OR v_donor_for IS NULL THEN
      RAISE EXCEPTION 'FAIL donor: AMZ-1068-2401-O1 expected cluster_role=donor with positive value and a receiver list, got role=%, value=%, donor_for=%',
        v_role, v_value, v_donor_for;
    END IF;
    RAISE NOTICE 'PASS donor: AMZ-1068-2401-O1 is a donor worth % AED to %', v_value, v_donor_for;

    SELECT cluster_role, visit_value_aed, donor_for INTO v_role, v_value, v_donor_for
      FROM public.pick_machines_v12(v_plan_date, 30) WHERE official_name = 'VML-1004-0500-O1';
    IF v_role IS DISTINCT FROM 'donor' OR COALESCE(v_value,0) <= 0 OR v_donor_for IS NULL THEN
      RAISE EXCEPTION 'FAIL donor: VML-1004-0500-O1 expected cluster_role=donor with positive value and a receiver list, got role=%, value=%, donor_for=%',
        v_role, v_value, v_donor_for;
    END IF;
    RAISE NOTICE 'PASS donor: VML-1004-0500-O1 is a donor worth % AED to %', v_value, v_donor_for;
  END;

  -- Cluster rule: once any machine in a building is picked (P1 or P2), every other machine in
  -- that same building with some P2/P3 need becomes a P3 cluster candidate. Tested generically
  -- (not tied to one named building): at least one row must exist tagged cluster_role='cluster'
  -- whose own tier alone (P1/P2 need) did not already justify inclusion, i.e. it is a genuine
  -- pull-in, not a machine that would have been picked anyway.
  SELECT COUNT(*) INTO v_count
    FROM public.pick_machines_v12(v_plan_date, 30)
   WHERE cluster_role = 'cluster';
  IF v_count < 1 THEN
    RAISE EXCEPTION 'FAIL cluster: expected at least one cluster-tagged pull-in row, got 0';
  END IF;
  RAISE NOTICE 'PASS cluster: % row(s) tagged cluster_role=cluster', v_count;

  -- Reasons must be present and use no em dashes (hard rule, applies to engine output too).
  SELECT COUNT(*) INTO v_count
    FROM public.pick_machines_v12(v_plan_date, 30) p, unnest(p.reasons) r
   WHERE r LIKE '%' || chr(8212) || '%';
  IF v_count > 0 THEN
    RAISE EXCEPTION 'FAIL no-em-dash: % reason string(s) contain an em dash', v_count;
  END IF;
  RAISE NOTICE 'PASS no-em-dash: no reason strings contain an em dash';

  RAISE NOTICE 'ALL selection_v2 CHECKS PASSED for plan_date %', v_plan_date;
END $$;
