-- PRD-133 (loop 2026-09-25 B6, updated for the CS HOLD F1-F8 fixes) : selection v2 assertions
-- against pick_machines_v12's real, current live behaviour.
--
-- These are NOT a historical replay (see docs/loops/2026-09-25-selection-v2/STATE.md, "Scope
-- decision on B4-B6": pick_machines_v12 only reads the latest WEIMI snapshot, so there is no
-- as-of-date capability to replay a past day yet). Every assertion here reads real production
-- data through pick_machines_v12 itself, read-only, no writes; safe to re-run any time. Each
-- check RAISEs on failure, so `\set ON_ERROR_STOP on` (or the migration runner's own default)
-- stops the file at the first real regression.
--
-- Run against plan_date 2026-09-25, the loop's own evidence day. Rerunning this file on a later
-- date will read that later day's live data instead; the specific machine names below are the
-- loop's named acceptance evidence, not fixtures, so a rerun may show different pass/fail as the
-- fleet's real state changes day to day. That is expected: this file checks the RULES, not a
-- frozen scenario.
--
-- The "existence" checks (at least one donor, at least one cluster pull-in) use a cap comfortably
-- above the fleet's total qualifying-machine count (100), not the real default cap (8), since
-- F7's re-ranked visit_value_aed can push a genuine but low-value example past a small cap. Using
-- 30 here once excluded the only real cluster pull-in for 2026-09-25 by a single rank position
-- (31 machines qualified that day); 100 is a safe margin without hardcoding today's exact count.
--
-- F1-F8 additions (CS HOLD, this run): total-cap now covers the whole result including P1 (F1),
-- cluster never fires on a NULL building_id now that machines.building_id is a real assignment
-- (F2), donor is tightened (F3, exercised by the same two named donor machines), a phantom
-- expiry lot no longer forces P1 (F4), a deliberately half-filled but low-value/low-velocity lane
-- no longer forces P1 on fill alone (F5), a P1 machine above the fleet's median daily revenue
-- must show a positive visit_value_aed (F7), and cluster_role='cluster' never co-occurs with an
-- independently-qualifying P1/P2 tier (F8).

\set ON_ERROR_STOP on

CREATE TEMP TABLE tmp_v12_cap8 AS SELECT * FROM public.pick_machines_v12('2026-09-25'::date, 8);
CREATE TEMP TABLE tmp_v12_cap100 AS SELECT * FROM public.pick_machines_v12('2026-09-25'::date, 100);

DO $$
DECLARE
  v_tier text;
  v_count int;
  v_total int;
  v_p1_at_8 int;
  v_p1_at_100 int;
  v_role text;
  v_value numeric;
  v_donor_for jsonb;
  v_median_rev numeric;
BEGIN

  -- P1 rule: expired/expiring stock forces P1 regardless of days_since_visit (the cooldown bypass).
  -- AMZ-1029-3003-O1 is the named evidence (Activia expiring on the plan date) and, confirmed
  -- live, has days_since_visit = 0 today, i.e. visited within the last day -- exactly the
  -- condition that would otherwise trigger the "skip: visited within 1 day and no P1 trigger"
  -- rule. It still shows P1, proving the bypass works, not just that the machine happens to
  -- qualify some other way.
  SELECT tier INTO v_tier FROM tmp_v12_cap8 WHERE official_name = 'AMZ-1029-3003-O1';
  IF v_tier IS DISTINCT FROM 'P1' THEN
    RAISE EXCEPTION 'FAIL P1/cooldown-bypass: AMZ-1029-3003-O1 expected tier=P1, got %', COALESCE(v_tier, 'NULL (not picked)');
  END IF;
  RAISE NOTICE 'PASS P1/cooldown-bypass: AMZ-1029-3003-O1 is P1';

  -- VOX rule: a VOX (venue-supplied) machine must never be P1 on anything other than expiry or an
  -- empty hero lane. VOXMCC-1005-0201-B0 is the named evidence machine that must not be P1.
  SELECT tier INTO v_tier FROM tmp_v12_cap100 WHERE official_name = 'VOXMCC-1005-0201-B0';
  IF v_tier = 'P1' THEN
    RAISE EXCEPTION 'FAIL VOX-gate: VOXMCC-1005-0201-B0 must not be P1, got P1';
  END IF;
  RAISE NOTICE 'PASS VOX-gate: VOXMCC-1005-0201-B0 is not P1 (tier=%)', COALESCE(v_tier, 'not picked');

  -- Cap rule (F1 fix): with the default cap (8), the TOTAL row count must never exceed 8, and the
  -- non-P1 count must never exceed 8 either. Before the F1 fix, P1 rows were fully exempt from the
  -- cap on top of a full non-P1 allocation, so the total could exceed the cap.
  SELECT COUNT(*) INTO v_count FROM tmp_v12_cap8 WHERE tier <> 'P1';
  IF v_count > 8 THEN
    RAISE EXCEPTION 'FAIL cap: expected at most 8 non-P1 rows, got %', v_count;
  END IF;
  RAISE NOTICE 'PASS cap: % non-P1 rows at cap 8 (<= 8)', v_count;

  SELECT COUNT(*) INTO v_total FROM tmp_v12_cap8;
  IF v_total > 8 THEN
    RAISE EXCEPTION 'FAIL total-cap: expected at most 8 total rows at cap 8, got %', v_total;
  END IF;
  RAISE NOTICE 'PASS total-cap: % total rows at cap 8 (<= 8)', v_total;

  -- P1 is never itself capped: raising the cap must never reduce the number of P1 rows returned.
  SELECT COUNT(*) INTO v_p1_at_8   FROM tmp_v12_cap8   WHERE tier = 'P1';
  SELECT COUNT(*) INTO v_p1_at_100 FROM tmp_v12_cap100 WHERE tier = 'P1';
  IF v_p1_at_8 <> v_p1_at_100 THEN
    RAISE EXCEPTION 'FAIL P1-uncapped: P1 count changed with cap (8 -> %, 100 -> %)', v_p1_at_8, v_p1_at_100;
  END IF;
  RAISE NOTICE 'PASS P1-uncapped: % P1 rows regardless of cap', v_p1_at_8;

  -- Donor rule (F3 tightened): a machine holding a slow-moving, warehouse-out-of-stock SKU with
  -- a real receiver must be tagged cluster_role='donor' with positive visit_value_aed and a
  -- non-empty donor_for, when the cap is raised enough to include it. AMZ-1068-2401-O1 and
  -- VML-1004-0500-O1 are the named evidence machines (Vitamin Well and Red Bull respectively),
  -- reconfirmed live under the stricter F3 rules (primary-WH pickable check, donor stock >= 4,
  -- fleet-wide top-quartile receiver velocity, receiver itself picked or P1/P2).
  SELECT cluster_role, visit_value_aed, donor_for INTO v_role, v_value, v_donor_for
    FROM tmp_v12_cap100 WHERE official_name = 'AMZ-1068-2401-O1';
  IF v_role IS DISTINCT FROM 'donor' OR COALESCE(v_value,0) <= 0 OR v_donor_for IS NULL THEN
    RAISE EXCEPTION 'FAIL donor: AMZ-1068-2401-O1 expected cluster_role=donor with positive value and a receiver list, got role=%, value=%, donor_for=%',
      v_role, v_value, v_donor_for;
  END IF;
  RAISE NOTICE 'PASS donor: AMZ-1068-2401-O1 is a donor worth % AED to %', v_value, v_donor_for;

  SELECT cluster_role, visit_value_aed, donor_for INTO v_role, v_value, v_donor_for
    FROM tmp_v12_cap100 WHERE official_name = 'VML-1004-0500-O1';
  IF v_role IS DISTINCT FROM 'donor' OR COALESCE(v_value,0) <= 0 OR v_donor_for IS NULL THEN
    RAISE EXCEPTION 'FAIL donor: VML-1004-0500-O1 expected cluster_role=donor with positive value and a receiver list, got role=%, value=%, donor_for=%',
      v_role, v_value, v_donor_for;
  END IF;
  RAISE NOTICE 'PASS donor: VML-1004-0500-O1 is a donor worth % AED to %', v_value, v_donor_for;

  -- Cluster rule: once any machine in a building is picked (P1 or P2), every other machine in
  -- that same building with some P2/P3 need becomes a P3 cluster candidate. Tested generically
  -- (not tied to one named building): at least one row must exist tagged cluster_role='cluster'.
  SELECT COUNT(*) INTO v_count FROM tmp_v12_cap100 WHERE cluster_role = 'cluster';
  IF v_count < 1 THEN
    RAISE EXCEPTION 'FAIL cluster: expected at least one cluster-tagged pull-in row, got 0';
  END IF;
  RAISE NOTICE 'PASS cluster: % row(s) tagged cluster_role=cluster', v_count;

  -- Cluster rule (F2 fix): cluster must never fire on a NULL building_id. Before the F2 fix, a
  -- naming-convention fallback code collapsed unrelated machines (GRIT-1022, ADDMIND-1007,
  -- AMZ-1029 among them) onto the same coincidental "00" code and clustered them incorrectly.
  SELECT COUNT(*) INTO v_count FROM tmp_v12_cap100 WHERE cluster_role = 'cluster' AND building_id IS NULL;
  IF v_count > 0 THEN
    RAISE EXCEPTION 'FAIL cluster-null-building: % row(s) tagged cluster with building_id NULL', v_count;
  END IF;
  RAISE NOTICE 'PASS cluster-null-building: no cluster tag on a NULL building_id';

  -- Cluster rule (F8 fix): cluster_role='cluster' must never co-occur with a tier the machine
  -- already independently qualifies for on its own merits (P1 or P2). A machine that is P1/P2 on
  -- its own reasons never needs the building to explain the visit.
  SELECT COUNT(*) INTO v_count FROM tmp_v12_cap100 WHERE cluster_role = 'cluster' AND tier IN ('P1','P2');
  IF v_count > 0 THEN
    RAISE EXCEPTION 'FAIL cluster-not-on-own-tier: % row(s) tagged cluster with an independently-qualifying P1/P2 tier', v_count;
  END IF;
  RAISE NOTICE 'PASS cluster-not-on-own-tier: cluster tag never applied to an independent P1/P2 pick';

  -- Expiry rule (F4 fix): IRIS-1070-0000-O1 has a phantom Activia lot in pod_inventory on shelf
  -- A01, but WEIMI currently confirms Keen Health Dipped Crackers on that lane instead. The
  -- expiry trigger must require WEIMI confirmation (matching pod product, current_stock > 0)
  -- before forcing P1, so this machine must not be P1 on that stale lot.
  SELECT tier INTO v_tier FROM tmp_v12_cap100 WHERE official_name = 'IRIS-1070-0000-O1';
  IF v_tier = 'P1' THEN
    RAISE EXCEPTION 'FAIL phantom-expiry: IRIS-1070-0000-O1 should not be P1 on a phantom lot, got P1';
  END IF;
  RAISE NOTICE 'PASS phantom-expiry: IRIS-1070-0000-O1 tier=%', COALESCE(v_tier, 'not picked');

  -- Fill rule (F5 fix): GRIT-1022-0100-W0 is deliberately half-filled by CS at low revenue
  -- (~AED 6/day). The fill<50% P1 trigger must require velocity >= 0.3/day and daily revenue >=
  -- the fleet 25th percentile, downgrading to P2 otherwise, so this machine must not be P1 on
  -- fill alone.
  SELECT tier INTO v_tier FROM tmp_v12_cap100 WHERE official_name = 'GRIT-1022-0100-W0';
  IF v_tier = 'P1' THEN
    RAISE EXCEPTION 'FAIL fill-gate: GRIT-1022-0100-W0 should not be P1 on low fill alone, got P1';
  END IF;
  RAISE NOTICE 'PASS fill-gate: GRIT-1022-0100-W0 tier=%', COALESCE(v_tier, 'not picked');

  -- Visit value rule (F7 fix): sales_saved_aed is now a real per-lane shortage sum, not a
  -- machine-level revenue/runway approximation that could flatten to zero regardless of urgency.
  -- Every P1 machine whose own daily revenue is above the fleet median must show a positive
  -- visit_value_aed; a P1 visit is never worth zero when the machine makes above-median money.
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY COALESCE(mp.daily_revenue_aed,0)) INTO v_median_rev
    FROM public.v_machine_priority mp
   WHERE mp.include_in_refill = true
     AND mp.machine_status NOT IN ('Warehouse','Inactive')
     AND mp.venue_group IS DISTINCT FROM 'LVLUP';

  SELECT COUNT(*) INTO v_count
    FROM tmp_v12_cap100 p
    JOIN public.v_machine_priority mp ON mp.machine_id = p.machine_id
   WHERE p.tier = 'P1'
     AND COALESCE(mp.daily_revenue_aed,0) > v_median_rev
     AND COALESCE(p.visit_value_aed,0) <= 0;
  IF v_count > 0 THEN
    RAISE EXCEPTION 'FAIL visit-value-above-median: % P1 machine(s) above the fleet median revenue (%) show visit_value_aed <= 0', v_count, v_median_rev;
  END IF;
  RAISE NOTICE 'PASS visit-value-above-median: every P1 machine above median revenue (%) has visit_value_aed > 0', v_median_rev;

  -- Reasons must be present and use no em dashes (hard rule, applies to engine output too).
  SELECT COUNT(*) INTO v_count
    FROM tmp_v12_cap100 p, unnest(p.reasons) r
   WHERE r LIKE '%' || chr(8212) || '%';
  IF v_count > 0 THEN
    RAISE EXCEPTION 'FAIL no-em-dash: % reason string(s) contain an em dash', v_count;
  END IF;
  RAISE NOTICE 'PASS no-em-dash: no reason strings contain an em dash';

  RAISE NOTICE 'ALL selection_v2 CHECKS PASSED';
END $$;

DROP TABLE tmp_v12_cap8;
DROP TABLE tmp_v12_cap100;
