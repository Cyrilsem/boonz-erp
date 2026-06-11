-- PRD-023g: refuse cash recoveries exceeding the transaction's remaining gap
-- (remaining = txn_total - (settled - refunded) - cash already recovered).
-- Prevents double-press duplicates at the source.
CREATE OR REPLACE FUNCTION public.record_cash_recovery(p_merchant_reference text, p_recovered_amount numeric, p_reason text, p_collected_by text DEFAULT NULL::text, p_tender_method text DEFAULT 'cash'::text, p_recovered_at timestamp with time zone DEFAULT now(), p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id            uuid;
  v_machine_id         uuid;
  v_machine_name       text;
  v_recovery_id        uuid;
  v_txn_total          numeric;
  v_adyen_captured     numeric;
  v_adyen_refunded     numeric;
  v_total_cash         numeric;
  v_remaining_gap      numeric;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','record_cash_recovery',true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id
      AND up.role IN ('operator_admin','superadmin','warehouse','field_staff')
  ) THEN
    RAISE EXCEPTION 'record_cash_recovery: caller lacks permission (read-only account)';
  END IF;

  IF p_merchant_reference IS NULL OR LENGTH(TRIM(p_merchant_reference)) = 0 THEN
    RAISE EXCEPTION 'merchant_reference is required';
  END IF;
  IF p_recovered_amount IS NULL OR p_recovered_amount <= 0 THEN
    RAISE EXCEPTION 'recovered_amount must be > 0 (got %)', p_recovered_amount;
  END IF;
  IF p_reason IS NULL OR LENGTH(TRIM(p_reason)) < 5 THEN
    RAISE EXCEPTION 'reason is required (min 5 chars)';
  END IF;
  IF p_tender_method NOT IN ('cash','card_retry','bank_transfer','voucher','other') THEN
    RAISE EXCEPTION 'tender_method must be one of: cash, card_retry, bank_transfer, voucher, other (got %)', p_tender_method;
  END IF;

  SELECT sh.machine_id, m.official_name
    INTO v_machine_id, v_machine_name
  FROM sales_history sh
  JOIN machines m ON m.machine_id = sh.machine_id
  WHERE regexp_replace(sh.internal_txn_sn, '_\d+$', '') = p_merchant_reference
  LIMIT 1;

  IF v_machine_id IS NULL THEN
    RAISE EXCEPTION 'merchant_reference % not found in sales_history', p_merchant_reference;
  END IF;

  -- OVER-RECOVERY GUARD (pre-insert): cash cannot exceed the remaining net gap
  SELECT COALESCE(SUM(total_amount), 0) INTO v_txn_total
  FROM sales_history
  WHERE regexp_replace(internal_txn_sn, '_\d+$', '') = p_merchant_reference;

  SELECT COALESCE(SUM(captured_amount_value) FILTER (WHERE status = 'SettledBulk'), 0),
         COALESCE(SUM(captured_amount_value) FILTER (WHERE status = 'RefundedBulk'), 0)
    INTO v_adyen_captured, v_adyen_refunded
  FROM adyen_transactions
  WHERE merchant_reference = p_merchant_reference;

  SELECT COALESCE(SUM(recovered_amount), 0) INTO v_total_cash
  FROM cash_recovery_log
  WHERE merchant_reference = p_merchant_reference;

  v_remaining_gap := v_txn_total - (v_adyen_captured - v_adyen_refunded) - v_total_cash;

  IF p_recovered_amount > v_remaining_gap + 0.01 THEN
    RAISE EXCEPTION 'record_cash_recovery: % exceeds remaining gap of % for ref % (txn % | settled % | refunded % | cash already %). Already fully recovered?',
      p_recovered_amount, ROUND(GREATEST(v_remaining_gap,0),2), p_merchant_reference,
      v_txn_total, v_adyen_captured, v_adyen_refunded, v_total_cash;
  END IF;

  INSERT INTO cash_recovery_log (
    merchant_reference, machine_id, recovered_amount, tender_method,
    recovered_at, collected_by, reason, notes, created_by
  ) VALUES (
    p_merchant_reference, v_machine_id, p_recovered_amount, p_tender_method,
    p_recovered_at, p_collected_by, p_reason, p_notes, auth.uid()
  )
  RETURNING recovery_id INTO v_recovery_id;

  v_total_cash := v_total_cash + p_recovered_amount;
  v_remaining_gap := GREATEST(v_txn_total - (v_adyen_captured - v_adyen_refunded) - v_total_cash, 0);

  RETURN jsonb_build_object(
    'ok', true,
    'recovery_id', v_recovery_id,
    'merchant_reference', p_merchant_reference,
    'machine_name', v_machine_name,
    'recorded_amount', p_recovered_amount,
    'tender_method', p_tender_method,
    'recovered_at', p_recovered_at,
    'reconciliation', jsonb_build_object(
      'txn_total', v_txn_total,
      'adyen_captured', v_adyen_captured,
      'adyen_refunded', v_adyen_refunded,
      'total_cash_recovered', v_total_cash,
      'remaining_gap', v_remaining_gap,
      'closed', (v_remaining_gap <= 0.01)
    )
  );
END;
$function$;
