-- PRD-023i (2026-06-17): VOX line-detail money columns + report timeout headroom.
-- Applied to remote via MCP as prd023_i_lines_money_cols_and_timeout.
--
-- (1) get_vox_commercial_txn_lines: add txn-level Adyen Fees / Net Revenue / Boonz 20% /
--     VOX 80% so MAFE has ONE report (Default/Refund/COGS already present). Signature
--     change => DROP+CREATE (reporting fn, no positional callers; FE reads by JSON key).
--     Money math mirrors get_vox_commercial_report exactly; line totals tie to the waterfall
--     (per-txn 2-dp rounding gives <2 AED/month drift on fee/share subtotals, expected).
-- (2) statement_timeout='30s' (function-local GUC) on the 3 VOX report RPCs so transient DB
--     contention stops cancelling month-window queries at the role default (authenticated 8s).
--     Warm runtime ~1.9s; 30s is headroom. Companion: maxDuration=30 on the 3 /api/vox routes.
-- Read-only; no protected-entity writes. Cody-approved (class c). Articles 12/13 (DROP+CREATE ok).

DROP FUNCTION IF EXISTS public.get_vox_commercial_txn_lines(text[], date, date);

CREATE FUNCTION public.get_vox_commercial_txn_lines(
  p_pods text[] DEFAULT ARRAY['Mercato'::text, 'Mirdif'::text],
  p_date_from date DEFAULT '2026-02-06'::date,
  p_date_to date DEFAULT CURRENT_DATE)
 RETURNS TABLE(base_txn_sn text, psp_reference text, transaction_date timestamp with time zone,
   site text, machine text, pod_product_name text, qty numeric, unit_price numeric,
   line_total numeric, unit_cogs numeric, line_cogs numeric, supply_source text,
   txn_captured numeric, txn_default numeric, txn_refunded numeric,
   txn_adyen_fees numeric, txn_net_revenue numeric, txn_boonz_share numeric, txn_vox_share numeric,
   txn_status text)
 LANGUAGE sql
 STABLE
 SET "TimeZone" TO 'Asia/Dubai'
 SET statement_timeout TO '30s'
