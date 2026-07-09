-- PRD-087 dashboard sales v2 (CS fixes):
-- 1) VOX toggle now means venue_group = 'VOX' (the whole MAF venue group —
--    VOX cinemas AND sister pods ACTIVATE / IFLY / MPMCC / ACTIVATEMCC),
--    not machine names starting with VOX.
-- 2) default_rate now uses the CANONICAL PRD-023h formula from
--    get_payment_default_summary: per merchant_reference (internal_txn_sn
--    with _N suffix stripped), default_short = GREATEST(total − Adyen
--    settled − refunded − cash_recovered, 0); rate = gap / matched sales,
--    over Adyen-MATCHED refs only (refunds are not default).
CREATE OR REPLACE FUNCTION public.get_dashboard_sales(
  p_include_vox boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
WITH now_dxb AS (
  SELECT (now() AT TIME ZONE 'Asia/Dubai')::date AS today
),
sales AS MATERIALIZED (
  SELECT (sh.transaction_date AT TIME ZONE 'Asia/Dubai')::date AS d,
         sh.machine_id, m.official_name AS machine_name,
         COALESCE(NULLIF(TRIM(pnc.official_name), ''), TRIM(sh.pod_product_name)) AS product_name,
         sh.qty, sh.paid_amount, sh.total_amount,
         regexp_replace(sh.internal_txn_sn, '_\d+$', '') AS merchant_reference
  FROM sales_history sh
  JOIN machines m ON m.machine_id = sh.machine_id
  LEFT JOIN product_name_conventions pnc
    ON lower(TRIM(pnc.original_name)) = lower(TRIM(sh.pod_product_name))
  WHERE sh.delivery_status IN ('Success','Successful')
    AND NOT (COALESCE(sh.refunded_amount,0) > 0
             AND COALESCE(sh.refunded_amount,0) >= COALESCE(sh.paid_amount,0))
    AND COALESCE(m.venue_group,'') <> 'WH'
    AND upper(m.official_name) NOT LIKE 'WH%'
    AND (p_include_vox OR COALESCE(m.venue_group,'') <> 'VOX')
    AND (sh.transaction_date AT TIME ZONE 'Asia/Dubai')::date
        >= (SELECT today FROM now_dxb) - 30
),
-- canonical default (PRD-023h, matched-only): one adyen/cash pass for the
-- whole 30d scope, then aggregated per KPI window by ref date
refs AS MATERIALIZED (
  SELECT merchant_reference, max(d) AS d, sum(total_amount) AS txn_total
  FROM sales GROUP BY 1
),
ady AS (
  SELECT at.merchant_reference,
         COALESCE(SUM(at.captured_amount_value) FILTER (WHERE at.status = 'SettledBulk'),0)  AS settled,
         COALESCE(SUM(at.captured_amount_value) FILTER (WHERE at.status = 'RefundedBulk'),0) AS refunded
  FROM adyen_transactions at
  WHERE at.merchant_reference IN (SELECT merchant_reference FROM refs)
  GROUP BY 1
),
cash AS (
  SELECT crl.merchant_reference, SUM(crl.recovered_amount) AS cash_recovered
  FROM cash_recovery_log crl
  WHERE crl.merchant_reference IN (SELECT merchant_reference FROM refs)
  GROUP BY 1
),
per_ref AS MATERIALIZED (
  SELECT r.merchant_reference, r.d, r.txn_total,
         (a.merchant_reference IS NOT NULL) AS adyen_matched,
         GREATEST(r.txn_total - COALESCE(a.settled,0) - COALESCE(a.refunded,0)
                  - COALESCE(c.cash_recovered,0), 0) AS default_short
  FROM refs r
  LEFT JOIN ady a  ON a.merchant_reference = r.merchant_reference
  LEFT JOIN cash c ON c.merchant_reference = r.merchant_reference
),
kpi AS (
  SELECT jsonb_build_object(
    'today', (SELECT jsonb_build_object(
        'revenue', COALESCE(round(sum(paid_amount),0),0),
        'units', COALESCE(sum(qty),0), 'txns', count(*),
        'default_rate', COALESCE((
          SELECT round(100.0 * COALESCE(sum(default_short) FILTER (WHERE adyen_matched),0)
                 / NULLIF(sum(txn_total) FILTER (WHERE adyen_matched),0), 2)
          FROM per_ref WHERE d = (SELECT today FROM now_dxb)), 0))
      FROM sales WHERE d = (SELECT today FROM now_dxb)),
    'd7', (SELECT jsonb_build_object(
        'revenue', COALESCE(round(sum(paid_amount),0),0),
        'units', COALESCE(sum(qty),0), 'txns', count(*),
        'default_rate', COALESCE((
          SELECT round(100.0 * COALESCE(sum(default_short) FILTER (WHERE adyen_matched),0)
                 / NULLIF(sum(txn_total) FILTER (WHERE adyen_matched),0), 2)
          FROM per_ref WHERE d > (SELECT today FROM now_dxb) - 7), 0))
      FROM sales WHERE d > (SELECT today FROM now_dxb) - 7),
    'd30', (SELECT jsonb_build_object(
        'revenue', COALESCE(round(sum(paid_amount),0),0),
        'units', COALESCE(sum(qty),0), 'txns', count(*),
        'default_rate', COALESCE((
          SELECT round(100.0 * COALESCE(sum(default_short) FILTER (WHERE adyen_matched),0)
                 / NULLIF(sum(txn_total) FILTER (WHERE adyen_matched),0), 2)
          FROM per_ref), 0))
      FROM sales),
    'daily', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'd', gs::date, 'revenue', COALESCE(s.rev,0), 'units', COALESCE(s.units,0))
        ORDER BY gs), '[]'::jsonb)
      FROM generate_series((SELECT today FROM now_dxb) - 29,
                           (SELECT today FROM now_dxb), '1 day') gs
      LEFT JOIN (
        SELECT d, round(sum(paid_amount),0) rev, sum(qty) units
        FROM sales GROUP BY d
      ) s ON s.d = gs::date)
  ) AS j
),
top_machines AS (
  SELECT jsonb_build_object(
    'today', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'machine', t.machine_name, 'revenue', t.rev, 'units', t.units) ORDER BY t.rev DESC), '[]'::jsonb)
      FROM (SELECT machine_name, round(sum(paid_amount)) rev, sum(qty) units
            FROM sales WHERE d = (SELECT today FROM now_dxb)
            GROUP BY 1 ORDER BY 2 DESC LIMIT 10) t),
    'd7', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'machine', t.machine_name, 'revenue', t.rev, 'units', t.units) ORDER BY t.rev DESC), '[]'::jsonb)
      FROM (SELECT machine_name, round(sum(paid_amount)) rev, sum(qty) units
            FROM sales WHERE d > (SELECT today FROM now_dxb) - 7
            GROUP BY 1 ORDER BY 2 DESC LIMIT 10) t),
    'd30', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'machine', t.machine_name, 'revenue', t.rev, 'units', t.units) ORDER BY t.rev DESC), '[]'::jsonb)
      FROM (SELECT machine_name, round(sum(paid_amount)) rev, sum(qty) units
            FROM sales WHERE d > (SELECT today FROM now_dxb) - 30
            GROUP BY 1 ORDER BY 2 DESC LIMIT 10) t)
  ) AS j
),
top_products AS (
  SELECT jsonb_build_object(
    'today', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'product', t.product_name, 'revenue', t.rev, 'units', t.units) ORDER BY t.units DESC), '[]'::jsonb)
      FROM (SELECT product_name, round(sum(paid_amount)) rev, sum(qty) units
            FROM sales WHERE d = (SELECT today FROM now_dxb)
            GROUP BY 1 ORDER BY sum(qty) DESC LIMIT 10) t),
    'd7', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'product', t.product_name, 'revenue', t.rev, 'units', t.units) ORDER BY t.units DESC), '[]'::jsonb)
      FROM (SELECT product_name, round(sum(paid_amount)) rev, sum(qty) units
            FROM sales WHERE d > (SELECT today FROM now_dxb) - 7
            GROUP BY 1 ORDER BY sum(qty) DESC LIMIT 10) t),
    'd30', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'product', t.product_name, 'revenue', t.rev, 'units', t.units) ORDER BY t.units DESC), '[]'::jsonb)
      FROM (SELECT product_name, round(sum(paid_amount)) rev, sum(qty) units
            FROM sales WHERE d > (SELECT today FROM now_dxb) - 30
            GROUP BY 1 ORDER BY sum(qty) DESC LIMIT 10) t)
  ) AS j
)
SELECT jsonb_build_object(
  'generated_at', now(),
  'today', (SELECT today FROM now_dxb),
  'include_vox', p_include_vox,
  'trading_machines', (SELECT count(DISTINCT machine_id) FROM sales),
  'kpis', (SELECT j FROM kpi),
  'top_machines', (SELECT j FROM top_machines),
  'top_products', (SELECT j FROM top_products)
);
$$;

COMMENT ON FUNCTION public.get_dashboard_sales(boolean) IS
'PRD-087 v2: fast sales dashboard blocks. p_include_vox scopes by venue_group=VOX (whole MAF group incl ACTIVATE/IFLY/MPMCC). default_rate = canonical PRD-023h (Adyen-matched gap / matched sales, refunds & cash recovery credited). Read-only.';
