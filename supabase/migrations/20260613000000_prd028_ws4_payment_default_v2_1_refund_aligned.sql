-- PRD-028 WS4 v2.1: refund alignment found by Cody's required live comparison.
-- v2's matched gap (txn_total - captured_net) double-counted refund-only refs
-- (a 213 AED refunded txn contributed 426 of phantom gap: 567.30 vs the
-- waterfall's 141.30). PRD-023h ruled refunds are NOT default. v2.1 computes
-- per-ref default_short = GREATEST(total - settled - refunded - cash, 0),
-- floored like the waterfall. Verified cent-equal post-apply: gap 141.30 ==
-- waterfall 141.30 (VOX 2026-06-01..11), default 1.28%, unmatched exposure
-- 2,209.85 all in the <7d recent bucket (0 aged - pure settlement lag).
-- Same Cody verdict as v2 (the comparison was its apply condition).

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
         GREATEST(t.txn_total - COALESCE(a.settled,0) - COALESCE(a.refunded,0) - COALESCE(c.cash_recovered,0), 0) AS default_short,
         (a.merchant_reference IS NOT NULL) AS adyen_matched
  FROM txns t
  LEFT JOIN ady a  ON a.merchant_reference = t.merchant_reference
  LEFT JOIN cash c ON c.merchant_reference = t.merchant_reference
)
SELECT jsonb_build_object(
  'date_from', p_date_from,
  'date_to',   p_date_to,
  'scope',     COALESCE(p_venue_group,'custom'),
  'semantics', 'matched_only_v2_1_refund_aligned',
  'formula',   'per-ref default_short = GREATEST(total - settled - refunded - cash, 0); gap/default over MATCHED refs only (refunds are not default, PRD-023h); unmatched refs reported as explicit exposure, age-split at 7d',
  'total_sales',        ROUND(SUM(txn_total), 2),
  'matched_total_sales',ROUND(COALESCE(SUM(txn_total) FILTER (WHERE adyen_matched), 0), 2),
  'captured_card_gross',ROUND(SUM(settled), 2),
  'refunds',            ROUND(SUM(refunded), 2),
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
  'refunded_refs',      COUNT(*) FILTER (WHERE refunded > 0),
  'cash_refs',          COUNT(*) FILTER (WHERE cash_recovered > 0)
) FROM per_ref;
$function$;
