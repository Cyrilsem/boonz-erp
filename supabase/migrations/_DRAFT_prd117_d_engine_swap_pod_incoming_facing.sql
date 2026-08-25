-- DRAFT — NOT APPLIED. PRD-117 item D (Tier 2, T2.5, prepare-only).
-- ⛔ Live engine version bump (v15_slot_profile -> would become v16). Needs a
-- fixture run WITH CS PRESENT before this is ever applied. Do not run
-- apply_migration against this file without CS in the room.
--
-- Bug: engine_swap_pod sizes every swap-in's qty_in off the OUTGOING product's
-- WEIMI lane max (v_shelf_max_stock keyed by the shelf, which reflects whatever
-- was physically sitting there before — the incumbent/outgoing product), not
-- the INCOMING product's own typical facing. Live examples cited in the PRD:
-- Sunbites sized to 14 units in what was a Perrier lane; Krambals sized to 16
-- units in what was a Vitamin Well lane. Both auto-planned quantities are
-- implausible for those products' own physical form factor.
--
-- Fix (mirrors PRD-116c, migration 20260823215729_prd116c_addnew_edit_cap_uses_incoming_facing.sql,
-- applied 2026-08-23, md5-verified): before sizing qty_in, look up the INCOMING
-- pod product's own fleet-wide max facing from weimi_aisle_snapshots (last 30
-- days, matched by product_name -> pod_products.pod_product_name), and prefer
-- that over the outgoing lane's max_stock_weimi. Fall back to the lane max only
-- when the incoming product has no fleet-wide WEIMI observation (new to fleet).
--
-- NOTE the direction is the OPPOSITE of PRD-116c: PRD-116c used GREATEST
-- (expand a too-small lane cap up to the incoming product's real facing, so a
-- valid driver-entered quantity isn't wrongly refused). Item D needs the engine
-- to CAP DOWN to the incoming product's real facing when the outgoing lane's
-- historical max is not a good sizing signal for a different-shaped product —
-- i.e. prefer the incoming facing over the lane max when both exist, fall back
-- to lane max only when the incoming product has no fleet observation.
--
-- Three sizing sites inside engine_swap_pod need this, all currently keyed
-- SOLELY on v_shelf_max_stock (outgoing/shelf-based):
--   Pass 1  (strategic-tag-driven substitute insert)      -- keyed on tr.pod_in
--   Pass 2a (dead-slot rank_slot_suitability resolution)  -- keyed on v_sub.pod_product_id
--   Pass 2b (driver_recommendation wrong_product rotate)  -- keyed on r.pod_in
-- Pass 3 (broad rotation, value-model swaps) is UNAFFECTED — it already sizes
-- cand_cap from slot_profile_pool keyed on the candidate's own
-- boonz_product_id/shelf_size/lane_family, which is already incoming-facing-based.
--
-- md5 guard: a71aa16530e7641cbbc82234ef76d20b (verified live 2026-08-26 02:xx Dubai)

DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.proname='engine_swap_pod' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'a71aa16530e7641cbbc82234ef76d20b' THEN
    RAISE EXCEPTION 'engine_swap_pod drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;

  -- Pass 1: strategic-tag-driven substitute insert.
  v_new := replace(v_def,
$$    CASE WHEN tr.action_directive='swap_out_m2w' THEN NULL
         ELSE GREATEST(COALESCE((SELECT MAX(sms.max_stock_weimi)::int FROM public.v_shelf_max_stock sms
                                  WHERE sms.shelf_id = tr.shelf_id_final),8)/2,4)::int END,$$,
$$    CASE WHEN tr.action_directive='swap_out_m2w' THEN NULL
         -- PRD-117 item D: cap at the INCOMING pod's own fleet facing, fall back to lane max.
         ELSE GREATEST(COALESCE(
                (SELECT MAX(s.max_stock)::int FROM public.weimi_aisle_snapshots s
                   JOIN public.pod_products pp ON lower(trim(s.product_name))=lower(trim(pp.pod_product_name))
                  WHERE pp.pod_product_id = tr.pod_in AND s.snapshot_date >= CURRENT_DATE - 30),
                (SELECT MAX(sms.max_stock_weimi)::int FROM public.v_shelf_max_stock sms
                  WHERE sms.shelf_id = tr.shelf_id_final),
                8)/2,4)::int END,$$);
  IF v_new = v_def THEN RAISE EXCEPTION 'Pass 1 sizing block not found'; END IF;
  v_def := v_new;

  -- Pass 2a: dead-slot rank_slot_suitability resolution.
  v_new := replace(v_def,
$$      SELECT MAX(sms.max_stock_weimi)::int INTO v_shelf_cap
        FROM public.v_shelf_max_stock sms
       WHERE sms.shelf_id = r.shelf_id;
      UPDATE public.pod_swaps
         SET pod_product_id_in = v_sub.pod_product_id,
             qty_in            = LEAST(
                                   GREATEST(COALESCE(v_shelf_cap, 8), 1),
                                   COALESCE(v_sub.wh_pickable,0)::int),$$,
$$      -- PRD-117 item D: cap at the INCOMING pod's own fleet facing, fall back to lane max.
      SELECT MAX(s.max_stock)::int INTO v_shelf_cap
        FROM public.weimi_aisle_snapshots s
        JOIN public.pod_products pp ON lower(trim(s.product_name))=lower(trim(pp.pod_product_name))
       WHERE pp.pod_product_id = v_sub.pod_product_id AND s.snapshot_date >= CURRENT_DATE - 30;
      IF v_shelf_cap IS NULL THEN
        SELECT MAX(sms.max_stock_weimi)::int INTO v_shelf_cap
          FROM public.v_shelf_max_stock sms
         WHERE sms.shelf_id = r.shelf_id;
      END IF;
      UPDATE public.pod_swaps
         SET pod_product_id_in = v_sub.pod_product_id,
             qty_in            = LEAST(
                                   GREATEST(COALESCE(v_shelf_cap, 8), 1),
                                   COALESCE(v_sub.wh_pickable,0)::int),$$);
  IF v_new = v_def THEN RAISE EXCEPTION 'Pass 2a sizing block not found'; END IF;
  v_def := v_new;

  -- Pass 2b: driver_recommendation wrong_product rotate-out.
  v_new := replace(v_def,
$$      GREATEST(COALESCE((SELECT MAX(sms.max_stock_weimi)::int FROM public.v_shelf_max_stock sms
                          WHERE sms.shelf_id = r.shelf_id),8),1)::int,
      'rotate_out', 'driver_recommendation', NULL::numeric, NULL::uuid,$$,
$$      -- PRD-117 item D: cap at the INCOMING pod's own fleet facing, fall back to lane max.
      GREATEST(COALESCE(
                 (SELECT MAX(s.max_stock)::int FROM public.weimi_aisle_snapshots s
                    JOIN public.pod_products pp ON lower(trim(s.product_name))=lower(trim(pp.pod_product_name))
                   WHERE pp.pod_product_id = r.pod_in AND s.snapshot_date >= CURRENT_DATE - 30),
                 (SELECT MAX(sms.max_stock_weimi)::int FROM public.v_shelf_max_stock sms
                    WHERE sms.shelf_id = r.shelf_id),
                 8),1)::int,
      'rotate_out', 'driver_recommendation', NULL::numeric, NULL::uuid,$$);
  IF v_new = v_def THEN RAISE EXCEPTION 'Pass 2b sizing block not found'; END IF;
  v_def := v_new;

  -- Bump engine_version tag so downstream reasoning/audit rows are distinguishable.
  v_new := replace(v_def, 'v15_slot_profile', 'v16_incoming_facing_cap');
  IF v_new = v_def THEN RAISE EXCEPTION 'engine_version tag not found'; END IF;
  v_def := v_new;

  EXECUTE v_def;
END $mig$;

-- ============================================================================
-- FIXTURE PLAN (run with CS present before this is ever applied to prod):
--
-- 1. Rolled-back-transaction dry run: apply the DO-block inside BEGIN...ROLLBACK,
--    then re-run engine_swap_pod for a recent real p_plan_date that produced the
--    Sunbites/Perrier and Krambals/Vitamin-Well swaps, and diff pod_swaps.qty_in
--    before vs after for every row touched by Pass 1/2a/2b. Confirm:
--      a) Sunbites' new qty_in reflects Sunbites' own fleet-wide WEIMI max_stock
--         (not 14, unless that genuinely IS Sunbites' typical facing elsewhere).
--      b) Krambals' new qty_in reflects Krambals' own fleet-wide max (the IFLY
--         A05 Krambals swap already live tonight via item M's alert is a good
--         real comparison point once it has a few days of its own WEIMI history).
--      c) A product with NO fleet-wide WEIMI history yet (new introduction) still
--         falls back to the old lane-max behavior — qty_in unchanged for those rows.
--      d) Pass 3 (broad rotation) rows are byte-for-byte unchanged (untouched code path).
--   2. Confirm no row's new qty_in exceeds wh_pickable (the LEAST/GREATEST wrapper
--      in Pass 2a already guards this; Pass 1 and 2b have no wh_pickable comparison
--      at insert time today — verify that is pre-existing behavior, not something
--      this patch changes, before treating it as in-scope).
--   3. Full golden-suite run (whichever golden fixture set currently exercises
--      engine_swap_pod) — confirm no unrelated regression, and that engine_version
--      shows 'v16_incoming_facing_cap' in every newly-created row's reasoning.
--   4. Cody review naming Articles 1, 4, 8, 12, 16 before apply. This is a DEFINER
--      write-path change on a canonical writer (pod_swaps) — same review bar as
--      any other engine version bump.
-- ============================================================================
