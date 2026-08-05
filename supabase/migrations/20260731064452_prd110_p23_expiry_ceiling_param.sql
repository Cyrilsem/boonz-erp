-- PRD-110 P2.3 - the expiry ceiling's safety factor, as a param not a literal.
-- Mirrors v19's hardcoded 0.8 spoilage cap (S <= mu * shelf_life * 0.8) so that v3 starts
-- calibrated identically to the engine it shadows, and so the factor can be tuned without a
-- function replace. Cody: Article 14 N/A (column on config, not a snapshot table).
ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS base_stock_expiry_safety_factor numeric NOT NULL DEFAULT 0.80;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.refill_policy_params'::regclass
                    AND conname  = 'rpp_base_stock_expiry_safety_factor_chk') THEN
    ALTER TABLE public.refill_policy_params
      ADD CONSTRAINT rpp_base_stock_expiry_safety_factor_chk
      CHECK (base_stock_expiry_safety_factor > 0 AND base_stock_expiry_safety_factor <= 1);
  END IF;
END $$;

COMMENT ON COLUMN public.refill_policy_params.base_stock_expiry_safety_factor IS
  'PRD-110 P2.3. Safety factor on the expiry ceiling: ceiling_units = floor(days_to_expiry * '
  'sell_rate * this). 0.80 = v19''s hardcoded spoilage cap, so v3 starts calibrated to the engine '
  'it shadows. Consumed ONLY by engine_add_pod_v3 (shadow). Raising it toward 1.0 stocks closer to '
  'the expiry date; it can never lift a quantity above the min-facing floor or fill_to_cap.';

-- Post-guard: exactly one config row, and it carries the v19-matching default.
DO $$
DECLARE v_n int; v_f numeric;
BEGIN
  SELECT count(*), min(base_stock_expiry_safety_factor) INTO v_n, v_f
    FROM public.refill_policy_params;
  IF v_n <> 1 OR v_f IS DISTINCT FROM 0.80 THEN
    RAISE EXCEPTION 'P2.3 param guard: expected 1 row at 0.80, got % row(s) at %', v_n, v_f;
  END IF;
END $$;
