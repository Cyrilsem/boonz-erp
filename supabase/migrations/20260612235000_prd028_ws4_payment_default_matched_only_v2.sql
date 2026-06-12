-- PRD-028 WS4 Option 1 (CS decision 2026-06-12): get_payment_default_summary v2.
-- Gap/default are now MATCHED-ONLY (refs with an Adyen record); unmatched refs
-- (settlement lag / no Adyen record yet) become an EXPLICIT unmatched_exposure
-- field, age-split at 7 days (recent = likely settlement lag; aged = likely
-- real default). Partner-visible default rates stay stable (1.27% class, not
-- 21% with lag noise); exposure is visible instead of implicit.
-- Signature UNCHANGED (no new params - avoids the pg overload footgun).
-- v1 rollback md5 10662ff4870ef54a0907dbe4b3f65926.

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
         COALESCE(SUM(at.captured_amount_value) FILTER (WHERE at.status = 'RefundedBulk'),0) AS refunded
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
         COALESCE(a.refunded,0)       AS refunded,
         COALESCE(c.cash_recovered,0) AS cash_recovered,
         (COALESCE(a.settled,0) - COALESCE(a.refunded,0) + COALESCE(c.cash_recovered,0)) AS captured_net,
         (a.merchant_reference IS NOT NULL) AS adyen_matched
  FROM txns t
  LEFT JOIN ady a  ON a.merchant_reference = t.merchant_reference
  LEFT JOIN cash c ON c.merchant_reference = t.merchant_reference
)
SELECT jsonb_build_object(
  'date_from', p_date_from,
  'date_to',   p_date_to,
  'scope',     COALESCE(p_venue_group,'custom'),
  'semantics', 'matched_only_v2',
  'formula',   'captured = settled - refunds + cash; gap/default over MATCHED refs only; unmatched refs reported as explicit exposure, age-split at 7d',
  'total_sales',        ROUND(SUM(txn_total), 2),
  'matched_total_sales',ROUND(COALESCE(SUM(txn_total) FILTER (WHERE adyen_matched), 0), 2),
  'captured_card_gross',ROUND(SUM(settled), 2),
  'refunds',            ROUND(SUM(refunded), 2),
  'cash_recovered',     ROUND(SUM(cash_recovered), 2),
  'captured_net',       ROUND(SUM(captured_net), 2),
  'gap',                ROUND(COALESCE(SUM(txn_total - captured_net) FILTER (WHERE adyen_matched), 0), 2),
  'default_pct',        ROUND(100.0 * COALESCE(SUM(txn_total - captured_net) FILTER (WHERE adyen_matched), 0)
                          / NULLIF(SUM(txn_total) FILTER (WHERE adyen_matched), 0), 2),
  'unmatched_refs',     COUNT(*) FILTER (WHERE NOT adyen_matched),
  'unmatched_exposure', ROUND(COALESCE(SUM(txn_total - captured_net) FILTER (WHERE NOT adyen_matched), 0), 2),
  'unmatched_refs_recent',     COUNT(*) FILTER (WHERE NOT adyen_matched AND last_txn_at >= now() - interval '7 days'),
  'unmatched_exposure_recent', ROUND(COALESCE(SUM(txn_total - captured_net) FILTER (WHERE NOT adyen_matched AND last_txn_at >= now() - interval '7 days'), 0), 2),
  'unmatched_refs_aged',       COUNT(*) FILTER (WHERE NOT adyen_matched AND last_txn_at < now() - interval '7 days'),
  'unmatched_exposure_aged',   ROUND(COALESCE(SUM(txn_total - captured_net) FILTER (WHERE NOT adyen_matched AND last_txn_at < now() - interval '7 days'), 0), 2),
  'age_split_days',     7,
  'txn_refs',           COUNT(*),
  'matched_refs',       COUNT(*) FILTER (WHERE adyen_matched),
  'default_refs',       COUNT(*) FILTER (WHERE adyen_matched AND captured_net < txn_total - 0.01),
  'refunded_refs',      COUNT(*) FILTER (WHERE refunded > 0),
  'cash_refs',          COUNT(*) FILTER (WHERE cash_recovered > 0)
) FROM per_ref;
$function$;
