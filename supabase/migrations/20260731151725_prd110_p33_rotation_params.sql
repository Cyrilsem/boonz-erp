-- PRD-110 P3.3 — rotation heartbeat parameters.
--
-- These are PREREQUISITES OF THE FIXTURE, not the object under test: fixture 43's
-- independent recomputation reads them to decide which shelves qualify. Applying them
-- before the fixture is the leg-58 precedent (var_* params before fixture 42), NOT a
-- LAW-1 shortcut -- the RED still isolates propose_rotations_v3 exactly.
--
-- ⛔ EVERY THRESHOLD BELOW IS A POLICY CHOICE, NOT A MEASUREMENT. Unlike the P3.5 capacity
--    params (which model unobserved driver minutes -- S-69), these are judgment calls about
--    what "too slow" and "fast enough to be worth a van trip" mean. CS corrects them with
--    one UPDATE, no migration. The operational question of how much stock to leave behind
--    on a rotated shelf is parked as D-26.

ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS rot_slow_velocity_per_day numeric(10,4) NOT NULL DEFAULT 0.10,
  ADD COLUMN IF NOT EXISTS rot_min_source_qty        integer       NOT NULL DEFAULT 3,
  ADD COLUMN IF NOT EXISTS rot_min_speedup           numeric(10,4) NOT NULL DEFAULT 2.0,
  ADD COLUMN IF NOT EXISTS rot_min_fit_score         numeric(10,4) NOT NULL DEFAULT 2.0,
  ADD COLUMN IF NOT EXISTS rot_max_proposals         integer       NOT NULL DEFAULT 25;

COMMENT ON COLUMN public.refill_policy_params.rot_slow_velocity_per_day IS
'P3.3 POLICY, not measured. A source shelf is a rotation candidate below this units/day. Read from the canonical velocity object v_shelf_instock_velocity_split_v3 ONLY.';
COMMENT ON COLUMN public.refill_policy_params.rot_min_source_qty IS
'P3.3 POLICY, not measured. Below this many units on the shelf, a rotation is not worth a van leg.';
COMMENT ON COLUMN public.refill_policy_params.rot_min_speedup IS
'P3.3 POLICY, not measured. Target velocity must be at least this multiple of source velocity.';
COMMENT ON COLUMN public.refill_policy_params.rot_min_fit_score IS
'P3.3 POLICY, not measured. Minimum fit_score for a proposal to be emitted at all.';
COMMENT ON COLUMN public.refill_policy_params.rot_max_proposals IS
'P3.3 POLICY, not measured. Default cap on proposals emitted per heartbeat run.';

ALTER TABLE public.refill_policy_params
  DROP CONSTRAINT IF EXISTS chk_rot_params_sane;
ALTER TABLE public.refill_policy_params
  ADD CONSTRAINT chk_rot_params_sane CHECK (
    rot_slow_velocity_per_day > 0
    AND rot_min_source_qty     > 0
    AND rot_min_speedup     >= 1.0   -- a "speedup" below 1 would rotate stock to a SLOWER shelf
    AND rot_min_fit_score      > 0
    AND rot_max_proposals      > 0
  );
