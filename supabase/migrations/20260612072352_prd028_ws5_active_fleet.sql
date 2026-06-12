-- PRD-028 WS5: canonical active-fleet scope view (Article 16)
-- Applied via MCP as prd028_ws5_active_fleet (version 20260612072352).
-- v_active_fleet -> report RPCs (first consumer: get_payment_default_summary).
-- Design + decision notes: docs/prds/prd-028/WS5-active-fleet-design.md

CREATE OR REPLACE VIEW public.v_active_fleet AS
SELECT m.machine_id,
       m.official_name,
       m.venue_group,
       CASE WHEN m.venue_group = 'VOX' THEN 'vox' ELSE 'main' END AS service_track,
       COALESCE(m.include_in_refill, true) AS include_in_refill,
       COALESCE(m.status, 'Active') AS status,
       m.repurposed_at
FROM public.machines m
WHERE COALESCE(m.status, 'Active') NOT IN ('Inactive', 'Warehouse');

COMMENT ON VIEW public.v_active_fleet IS
'CANONICAL (Article 16, METRICS_REGISTRY.md): the operating fleet scope. Base rule: status NOT IN (Inactive, Warehouse). Consumers add their DECLARED extra filters from exposed columns: refill/ops -> include_in_refill AND repurposed_at IS NULL; reconciliation -> none (repurposed-but-Active rows still carry period sales: 3,620.75 AED on 06-01..11 VOX). Never re-derive fleet scope WHERE clauses inline.';

-- get_payment_default_summary: venue-scope branch consumes v_active_fleet.
-- Verified value-identical pre/post on 06-01..11 VOX (full jsonb equality).
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
         SUM(sh.total_amount) AS txn_total
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
  'formula',   'captured = settled - refunds + cash; gap = total - captured; default = ref short > 0.01 after refunds+cash',
  'total_sales',        ROUND(SUM(txn_total), 2),
  'captured_card_gross',ROUND(SUM(settled), 2),
  'refunds',            ROUND(SUM(refunded), 2),
  'cash_recovered',     ROUND(SUM(cash_recovered), 2),
  'captured_net',       ROUND(SUM(captured_net), 2),
  'gap',                ROUND(SUM(txn_total) - SUM(captured_net), 2),
  'default_pct',        ROUND(100.0 * (SUM(txn_total) - SUM(captured_net)) / NULLIF(SUM(txn_total),0), 2),
  'txn_refs',           COUNT(*),
  'matched_refs',       COUNT(*) FILTER (WHERE adyen_matched),
  'default_refs',       COUNT(*) FILTER (WHERE captured_net < txn_total - 0.01),
  'refunded_refs',      COUNT(*) FILTER (WHERE refunded > 0),
  'cash_refs',          COUNT(*) FILTER (WHERE cash_recovered > 0)
) FROM per_ref;
$function$;
