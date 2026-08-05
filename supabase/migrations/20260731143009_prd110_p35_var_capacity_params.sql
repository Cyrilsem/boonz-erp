-- PRD-110 P3.5 · day-capacity model parameters for the value-at-risk picker.
--
-- BUILD-SPEC line 93 names three cost terms the picker must model - "driver-hours, cluster
-- travel, pack time" - and BUILD-SPEC line 5 says v3 feature params live either as columns
-- on refill_policy_params or in a new v3_flags table. Columns here, matching the precedent
-- P2.2 set with base_stock_* and P2.4 with demand_factor_clamp_*: this is a parameter set,
-- not a flag, and refill_policy_params is already the single-row home for exactly that.
--
-- ⛔ THE MACHINE-COUNT CAP IS DELIBERATELY NOT DUPLICATED HERE. pick_urgency_params
-- .driver_capacity (= 8) is the live-calibrated machines-per-day cap the existing Gate-0
-- picker already respects; the VAR picker READS it rather than minting a second, divergeable
-- copy of the same number.
--
-- ⚠️ THE DEFAULTS BELOW ARE MODELLED, NOT MEASURED, AND THAT IS RECORDED ON PURPOSE.
-- trip_events - the only table in the schema that could carry observed per-visit driver
-- timings - holds ZERO rows (probed leg 58). There is therefore no observational basis for
-- driver-hours, travel or pack minutes anywhere in the system today. The numbers below are a
-- transparent standing assumption (8-hour day, 25 min on site, 1.5 min per pack line, 10 min
-- inside a route cluster vs 35 min between clusters), parameterised precisely so CS can
-- correct them with an UPDATE and so a future leg can calibrate them from trip_events once
-- that table is populated. They are NOT presented as evidence. See S-69.

ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS var_driver_day_minutes           numeric NOT NULL DEFAULT 480,
  ADD COLUMN IF NOT EXISTS var_service_minutes_per_machine  numeric NOT NULL DEFAULT 25,
  ADD COLUMN IF NOT EXISTS var_pack_minutes_per_line        numeric NOT NULL DEFAULT 1.5,
  ADD COLUMN IF NOT EXISTS var_travel_minutes_intra_cluster numeric NOT NULL DEFAULT 10,
  ADD COLUMN IF NOT EXISTS var_travel_minutes_inter_cluster numeric NOT NULL DEFAULT 35,
  ADD COLUMN IF NOT EXISTS var_price_lookback_days          integer NOT NULL DEFAULT 90,
  ADD COLUMN IF NOT EXISTS var_default_gap_days             numeric NOT NULL DEFAULT 3;

-- Guardrails: every term is a duration and a duration cannot be negative; a zero-minute day
-- would make the picker select nothing at all and look like a bug rather than a config error.
ALTER TABLE public.refill_policy_params
  DROP CONSTRAINT IF EXISTS chk_var_capacity_params_sane;
ALTER TABLE public.refill_policy_params
  ADD CONSTRAINT chk_var_capacity_params_sane CHECK (
        var_driver_day_minutes            > 0
    AND var_service_minutes_per_machine  >= 0
    AND var_pack_minutes_per_line        >= 0
    AND var_travel_minutes_intra_cluster >= 0
    AND var_travel_minutes_inter_cluster >= var_travel_minutes_intra_cluster
    AND var_price_lookback_days           > 0
    AND var_default_gap_days              > 0
  );

COMMENT ON COLUMN public.refill_policy_params.var_driver_day_minutes IS
  'PRD-110 P3.5. Minutes of driver time a single refill day may consume. MODELLED, not measured (trip_events is empty) - see S-69.';
COMMENT ON COLUMN public.refill_policy_params.var_service_minutes_per_machine IS
  'PRD-110 P3.5. Fixed on-site minutes per machine visit, independent of how many lines it takes. MODELLED, not measured.';
COMMENT ON COLUMN public.refill_policy_params.var_pack_minutes_per_line IS
  'PRD-110 P3.5. The pack-time term of BUILD-SPEC line 93: minutes per refill line, applied to the count of shelves below capacity. MODELLED, not measured.';
COMMENT ON COLUMN public.refill_policy_params.var_travel_minutes_intra_cluster IS
  'PRD-110 P3.5. Travel minutes when the next machine shares the previous one route cluster (v_machine_priority.r_cluster). MODELLED, not measured.';
COMMENT ON COLUMN public.refill_policy_params.var_travel_minutes_inter_cluster IS
  'PRD-110 P3.5. Travel minutes when the next machine is in a different route cluster, and for the first machine of the day. MODELLED, not measured.';
COMMENT ON COLUMN public.refill_policy_params.var_price_lookback_days IS
  'PRD-110 P3.5. Lookback window for the realized unit price (sales_history paid_amount / qty) that converts lost units into lost revenue.';
COMMENT ON COLUMN public.refill_policy_params.var_default_gap_days IS
  'PRD-110 P3.5. Last-resort days-to-next-feasible-visit when a machine has neither a v_machine_base_stock_policy_v3 row nor a machine_service_policy interval. 0 such machines live; the tier is defensive.';
