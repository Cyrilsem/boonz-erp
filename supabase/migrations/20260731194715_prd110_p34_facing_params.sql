-- PRD-110 P3.4 — facing rightsizing parameters.
--
-- Prerequisites of fixture 48's independent recomputation, applied before it exactly as
-- the P3.3 rotation params were applied before fixture 43 (leg-58 precedent). The RED
-- still isolates propose_facing_changes_v3.
--
-- ⛔ EVERY THRESHOLD IS A POLICY CHOICE, NOT A MEASUREMENT. "Too little revenue per lane"
--    is a judgment about shelf economics, not an observation. CS corrects with one UPDATE.

ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS fac_min_facings_to_shrink   integer       NOT NULL DEFAULT 2,
  ADD COLUMN IF NOT EXISTS fac_shrink_ratio            numeric(10,4) NOT NULL DEFAULT 0.50,
  ADD COLUMN IF NOT EXISTS fac_expand_ratio            numeric(10,4) NOT NULL DEFAULT 1.75,
  ADD COLUMN IF NOT EXISTS fac_starvation_ratio        numeric(10,4) NOT NULL DEFAULT 1.25,
  ADD COLUMN IF NOT EXISTS fac_min_peer_families       integer       NOT NULL DEFAULT 4,
  ADD COLUMN IF NOT EXISTS fac_min_abs_rev_gap_aed     numeric(10,4) NOT NULL DEFAULT 0.15,
  ADD COLUMN IF NOT EXISTS fac_price_lookback_days     integer       NOT NULL DEFAULT 90,
  ADD COLUMN IF NOT EXISTS fac_max_proposals           integer       NOT NULL DEFAULT 25;

COMMENT ON COLUMN public.refill_policy_params.fac_min_facings_to_shrink IS
'P3.4 POLICY. A family must hold at least this many lanes before shrinking is even considered. At 2 the last lane can never be taken by this engine: shrink always leaves >= 1 facing.';
COMMENT ON COLUMN public.refill_policy_params.fac_shrink_ratio IS
'P3.4 POLICY. Shrink when rev/facing/day POTENTIAL is below this multiple of the machine peer median. Read POTENTIAL (in-stock rate), never REALIZED: punishing a lane for being empty is punishing the refill, not the assortment.';
COMMENT ON COLUMN public.refill_policy_params.fac_expand_ratio IS
'P3.4 POLICY. Expand when rev/facing/day POTENTIAL is above this multiple of the machine peer median AND the family is starved.';
COMMENT ON COLUMN public.refill_policy_params.fac_starvation_ratio IS
'P3.4 POLICY. velocity_instock / velocity_calendar above this means the family sells materially faster when actually stocked than its calendar average shows - i.e. it is running dry. This is the ONLY admissible expansion evidence: high revenue alone justifies restocking, not another lane.';
COMMENT ON COLUMN public.refill_policy_params.fac_min_peer_families IS
'P3.4 POLICY. A machine needs at least this many priced+measured families before its median is a usable benchmark. Below it, the machine is skipped and the reason recorded - a median of two lanes is not a peer group.';
COMMENT ON COLUMN public.refill_policy_params.fac_min_abs_rev_gap_aed IS
'P3.4 POLICY. Absolute AED/facing/day floor on the gap to the median. Guards the low-revenue regime where a ratio test fires on rounding: 0.02 vs 0.05 AED/day is a 2.5x ratio and a 0.03 AED decision.';
COMMENT ON COLUMN public.refill_policy_params.fac_price_lookback_days IS
'P3.4. Realized-price lookback. Mirrors var_price_lookback_days; the two are deliberately separate dials on the same cascade.';
COMMENT ON COLUMN public.refill_policy_params.fac_max_proposals IS
'P3.4 POLICY. Cap on proposals emitted per run.';

ALTER TABLE public.refill_policy_params
  DROP CONSTRAINT IF EXISTS chk_fac_params_sane;
ALTER TABLE public.refill_policy_params
  ADD CONSTRAINT chk_fac_params_sane CHECK (
    fac_min_facings_to_shrink >= 2      -- at 1 a shrink would empty the lane entirely
    AND fac_shrink_ratio      > 0
    AND fac_shrink_ratio      < 1.0     -- shrinking an ABOVE-median lane is incoherent
    AND fac_expand_ratio      > 1.0     -- expanding a BELOW-median lane is incoherent
    AND fac_starvation_ratio  >= 1.0    -- in-stock rate is >= calendar rate by construction
    AND fac_min_peer_families >= 2
    AND fac_min_abs_rev_gap_aed >= 0
    AND fac_price_lookback_days > 0
    AND fac_max_proposals     > 0
  );
