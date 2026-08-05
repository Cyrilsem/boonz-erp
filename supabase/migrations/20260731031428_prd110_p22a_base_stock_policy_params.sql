-- PRD-110 P2.2a migration 1/3 — base-stock policy parameters.
-- ADDITIVE and INERT: nothing reads these columns yet. The resolver view (migration 3/3)
-- is the first consumer, and the engine wiring is a later leg (P2.2c).
--
-- base_stock_default_interval_days = 5.5 is the MEASURED fleet median-of-medians of the
-- inter-visit gap over 120 days, derived on the CANONICAL visit vocabulary (see migration
-- 3/3). It is NOT a guess and NOT the 7 that a dispatch-only derivation produces: counting
-- manual refills as visits (which the canonical clock does) shortens the fleet median from
-- 6.75 to 5.50. Range across machines 2.0 .. 20.5 over 30 machines.
--
-- base_stock_interval_precedence defaults to 'observed_first' on the S-43 evidence:
-- machine_service_policy.trip_interval_days is a 2026-06-21 seed_velocity_tertile seed that
-- overstates measured cadence on ALL 30 machines that have one (mean 3.67x). Parked as D-14
-- so CS can flip to 'policy_first' without a migration.

ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS base_stock_lead_days              numeric NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS base_stock_default_interval_days  numeric NOT NULL DEFAULT 5.5,
  ADD COLUMN IF NOT EXISTS base_stock_min_gaps               integer NOT NULL DEFAULT 2,
  ADD COLUMN IF NOT EXISTS base_stock_cadence_lookback_days  integer NOT NULL DEFAULT 120,
  ADD COLUMN IF NOT EXISTS base_stock_max_horizon_days       numeric NOT NULL DEFAULT 30,
  ADD COLUMN IF NOT EXISTS base_stock_interval_precedence    text    NOT NULL DEFAULT 'observed_first';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'chk_base_stock_interval_precedence'
                    AND conrelid = 'public.refill_policy_params'::regclass) THEN
    ALTER TABLE public.refill_policy_params
      ADD CONSTRAINT chk_base_stock_interval_precedence
      CHECK (base_stock_interval_precedence IN ('observed_first','policy_first'));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'chk_base_stock_ranges'
                    AND conrelid = 'public.refill_policy_params'::regclass) THEN
    ALTER TABLE public.refill_policy_params
      ADD CONSTRAINT chk_base_stock_ranges
      CHECK (base_stock_lead_days >= 0
         AND base_stock_default_interval_days > 0
         AND base_stock_min_gaps >= 1
         AND base_stock_cadence_lookback_days > 0
         AND base_stock_max_horizon_days >= 1);
  END IF;
END $$;

COMMENT ON COLUMN public.refill_policy_params.base_stock_lead_days IS
  'PRD-110 P2.2: lead time L added to the visit interval when sizing S = mu*H + z*sigma*sqrt(H).';
COMMENT ON COLUMN public.refill_policy_params.base_stock_default_interval_days IS
  'PRD-110 P2.2: tier-3 fallback interval. 5.5 = measured fleet median-of-medians (120d, canonical visit vocabulary). Applies only to machines with neither a service policy nor >= base_stock_min_gaps observed gaps.';
COMMENT ON COLUMN public.refill_policy_params.base_stock_min_gaps IS
  'PRD-110 P2.2: minimum observed inter-visit gaps before the observed cadence is trusted.';
COMMENT ON COLUMN public.refill_policy_params.base_stock_cadence_lookback_days IS
  'PRD-110 P2.2: lookback window for observed cadence.';
COMMENT ON COLUMN public.refill_policy_params.base_stock_max_horizon_days IS
  'PRD-110 P2.2: hard ceiling on horizon_days, so a pathological cadence cannot inflate S without bound.';
COMMENT ON COLUMN public.refill_policy_params.base_stock_interval_precedence IS
  'PRD-110 P2.2 / D-14: observed_first (default, S-43 evidence) or policy_first (honour the seeded trip_interval_days). CS-flippable without a migration.';
