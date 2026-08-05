-- PRD-110 P4.4 migration A - pre-auth cap dials for create_spot_purchase_v3.
-- Design D-D (leg 90): the cap ships ENFORCED-AS-'warn', not parked as a no-op.
-- An invisible cap is indistinguishable from no cap; 'warn' makes every breach
-- visible from day one at zero ops risk, mirroring preflight_enforcement.
-- The parked DECISIONS-READY item is the flip to 'block', not the cap's existence.
-- refill_policy_params is a ONE-ROW WIDE table (81 columns before this migration).

ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS spot_buy_price_cap_aed numeric NOT NULL DEFAULT 15;

ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS spot_buy_cap_enforcement text NOT NULL DEFAULT 'warn';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.refill_policy_params'::regclass
       AND conname  = 'refill_policy_params_spot_buy_cap_enforcement_check'
  ) THEN
    ALTER TABLE public.refill_policy_params
      ADD CONSTRAINT refill_policy_params_spot_buy_cap_enforcement_check
      CHECK (spot_buy_cap_enforcement IN ('off','warn','block'));
  END IF;
END $$;

COMMENT ON COLUMN public.refill_policy_params.spot_buy_price_cap_aed IS
  'PRD-110 P4.4: per-unit AED pre-authorisation cap for create_spot_purchase_v3. Default 15 (snacks/drinks).';
COMMENT ON COLUMN public.refill_policy_params.spot_buy_cap_enforcement IS
  'PRD-110 P4.4: off | warn | block. Ships ''warn'' (D-D). The flip to ''block'' is a parked CS decision.';

DO $$
DECLARE
  v_cap  numeric;
  v_enf  text;
  v_cols int;
BEGIN
  SELECT spot_buy_price_cap_aed, spot_buy_cap_enforcement INTO v_cap, v_enf
    FROM public.refill_policy_params LIMIT 1;

  IF v_cap IS DISTINCT FROM 15 THEN
    RAISE EXCEPTION 'P4.4 A FAILED: spot_buy_price_cap_aed is %, expected 15', v_cap;
  END IF;
  IF v_enf IS DISTINCT FROM 'warn' THEN
    RAISE EXCEPTION 'P4.4 A FAILED: spot_buy_cap_enforcement is %, expected warn', v_enf;
  END IF;

  SELECT count(*) INTO v_cols FROM information_schema.columns
   WHERE table_name = 'refill_policy_params';
  IF v_cols <> 83 THEN
    RAISE EXCEPTION 'P4.4 A FAILED: refill_policy_params has % columns, expected 83 (81+2)', v_cols;
  END IF;

  -- the CHECK must actually be able to fire
  BEGIN
    UPDATE public.refill_policy_params SET spot_buy_cap_enforcement = 'nonsense';
    RAISE EXCEPTION 'P4.4 A FAILED: CHECK did not fire on an invalid enforcement value';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  RAISE NOTICE 'P4.4 A OK: cap=% enforcement=% cols=%', v_cap, v_enf, v_cols;
END $$;
