-- PRD-119 D4 CORRECTION (CS, 2026-09-08): reverts the K1 short-dated guard's
-- category-horizon read (20260907114522_prd119_d4_k1_reads_expiry_pull_horizon.sql)
-- back to a floor, but NOT the original flat `plan_date + 7`. The category
-- horizon proved too aggressive as a LOAD-TIME hard block: a 21-day Snacks/
-- Confectionery horizon refuses loading sellable chocolate onto a weekly-visit
-- machine that will happily sell through it before the next visit, let alone
-- before the batch actually spoils.
--
-- New floor: expiry_date <= plan_date + GREATEST(7, days_to_next_planned_visit + 3).
-- days_to_next_planned_visit is read from `machines_to_visit` (the only real
-- forward visit-schedule table in this schema) -- the machine's own next row
-- with plan_date > p_plan_date and status IN ('picked','cs_added') (i.e.
-- actually scheduled, not dropped/superseded). No future visit known ->
-- Postgres GREATEST ignores the NULL operand and the floor falls back to the
-- bare 7-day base, matching the pre-D4 behavior for a machine with no visible
-- schedule.
--
-- `expiry_pull_horizon` (table + its 6-row seed) is UNTOUCHED by this
-- migration -- kept exactly as seeded. It moves to a different job: ranking
-- the nightly pull list / driver PULL screen by lane velocity vs the
-- category's horizon (see 20260908071722_prd119_d4_correction_pull_candidates_view.sql),
-- honouring PRD-119's own original D4 decision ("category sets the deadline,
-- velocity decides whether the lane clears before it") that the K1-reads-
-- horizon migration itself flagged as an unresolved contradiction. This
-- migration is the CS resolution of that flagged contradiction.
--
-- The 48h absolute floor (`p_plan_date + 2`, no override possible) and the
-- item-C unbound-fill check are untouched -- this migration's `replace()`
-- calls target only the item-K short-dated WHERE clause and its RAISE
-- EXCEPTION message text.
--
-- Fixture (rolled back, synthetic 2099-06-01 plan+dispatch rows on a real
-- machine, ACTIVATE-2005-0000-W0 -- no live/today plan row touched):
--   1. dairy (Fade Fit Balade - Greek Yogurt Blueberry) at expiry=plan_date+4,
--      any visit cadence -> REFUSED (4 <= GREATEST(7,...) always, since the
--      floor's minimum is 7).
--   2. chocolate (Twix - Regular, Confectionery, horizon=21 in
--      expiry_pull_horizon but NOT READ by this guard) at expiry=plan_date+20,
--      next planned visit in 7 days -> floor = GREATEST(7, 7+3) = 10 ->
--      20 > 10 -> PASSED.
--   3. Same chocolate line, no future visit known at all (machines_to_visit
--      row removed) -> floor falls back to the bare 7 -> 20 > 7 -> PASSED.
-- All three passed on the first run.
--
-- Cody: approve, Articles 1 (still the sole approval gate, no new write
-- path), 4 (role/via_rpc/rpc_name unchanged), 5 (status-transition logic
-- untouched), 12 (forward-only, md5-guarded byte-exact `replace()` -- item C's
-- unbound check, the K1 NULL-expiry vox_at_venue/internal_transfer exemption,
-- and the 48h floor are byte-identical to the prior live function).
DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='approve_refill_plan' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'eddf61c25aa05a2a534e0229617cb299' THEN RAISE EXCEPTION 'approve_refill_plan drifted (md5 %), refusing blind patch', md5(v_def); END IF;

  v_new := replace(v_def,
E'    AND (\n      (rd3.expiry_date IS NULL AND COALESCE(rd3.source_origin::text,\'\') NOT IN (\'vox_at_venue\',\'internal_transfer\'))\n      OR rd3.expiry_date <= (p_plan_date + COALESCE(\n          (SELECT eph.pull_days_before_expiry FROM public.expiry_pull_horizon eph WHERE eph.category = bp3.category_group),\n          (SELECT eph2.pull_days_before_expiry FROM public.expiry_pull_horizon eph2 WHERE eph2.category = \'default\'),\n          7\n        ))\n    )',
E'    AND (\n      (rd3.expiry_date IS NULL AND COALESCE(rd3.source_origin::text,\'\') NOT IN (\'vox_at_venue\',\'internal_transfer\'))\n      OR rd3.expiry_date <= (p_plan_date + GREATEST(7,\n          (SELECT MIN(mtv.plan_date) - p_plan_date\n             FROM public.machines_to_visit mtv\n            WHERE mtv.machine_id = rd3.machine_id\n              AND mtv.plan_date > p_plan_date\n              AND mtv.status IN (\'picked\',\'cs_added\')) + 3\n        ))\n    )');
  IF v_new = v_def THEN RAISE EXCEPTION 'approve_refill_plan: D4 category-horizon WHERE-clause pattern not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
E'RAISE EXCEPTION \'Gate-2 (item K): % Refill/Add New line(s) resolved to a NULL batch, or a batch within its category\'\'s expiry pull horizon (docs/prds PRD-119 D4), with no EXPIRY OVERRIDE comment — %\', v_shortdated_n, v_shortdated_summary;',
E'RAISE EXCEPTION \'Gate-2 (item K): % Refill/Add New line(s) resolved to a NULL batch, or a batch within the 7-day / next-visit+3d floor (docs/prds PRD-119 D4 correction), with no EXPIRY OVERRIDE comment — %\', v_shortdated_n, v_shortdated_summary;');
  IF v_new = v_def THEN RAISE EXCEPTION 'approve_refill_plan: RAISE EXCEPTION message pattern not found'; END IF;
  v_def := v_new;

  EXECUTE v_def;
END $mig$;
