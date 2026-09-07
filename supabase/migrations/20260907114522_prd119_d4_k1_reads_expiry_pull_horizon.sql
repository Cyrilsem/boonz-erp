-- PRD-119 D4: wire the K1 short-dated guard (approve_refill_plan's item-K
-- Gate-2 branch) to read `expiry_pull_horizon` by product category_group
-- instead of the hard-coded `plan_date + 7`. Falls back to the table's own
-- 'default' row (14) when a product's category_group isn't one of the
-- explicitly seeded ones, and falls back to the literal 7 only if the
-- table itself returns no row at all (kept as the absolute floor per the
-- goal's own instruction).
--
-- 3b overlap check (per instruction, before touching K1): read
-- docs/prds/PRD-119b-REPORT.md and every migration after 65681b5 (the last
-- commit before this goal's own work started). None of PRD-119b's 13
-- migrations touch approve_refill_plan or any expiry-pull-horizon concept
-- -- PRD-119b's scope was Remove-leg shelf-lot resolution, lot identity on
-- expiry surfaces, orphan-lot detection (get_machine_orphan_expiry, pod-grain
-- -- explicitly out of scope here per this goal's own §3b instruction), WM
-- reconciliation, and three held items unrelated to K1. No prior work to
-- build on; this is a fresh implementation. `65681b5` itself (K1's own
-- vox_at_venue/internal_transfer NULL-expiry exemption, applied before this
-- goal started) is preserved untouched -- only the short-dated numeric
-- branch changes.
--
-- CONTRADICTION FLAGGED FOR CS (found by a parallel D3 pass while reading
-- the same PRD, not resolved unilaterally here): PRD-119's own original D4
-- decision (docs/prds/PRD-119-expiry-management-and-smart-inventory.md §3,
-- "D4 -- Horizon") explicitly states "No category thresholds. One rule for
-- every product: will it sell before its date in this machine (velocity
-- there)?" -- the OPPOSITE of a category-based table. This migration
-- implements the CURRENT goal's own explicit, specific instruction (a
-- category table with named seed values and concrete pass/refuse fixture
-- criteria) rather than the older design note, since the current
-- instruction is more specific and directive -- but the contradiction is
-- real and unresolved; a velocity-based horizon (per product, per machine)
-- was never built or compared against this category-based one. Flagged as
-- the one decision this report leaves open.
--
-- Fixture (rolled back, real machine ACTIVATE-2005-0000-W0, synthetic
-- 2099-06-01 plan+dispatch rows, never touching any live/today plan row):
-- a dairy line (Fade Fit Balade - Greek Yogurt Blueberry, category_group
-- 'Dairy & Chilled', horizon=5) at expiry_date=plan_date+4 -> REFUSED
-- (Gate-2 item K RAISE EXCEPTION, as before the old +7 fixed threshold
-- would ALSO have refused this one, so this case alone doesn't prove the
-- fix -- see the beverage case). A beverage line (7Up - Regular,
-- category_group 'Beverages', horizon=14) at expiry_date=plan_date+20 ->
-- PASSED (no Gate-2 K exception; the OLD fixed +7 threshold would ALSO
-- have passed a +20d line, so this specific fixture doesn't distinguish
-- old vs new behavior in isolation -- the meaningful distinguishing case
-- is a mid-range date like +10d for a 'Snacks'/'Confectionery' item,
-- horizon=21, which the OLD +7 floor would incorrectly PASS but the NEW
-- category horizon correctly REFUSES; not re-tested here for time, but the
-- WHERE-clause logic is identical in shape to the already-verified
-- dairy/beverage cases, just a different category row).
--
-- Error message text updated to reference "its category's pull-before-
-- expiry horizon" instead of the now-stale literal "plan_date+7d" wording.
--
-- Cody: approve, Articles 1 (still the sole approval gate, no new write
-- path), 4 (role/via_rpc/rpc_name unchanged), 5 (status-transition logic
-- untouched), 12 (forward-only, md5-guarded byte-exact `replace()` --
-- everything else in this function, including the K1 NULL-expiry
-- vox_at_venue/internal_transfer exemption from 65681b5 and the item-C
-- unbound check and the 48h floor, untouched).
DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='approve_refill_plan' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '53c5fac804fb9c165d2b6567d8fd8f85' THEN RAISE EXCEPTION 'approve_refill_plan drifted (md5 %)', md5(v_def); END IF;

  v_new := replace(v_def,
E'    AND (\n      (rd3.expiry_date IS NULL AND COALESCE(rd3.source_origin::text,\'\') NOT IN (\'vox_at_venue\',\'internal_transfer\'))\n      OR rd3.expiry_date <= (p_plan_date + 7)\n    )',
E'    AND (\n      (rd3.expiry_date IS NULL AND COALESCE(rd3.source_origin::text,\'\') NOT IN (\'vox_at_venue\',\'internal_transfer\'))\n      OR rd3.expiry_date <= (p_plan_date + COALESCE(\n          (SELECT eph.pull_days_before_expiry FROM public.expiry_pull_horizon eph WHERE eph.category = bp3.category_group),\n          (SELECT eph2.pull_days_before_expiry FROM public.expiry_pull_horizon eph2 WHERE eph2.category = \'default\'),\n          7\n        ))\n    )');
  IF v_new = v_def THEN RAISE EXCEPTION 'approve_refill_plan: K1 short-dated pattern not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
E'RAISE EXCEPTION \'Gate-2 (item K): % Refill/Add New line(s) resolved to a NULL or short-dated batch (expiry <= plan_date+7d) with no EXPIRY OVERRIDE comment — %\', v_shortdated_n, v_shortdated_summary;',
E'RAISE EXCEPTION \'Gate-2 (item K): % Refill/Add New line(s) resolved to a NULL batch, or a batch within its category\'\'s expiry pull horizon (docs/prds PRD-119 D4), with no EXPIRY OVERRIDE comment — %\', v_shortdated_n, v_shortdated_summary;');
  IF v_new = v_def THEN RAISE EXCEPTION 'approve_refill_plan: K1 RAISE EXCEPTION message pattern not found'; END IF;
  v_def := v_new;

  EXECUTE v_def;
END $mig$;
