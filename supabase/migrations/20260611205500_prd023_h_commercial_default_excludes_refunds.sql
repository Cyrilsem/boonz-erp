-- PRD-023h: refunds are not payment defaults.
-- Applied to live as migration prd023_h_commercial_default_excludes_refunds (2026-06-11).
-- default_amount in get_vox_commercial_report now assesses the gap against what was
-- originally captured BEFORE the deliberate refund:
--   GREATEST(total_amount - (adyen_captured_net + refund_returned + cash_recovered), 0)
-- Refunds remain reported separately (waterfall.refund_amount + per-txn refunded_amount).
-- Effect (Mercato+Mirdif): 06Feb-01Jun default 1,361.90/1.43%/37disc -> 1,076.90/1.13%/32disc;
-- 06Feb-30Apr 550.60/1.49% -> 435.60/1.18%. Money waterfall (net revenue, shares, dues) unchanged.
-- Guarded in-place patch: fails loudly if the function body drifted.
DO $$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_vox_commercial_report';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'get_vox_commercial_report not found';
  END IF;
  -- Idempotent: skip if already patched.
  IF position('(adyen_captured_net + refund_returned + cash_recovered)' IN v_def) > 0 THEN
    RAISE NOTICE 'prd023_h already applied, skipping';
    RETURN;
  END IF;
  IF position('GREATEST(total_amount - (adyen_captured_net + cash_recovered), 0)' IN v_def) = 0 THEN
    RAISE EXCEPTION 'expected default_amount expression not found; function body drifted, manual review required';
  END IF;

  v_def := replace(v_def,
    'GREATEST(total_amount - (adyen_captured_net + cash_recovered), 0)',
    'GREATEST(total_amount - (adyen_captured_net + refund_returned + cash_recovered), 0)');

  EXECUTE v_def;
END $$;
