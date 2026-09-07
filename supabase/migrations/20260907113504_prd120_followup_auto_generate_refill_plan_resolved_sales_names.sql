-- Close-out follow-up item 2 (3 of 3, handled separately given blast
-- radius -- this is the LIVE refill engine): auto_generate_refill_plan's
-- daily-velocity subquery matched sales_history directly against the raw
-- WEIMI lane name (`LOWER(TRIM(sh.pod_product_name)) =
-- LOWER(TRIM(v_slot.pod_product_name))`, where v_slot.pod_product_name is
-- itself `goods_name_raw` from v_live_shelf_stock). Any sale recorded under
-- an alias/spelling variant of the live name (trailing-space "Sunbites ",
-- the "Freakin..." spellings, etc, per product_name_conventions) never
-- matched -- silently understating v_daily_avg, which directly drives
-- v_target/v_refill_qty, i.e. this bug UNDER-PLANS refill quantity in
-- production today, not just a reporting undercounting.
--
-- Fix: the subquery now sources from v_sales_history_resolved and matches
-- on v_slot.pod_product_id instead of the raw name -- v_live_shelf_stock
-- (the cursor v_slot iterates) ALREADY carries a resolved pod_product_id
-- column (used elsewhere in this same function, e.g. the SWAP/REFILL
-- variant-selection joins), so no new name-resolution CTE was needed here,
-- unlike get_machine_health/get_machine_slots_with_expiry which had to
-- build one. Single md5-guarded surgical replace() on exactly this one
-- subquery; the other ~250 lines of this function (triage, tier logic,
-- SWAP candidate selection, REFILL variant splitting, write_refill_plan
-- call, dispatching mirror) are byte-identical.
--
-- Fixture, live and end-to-end: real machine ACTIVATE-2005-0000-W0,
-- machine_id 4b235d37-c388-478b-8f3f-49d50971fcc1, shelf B06, live product
-- "Soft Drinks Mix" (pod_product_id cc6cc9ca-..., real
-- product_name_conventions alias "Drinks" -> "Soft Drinks Mix"). Isolated
-- subquery comparison (rolled back, real existing sales data): OLD
-- daily_avg = 0.20/day (6 units/30d matching the exact name only); NEW
-- daily_avg = 0.867/day (adds a synthetic 20-unit alias-named sale
-- correctly resolved) -- a 4.3x understatement corrected. Full end-to-end
-- engine call (p_dry_run=true, same machine, a larger synthetic 200-unit
-- alias sale to force a visible action change): BEFORE the patch, shelf B06
-- produced NO plan row at all (current_stock=8 already exceeded the
-- velocity-blind floor target, so the real demand was invisible to the
-- engine, not just under-counted); AFTER, the engine correctly proposes a
-- REFILL action, target=10 (max_stock), sold_7d=48. Confirms the goal's own
-- framing: this bug doesn't just misreport velocity, it makes the live
-- engine silently skip refilling lanes with real, alias-recorded demand.
--
-- Verified live, post-apply: public.auto_generate_refill_plan('all',
-- CURRENT_DATE+1, true, NULL) across the whole fleet (dry run, no writes)
-- returns status='ok'.
--
-- Cody: approve, Article 16 (one canonical sales-identity source, reusing
-- the pod_product_id this function already carries rather than inventing a
-- second resolution path), Article 12 (forward-only, byte-exact patch,
-- verified live post-apply with a real dry-run call before trusting it).
DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='auto_generate_refill_plan' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '6f7d9379d9b6db178619a1a168a6b3b6' THEN RAISE EXCEPTION 'auto_generate_refill_plan drifted (md5 %)', md5(v_def); END IF;

  v_new := replace(v_def,
E'      SELECT COALESCE(SUM(sh.qty)::numeric/30,0) INTO v_daily_avg\n      FROM sales_history sh WHERE sh.machine_id=v_machine.machine_id\n        AND LOWER(TRIM(sh.pod_product_name))=LOWER(TRIM(v_slot.pod_product_name))\n        AND sh.delivery_status IN (\'Success\',\'Successful\')\n        AND sh.transaction_date>=NOW()-INTERVAL \'30 days\';',
E'      SELECT COALESCE(SUM(vshr.qty)::numeric/30,0) INTO v_daily_avg\n      FROM public.v_sales_history_resolved vshr WHERE vshr.machine_id=v_machine.machine_id\n        AND vshr.pod_product_id=v_slot.pod_product_id\n        AND vshr.delivery_status IN (\'Success\',\'Successful\')\n        AND vshr.transaction_date>=NOW()-INTERVAL \'30 days\';');
  IF v_new = v_def THEN RAISE EXCEPTION 'auto_generate_refill_plan: v_daily_avg pattern not found'; END IF;
  v_def := v_new;

  EXECUTE v_def;
END $mig$;
