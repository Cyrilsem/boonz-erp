-- Blocker 1 (PRD-120 goal, 2026-09-09): root-cause fix for the 2030
-- machines_to_visit rows. INCIDENT_2026-09-08_K1_VISIT_FLOOR_REGRESSION.md
-- contained the symptom (capped approve_refill_plan's visit floor at 21d,
-- 60-day lookback) but explicitly deferred the source fix. This migration
-- is that source fix: every writer that accepts a caller-supplied
-- `p_plan_date` for `machines_to_visit` now refuses anything more than 30
-- days ahead of today.
--
-- Live count when this was written: 72 status IN ('picked','cs_added') rows
-- dated 2030 across 24 machines, ALL `status='cs_added'`, ALL created
-- 2026-08-04 03:09-04:49 UTC for plan_date 2030-11-01..2030-11-04 -- a
-- single ~100-minute exploratory session against `pick_machine_manually`
-- (the only writer of `status='cs_added'` besides `add_machine_to_plan`,
-- which explicitly sets `add_source='operator'` -- these rows carry the
-- column DEFAULT `'picker'`, ruling that one out). This is a SEPARATE
-- population from the 64 `status='picked'` rows already cleaned in the
-- 2026-09-08 incident (created 2026-07-30..08-14, scattered across many
-- dates -- a different exploratory session against `pick_machines_for_refill`).
-- Both writers share the identical defect: no upper bound on `p_plan_date`.
--
-- Fixed in all three functions that can write a future `machines_to_visit`
-- row from a caller-supplied date:
--   - `pick_machine_manually` (writer of the 72 rows this migration exists for)
--   - `add_machine_to_plan` (same defect, not yet exploited live, fixed anyway
--     -- same table, same caller-supplied date, no reason to leave one open)
--   - `pick_machines_for_refill` (writer of the 64 rows from the 2026-09-08
--     incident; already has a *lower*-bound check, `p_plan_date < CURRENT_DATE
--     - 7`; this adds the missing symmetric upper bound)
--
-- 30 days chosen to match the nightly assertion's own threshold
-- (`check_far_future_picked_visits`, already live) and the K1 guard's 60-day
-- lookback -- comfortably past any real routing horizon this fleet plans on.
--
-- Fixture (rolled back): all three functions correctly RAISE on
-- p_plan_date='2030-01-01'; `pick_machine_manually` on a real near-term date
-- (today+5) still succeeds normally (no false positive).
--
-- Cody: approve, Articles 1 (no new write path, same three canonical
-- writers), 4 (validation added, not removed), 12 (forward-only, md5-guarded
-- single-predicate insertions, no other logic touched in any of the three
-- functions).
DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc WHERE proname='pick_machine_manually';
  IF md5(v_def) <> '758aff6ddfc878f5c7404e5a5ffd7f65' THEN RAISE EXCEPTION 'pick_machine_manually drifted (md5 %), refusing blind patch', md5(v_def); END IF;
  v_new := replace(v_def,
E'  IF p_plan_date IS NULL OR p_machine_id IS NULL THEN\n    RAISE EXCEPTION \'p_plan_date and p_machine_id required\';\n  END IF;',
E'  IF p_plan_date IS NULL OR p_machine_id IS NULL THEN\n    RAISE EXCEPTION \'p_plan_date and p_machine_id required\';\n  END IF;\n\n  IF p_plan_date > CURRENT_DATE + 30 THEN\n    RAISE EXCEPTION \'pick_machine_manually: p_plan_date % is more than 30 days ahead -- refusing (use a nearer date; if this is deliberate long-range planning, confirm with CS first)\', p_plan_date;\n  END IF;');
  IF v_new = v_def THEN RAISE EXCEPTION 'pick_machine_manually: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc WHERE proname='add_machine_to_plan';
  IF md5(v_def) <> 'e57f981b0bc30a480e70a437ec7e51d0' THEN RAISE EXCEPTION 'add_machine_to_plan drifted (md5 %), refusing blind patch', md5(v_def); END IF;
  v_new := replace(v_def,
E'  IF p_plan_date IS NULL OR p_machine_id IS NULL THEN\n    RAISE EXCEPTION \'add_machine_to_plan: p_plan_date and p_machine_id required\';\n  END IF;',
E'  IF p_plan_date IS NULL OR p_machine_id IS NULL THEN\n    RAISE EXCEPTION \'add_machine_to_plan: p_plan_date and p_machine_id required\';\n  END IF;\n\n  IF p_plan_date > CURRENT_DATE + 30 THEN\n    RAISE EXCEPTION \'add_machine_to_plan: p_plan_date % is more than 30 days ahead -- refusing (use a nearer date; if this is deliberate long-range planning, confirm with CS first)\', p_plan_date;\n  END IF;');
  IF v_new = v_def THEN RAISE EXCEPTION 'add_machine_to_plan: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc WHERE proname='pick_machines_for_refill';
  IF md5(v_def) <> 'dc90eaa849e31971ec800378982e1c31' THEN RAISE EXCEPTION 'pick_machines_for_refill drifted (md5 %), refusing blind patch', md5(v_def); END IF;
  v_new := replace(v_def,
E'  IF p_plan_date < CURRENT_DATE - 7 THEN\n    RAISE EXCEPTION \'p_plan_date % too far in the past (>7d)\', p_plan_date;\n  END IF;',
E'  IF p_plan_date < CURRENT_DATE - 7 THEN\n    RAISE EXCEPTION \'p_plan_date % too far in the past (>7d)\', p_plan_date;\n  END IF;\n  IF p_plan_date > CURRENT_DATE + 30 THEN\n    RAISE EXCEPTION \'pick_machines_for_refill: p_plan_date % is more than 30 days ahead -- refusing (exploratory/test calls must not write real picked rows this far out)\', p_plan_date;\n  END IF;');
  IF v_new = v_def THEN RAISE EXCEPTION 'pick_machines_for_refill: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;