AS $function$
  WITH vox_machines AS (
    SELECT m.machine_id, m.official_name,
      CASE WHEN m.pod_location ILIKE '%Mercato%' THEN 'Mercato'
           WHEN m.pod_location ILIKE '%Mirdi%'   THEN 'Mirdif' ELSE 'Other' END AS site
    FROM machines m WHERE m.venue_group = 'VOX' AND m.status = 'Active'
  ),
  selected_machines AS (SELECT * FROM vox_machines WHERE site = ANY(p_pods)),
  vox_sales AS (
    SELECT sh.machine_id, sm.official_name, sm.site,
      regexp_replace(sh.internal_txn_sn, '_\d+$', '') AS base_txn_sn,
      sh.transaction_date, sh.pod_product_name,
      COALESCE(sh.qty,0) AS qty,
      COALESCE(sh.total_amount, sh.paid_amount, 0) AS line_total,
      vpm.cost_incl_vat AS unit_cogs,
      (COALESCE(vpm.cost_incl_vat,0) * COALESCE(sh.qty,0))::numeric AS line_cogs,
      CASE WHEN vpm.source_of_supply = 'BOONZ' THEN 'Boonz'
           WHEN vpm.source_of_supply IS NULL THEN 'Unmapped'
           ELSE vpm.source_of_supply END AS supply_source,
      COALESCE(sh.refunded_amount,0) AS refunded_amount
    FROM sales_history sh
    JOIN selected_machines sm ON sm.machine_id = sh.machine_id
    LEFT JOIN vox_product_mapping vpm
      ON LOWER(TRIM(sh.pod_product_name)) = LOWER(TRIM(vpm.pod_product_name))
    WHERE sh.transaction_date::date >= p_date_from
      AND sh.transaction_date::date <= p_date_to
      AND (COALESCE(sh.total_amount, 0) > 0 OR COALESCE(sh.paid_amount, 0) > 0)
      AND COALESCE(sh.pod_product_name,'') <> 'Smart fridge'
  ),
  vox_txns AS (
    SELECT base_txn_sn, MIN(transaction_date) AS transaction_date,
      SUM(line_total) AS total_amount, SUM(refunded_amount) AS refunded_amount
    FROM vox_sales GROUP BY base_txn_sn
  ),
  adyen_settled AS (
    SELECT a.merchant_reference, SUM(a.captured_amount_value) AS captured_settled, MAX(a.psp_reference) AS psp_reference
    FROM v_adyen_transactions_attributed a
    WHERE a.status='SettledBulk' AND a.transaction_type='Purchase'
      AND a.pos_transaction_date::date >= p_date_from - INTERVAL '7 days'
      AND a.pos_transaction_date::date <= p_date_to + INTERVAL '7 days'
    GROUP BY a.merchant_reference
  ),
  adyen_refunds AS (
    SELECT a.merchant_reference, SUM(a.captured_amount_value) AS captured_refunded,
      SUM(COALESCE(a.adjusted_amount_value,0)) AS refund_returned
    FROM v_adyen_transactions_attributed a
    WHERE a.status='RefundedBulk' AND a.transaction_type='Purchase'
      AND a.pos_transaction_date::date >= p_date_from - INTERVAL '7 days'
      AND a.pos_transaction_date::date <= p_date_to + INTERVAL '7 days'
    GROUP BY a.merchant_reference
  ),
  cash_recovered_by_ref AS (
    SELECT merchant_reference, SUM(recovered_amount) AS cash_recovered
    FROM cash_recovery_log GROUP BY merchant_reference
  ),
  txn_money AS (
    SELECT t.base_txn_sn, s.psp_reference,
      (COALESCE(s.captured_settled,0) + COALESCE(r.captured_refunded,0) - COALESCE(r.refund_returned,0) + COALESCE(cr.cash_recovered,0)) AS captured_amount,
      (COALESCE(s.captured_settled,0) + COALESCE(r.captured_refunded,0) - COALESCE(r.refund_returned,0)) AS adyen_captured_net,
      COALESCE(r.refund_returned,0) AS refunded_amount,
      (s.psp_reference IS NOT NULL OR COALESCE(r.captured_refunded,0) > 0 OR COALESCE(cr.cash_recovered,0) > 0) AS is_matched,
      t.total_amount
    FROM vox_txns t
    LEFT JOIN adyen_settled s ON s.merchant_reference = t.base_txn_sn
    LEFT JOIN adyen_refunds r ON r.merchant_reference = t.base_txn_sn
    LEFT JOIN cash_recovered_by_ref cr ON cr.merchant_reference = t.base_txn_sn
  ),
  txn_calc AS (
    SELECT *,
      CASE WHEN psp_reference IS NOT NULL THEN ROUND(0.50 + adyen_captured_net * 0.026, 3) ELSE 0 END AS adyen_fees
    FROM txn_money
  )
  SELECT
    vs.base_txn_sn,
    tm.psp_reference,
    vs.transaction_date,
    vs.site,
    vs.official_name AS machine,
    vs.pod_product_name,
    vs.qty,
    ROUND(vs.line_total / NULLIF(vs.qty,0), 4) AS unit_price,
    vs.line_total,
    vs.unit_cogs,
    vs.line_cogs,
    vs.supply_source,
    ROUND(COALESCE(tm.captured_amount,0), 2) AS txn_captured,
    ROUND(GREATEST(tm.total_amount - COALESCE(tm.captured_amount,0), 0)
          * (CASE WHEN tm.is_matched THEN 1 ELSE 0 END), 2) AS txn_default,
    ROUND(COALESCE(tm.refunded_amount,0), 2) AS txn_refunded,
    ROUND(COALESCE(tm.adyen_fees,0), 2) AS txn_adyen_fees,
    ROUND(COALESCE(tm.captured_amount,0) - COALESCE(tm.refunded_amount,0) - COALESCE(tm.adyen_fees,0), 2) AS txn_net_revenue,
    ROUND((COALESCE(tm.captured_amount,0) - COALESCE(tm.refunded_amount,0) - COALESCE(tm.adyen_fees,0)) * 0.20, 2) AS txn_boonz_share,
    ROUND((COALESCE(tm.captured_amount,0) - COALESCE(tm.refunded_amount,0) - COALESCE(tm.adyen_fees,0)) * 0.80, 2) AS txn_vox_share,
    CASE WHEN tm.is_matched AND (tm.total_amount - COALESCE(tm.captured_amount,0)) <= 0.01 THEN 'matched'
         WHEN tm.is_matched THEN 'discrepancy'
         ELSE 'unmatched' END AS txn_status
  FROM vox_sales vs
  LEFT JOIN txn_calc tm ON tm.base_txn_sn = vs.base_txn_sn
  ORDER BY vs.transaction_date DESC, vs.base_txn_sn, vs.pod_product_name;
$function$;

GRANT EXECUTE ON FUNCTION public.get_vox_commercial_txn_lines(text[], date, date) TO authenticated, service_role;

ALTER FUNCTION public.get_vox_commercial_report(text[], date, date) SET statement_timeout TO '30s';
ALTER FUNCTION public.get_vox_consumer_report(text[], boolean, date, date, uuid) SET statement_timeout TO '30s';
