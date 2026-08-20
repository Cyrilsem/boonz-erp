-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- VOX SOA reconciliation wave (recon_fix1..6, 2026-07-28). get_payment_default_summary: refunds
-- now read actual adyen_transactions.refunded_amount_value instead of double-subtracting gross
-- captured of refunded baskets from captured_net. Semantics tag matched_only_v2_2_refund_amount.
-- Signature unchanged, grants preserved. Body below is the current live function definition.

CREATE OR REPLACE FUNCTION public.get_payment_default_summary(p_date_from date, p_date_to date, p_venue_group text DEFAULT 'VOX'::text, p_machine_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
WITH scope AS (
  SELECT machine_id FROM machines
  WHERE p_machine_ids IS NOT NULL AND machine_id = ANY(p_machine_ids)
  UNION ALL
  SELECT machine_id FROM v_active_fleet
  WHERE p_machine_ids IS NULL AND (p_venue_group IS NULL OR venue_group = p_venue_group)
),
txns AS (
  SELECT regexp_replace(sh.internal_txn_sn, '_\d+$', '') AS merchant_reference,
         SUM(sh.total_amount) AS txn_total,
         MAX(sh.transaction_date) AS last_txn_at
  FROM sales_history sh
  JOIN scope s ON s.machine_id = sh.machine_id
  WHERE sh.transaction_date::date BETWEEN p_date_from AND p_date_to
  GROUP BY 1
),
ady AS (
  SELECT at.merchant_reference,
         COALESCE(SUM(at.captured_amount_value) FILTER (WHERE at.status = 'SettledBulk'),0)  AS settled,
         COALESCE(SUM(at.captured_amount_value) FILTER (WHERE at.status = 'RefundedBulk'),0) AS refunded_gross,
         COALESCE(SUM(at.refunded_amount_value),0)                                           AS refunded_amt
  FROM adyen_transactions at
  WHERE at.merchant_reference IN (SELECT merchant_reference FROM txns)
  GROUP BY 1
),
cash AS (
  SELECT crl.merchant_reference, SUM(crl.recovered_amount) AS cash_recovered
  FROM cash_recovery_log crl
  WHERE crl.merchant_reference IN (SELECT merchant_reference FROM txns)
  GROUP BY 1
),
per_ref AS (
  SELECT t.merchant_reference,
         t.txn_total,
         t.last_txn_at,
         COALESCE(a.settled,0)        AS settled,
         COALESCE(a.refunded_gross,0) AS refunded_gross,
         COALESCE(a.refunded_amt,0)   AS refunded_amt,
         COALESCE(c.cash_recovered,0) AS cash_recovered,
         (COALESCE(a.settled,0) + COALESCE(a.refunded_gross,0) - COALESCE(a.refunded_amt,0) + COALESCE(c.cash_recovered,0)) AS captured_net,
         GREATEST(t.txn_total - COALESCE(a.settled,0) - COALESCE(a.refunded_gross,0) - COALESCE(c.cash_recovered,0), 0) AS default_short,
         (a.merchant_reference IS NOT NULL) AS adyen_matched
  FROM txns t
  LEFT JOIN ady a  ON a.merchant_reference = t.merchant_reference
  LEFT JOIN cash c ON c.merchant_reference = t.merchant_reference
)
SELECT jsonb_build_object(
  'date_from', p_date_from,
  'date_to',   p_date_to,
  'scope',     COALESCE(p_venue_group,'custom'),
  'semantics', 'matched_only_v2_2_refund_amount',
  'formula',   'per-ref default_short = GREATEST(total - settled - refunded_gross - cash, 0); refunds = actual refunded_amount_value (backfilled); captured_net = settled + refunded_gross - refunded_amt + cash; gap/default over MATCHED refs only (refunds are not default, PRD-023h); unmatched refs reported as explicit exposure, age-split at 7d',
  'total_sales',        ROUND(SUM(txn_total), 2),
  'matched_total_sales',ROUND(COALESCE(SUM(txn_total) FILTER (WHERE adyen_matched), 0), 2),
  'captured_card_gross',ROUND(SUM(settled + refunded_gross), 2),
  'refunds',            ROUND(SUM(refunded_amt), 2),
  'cash_recovered',     ROUND(SUM(cash_recovered), 2),
  'captured_net',       ROUND(SUM(captured_net), 2),
  'gap',                ROUND(COALESCE(SUM(default_short) FILTER (WHERE adyen_matched), 0), 2),
  'default_pct',        ROUND(100.0 * COALESCE(SUM(default_short) FILTER (WHERE adyen_matched), 0)
                          / NULLIF(SUM(txn_total) FILTER (WHERE adyen_matched), 0), 2),
  'unmatched_refs',     COUNT(*) FILTER (WHERE NOT adyen_matched),
  'unmatched_exposure', ROUND(COALESCE(SUM(default_short) FILTER (WHERE NOT adyen_matched), 0), 2),
  'unmatched_refs_recent',     COUNT(*) FILTER (WHERE NOT adyen_matched AND last_txn_at >= now() - interval '7 days'),
  'unmatched_exposure_recent', ROUND(COALESCE(SUM(default_short) FILTER (WHERE NOT adyen_matched AND last_txn_at >= now() - interval '7 days'), 0), 2),
  'unmatched_refs_aged',       COUNT(*) FILTER (WHERE NOT adyen_matched AND last_txn_at < now() - interval '7 days'),
  'unmatched_exposure_aged',   ROUND(COALESCE(SUM(default_short) FILTER (WHERE NOT adyen_matched AND last_txn_at < now() - interval '7 days'), 0), 2),
  'age_split_days',     7,
  'txn_refs',           COUNT(*),
  'matched_refs',       COUNT(*) FILTER (WHERE adyen_matched),
  'default_refs',       COUNT(*) FILTER (WHERE adyen_matched AND default_short > 0.01),
  'refunded_refs',      COUNT(*) FILTER (WHERE refunded_amt > 0),
  'cash_refs',          COUNT(*) FILTER (WHERE cash_recovered > 0)
) FROM per_ref;
$function$
