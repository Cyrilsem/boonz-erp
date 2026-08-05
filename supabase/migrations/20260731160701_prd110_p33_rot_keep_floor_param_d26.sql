-- PRD-110 P3.3 / D-26 — rotation keep-floor parameter.
--
-- ⭐ CS DECISION, 2026-07-31 ~20:15 Dubai (Cowork session), recorded in PRD-110-PARKING-LOT.md:
--    "Rotation keep-floor = 2 units." propose_rotations_v3 must move
--    LEAST(source_stock - rot_keep_floor, target_headroom), not LEAST(source_stock, headroom).
--
-- RATIONALE (CS's, recorded verbatim in the parking lot): the source shelf stays merchandised
-- and avoids the PRD-073b `hero_shelf_empty` urgency penalty, while the bulk of slow-moving
-- stock still relocates to where it actually sells.
--
-- ⛔ POLICY, NOT A MEASUREMENT — like every other rot_* param. CHECK is >= 0 (not > 0) precisely
--    so CS can restore full-strip behaviour for genuinely dead product with one UPDATE and no
--    migration, exactly as the decision text says.

ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS rot_keep_floor integer NOT NULL DEFAULT 2;

COMMENT ON COLUMN public.refill_policy_params.rot_keep_floor IS
'P3.3 POLICY, not measured (CS decision D-26, 2026-07-31). Units a rotation LEAVES BEHIND on the source shelf so it stays merchandised (PRD-073b hero_shelf_empty). 0 = strip the shelf completely.';

-- Extend the existing sanity CHECK rather than adding a second one, so the rot_* contract
-- stays readable as a single predicate.
ALTER TABLE public.refill_policy_params
  DROP CONSTRAINT IF EXISTS chk_rot_params_sane;
ALTER TABLE public.refill_policy_params
  ADD CONSTRAINT chk_rot_params_sane CHECK (
    rot_slow_velocity_per_day > 0
    AND rot_min_source_qty     > 0
    AND rot_min_speedup     >= 1.0   -- a "speedup" below 1 would rotate stock to a SLOWER shelf
    AND rot_min_fit_score      > 0
    AND rot_max_proposals      > 0
    AND rot_keep_floor        >= 0   -- D-26: 0 is legal and means "strip it"
  );
