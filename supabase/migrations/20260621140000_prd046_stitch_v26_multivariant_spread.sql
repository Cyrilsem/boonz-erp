-- PRD-046: stitch_pod_to_boonz v25_wh_pickable_unified -> v26_multivariant_spread.
-- Fixes the multi-variant SKU collapse (e.g. AMZ-1029 A07 "Chocolate Bar" planned 17 stitched to a
-- single "Snickers 17"). Root cause: is_residual_variant gated the distribution to on-shelf-only when
-- an on-shelf variant had WH stock (has_onshelf_wh), so pod_qty concentrated on one SKU.
--
-- Forward CREATE OR REPLACE. ONLY the Stage-3 distribution CTEs change (per the hard-safety rule);
-- everything else byte-identical. Two surgical edits + a version bump:
--   1) pull_resid.is_residual_variant: drop the `WHEN has_onshelf_wh THEN on_shelf` collapse branch so
--      the residual set is ALL WH-available active variants (ELSE wh_avail_variant>0). norm_split then
--      spreads pod_qty across them; zero-WH variants drop out of the denominator and redistribute.
--      Largest-remainder (pull_base/pull_slot_rem/pull_ranked/pull_target) and conservation are kept.
--   2) pull_ranked ORDER BY: add on_shelf as a leftover-unit tie-break (on-shelf gets remainder
--      preference -> a min-1 nudge in practice), never a collapse.
-- Single-variant (100%) still resolves to one SKU (its norm_split=1). Driver overlay, pin logic, the
-- qty>0 emit filter, and ADD/SWAP/FINALIZE are untouched.

DO $do$
DECLARE v text;
BEGIN
  SELECT pg_get_functiondef('public.stitch_pod_to_boonz(date,boolean)'::regprocedure) INTO v;

  -- 1) spread across all WH-available variants (remove the on-shelf-only collapse line)
  v := replace(v,
    E'               WHEN has_onshelf_wh THEN COALESCE(on_shelf,false)\n               ELSE COALESCE(wh_avail_variant,0) > 0',
    E'               ELSE COALESCE(wh_avail_variant,0) > 0');

  -- 2) on-shelf tie-break for leftover units in the REFILL distribution ranking
  v := replace(v,
    E'      ORDER BY remainder_score DESC, norm_split DESC, boonz_product_id\n    ) AS rank_remainder FROM pull_slot_rem psr',
    E'      ORDER BY remainder_score DESC, (COALESCE(on_shelf,false)) DESC, norm_split DESC, boonz_product_id\n    ) AS rank_remainder FROM pull_slot_rem psr');

  -- 3) version bump
  v := replace(v, 'v25_wh_pickable_unified', 'v26_multivariant_spread');

  -- drift guards
  IF position('has_onshelf_wh THEN COALESCE(on_shelf,false)' in v) > 0 THEN
    RAISE EXCEPTION 'PRD-046: collapse line still present after rewrite.';
  END IF;
  IF position('(COALESCE(on_shelf,false)) DESC, norm_split DESC' in v) = 0 THEN
    RAISE EXCEPTION 'PRD-046: on-shelf tie-break not injected (pull_ranked anchor drifted).';
  END IF;
  IF position('v25_wh_pickable_unified' in v) > 0 THEN
    RAISE EXCEPTION 'PRD-046: v25 version string remains after bump.';
  END IF;

  EXECUTE v;
END $do$;
