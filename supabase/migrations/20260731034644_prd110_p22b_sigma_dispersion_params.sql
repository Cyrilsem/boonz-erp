-- PRD-110 P2.2b - sigma (dispersion) parameters for the base-stock target S = mu*L + z*sigma*sqrt(L).
-- INERT on apply: nothing reads these columns until v_pod_demand_dispersion_v3 (P2.2b) lands and
-- engine_add_pod_v3 is wired (P2.2c). Same shape as the P2.2a base_stock_* params: CS-flippable
-- with a plain UPDATE, no migration required.
--
-- Defaults are MEASURED, not invented (2026-07-31, leg 39, in-scope pod-bound fleet):
--   lookback 60d          -> 469 canonical (machine, pod) pairs across 31 machines
--   min_days 14           -> 163 pairs qualify for their own phi; 306 fall to a prior (the
--                            MAJORITY path, exactly as S-44 predicted)
--   phi_floor 0           -> deliberately INERT. The measured phi is used as-is. A Poisson floor
--                            (phi >= 1) is a CS modelling choice, parked as D-15, one UPDATE away.
--   prior_precedence      -> 'pod_then_fleet': pooled per-pod phi (43 pods qualify) before the
--                            fleet median (0.690066 today).

ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS base_stock_sigma_lookback_days    integer NOT NULL DEFAULT 60,
  ADD COLUMN IF NOT EXISTS base_stock_sigma_min_days         integer NOT NULL DEFAULT 14,
  ADD COLUMN IF NOT EXISTS base_stock_sigma_phi_floor        numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS base_stock_sigma_prior_precedence text    NOT NULL DEFAULT 'pod_then_fleet';

ALTER TABLE public.refill_policy_params
  ADD CONSTRAINT chk_base_stock_sigma_ranges
  CHECK (base_stock_sigma_lookback_days > 0
     AND base_stock_sigma_min_days >= 2
     AND base_stock_sigma_phi_floor >= 0);

ALTER TABLE public.refill_policy_params
  ADD CONSTRAINT chk_base_stock_sigma_prior_precedence
  CHECK (base_stock_sigma_prior_precedence = ANY (ARRAY['pod_then_fleet'::text, 'fleet_only'::text]));

COMMENT ON COLUMN public.refill_policy_params.base_stock_sigma_lookback_days IS
  'PRD-110 P2.2b. Days of sales history used to estimate the dispersion ratio phi = sigma_obs/sqrt(mu_obs). Longer than the 30d velocity window on purpose: phi is scale-free, so a wider window buys precision without biasing the level.';
COMMENT ON COLUMN public.refill_policy_params.base_stock_sigma_min_days IS
  'PRD-110 P2.2b. Minimum distinct sale-days a (machine, pod) pair needs before its OWN phi is trusted. Below this the pair falls to the pod prior, then the fleet prior. stddev_samp needs >= 2 by definition; 14 is the S-44 evidence threshold.';
COMMENT ON COLUMN public.refill_policy_params.base_stock_sigma_phi_floor IS
  'PRD-110 P2.2b. Lower clamp on the resolved phi. Default 0 = INERT (measured phi used as-is). Raising it to 1.0 imposes a Poisson floor so no shelf can be sized with zero safety stock. Parked as D-15 - not invented by the build.';
COMMENT ON COLUMN public.refill_policy_params.base_stock_sigma_prior_precedence IS
  'PRD-110 P2.2b. How a pair with insufficient own history gets its phi: pod_then_fleet (default - pooled median phi for that canonical pod, else the fleet median) or fleet_only (skip the pod prior).';
