-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- VOX SOA reconciliation wave (recon_fix1..6, 2026-07-28). get_vox_consumer_report: refund handling
-- fixed to use refunded_amount_value; refunded baskets matched via refund-row psp (were shown as
-- wallet/unmatched); refunds excluded from default stats; summary gains total_refunded/refunded_txns;
-- recent_txns gains status='refunded'/refunded amount. Signature unchanged, grants preserved.
-- Body below is the current live function definition.

CREATE OR REPLACE FUNCTION public.get_vox_consumer_report(p_pods text[] DEFAULT ARRAY['Mercato'::text, 'Mirdif'::text], p_consolidated boolean DEFAULT true, p_date_from date DEFAULT '2026-02-06'::date, p_date_to date DEFAULT CURRENT_DATE, p_machine uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET "TimeZone" TO 'Asia/Dubai'
 SET statement_timeout TO '30s'
AS $function$
DECLARE v_result jsonb;
BEGIN
  WITH vox_machines AS (
    SELECT m.machine_id, m.official_name AS machine_name, m.adyen_store_description AS adyen_desc,
      CASE WHEN m.pod_location ILIKE '%Mercato%' THEN 'Mercato'
           WHEN m.pod_location ILIKE '%Mirdi%'   THEN 'Mirdif' ELSE 'Other' END AS site
    FROM machines m WHERE m.venue_group = 'VOX' AND m.status = 'Active'
  ),
  selected_machines AS (SELECT * FROM vox_machines WHERE site = ANY(p_pods)),
  vox_sales AS (
    SELECT * FROM (
      SELECT sh.*, sm.site, sm.machine_name AS official_name,
        regexp_replace(sh.internal_txn_sn, '_\d+$', '') AS base_txn_sn,
        COALESCE(sh.paid_amount, 0) AS effective_paid,
        COALESCE(sh.total_amount, sh.paid_amount, 0) AS effective_total,
        SUM(COALESCE(sh.total_amount, 0) + COALESCE(sh.paid_amount, 0))
          OVER (PARTITION BY regexp_replace(sh.internal_txn_sn, '_\d+$', '')) AS basket_amount
      FROM sales_history sh JOIN selected_machines sm ON sm.machine_id = sh.machine_id
      WHERE sh.transaction_date::date >= p_date_from AND sh.transaction_date::date <= p_date_to
        AND (p_machine IS NULL OR sh.machine_id = p_machine)
    ) q
    WHERE basket_amount > 0
  ),
  vox_txns AS (
    SELECT base_txn_sn, site, machine_id, official_name,
      MIN(transaction_date) AS transaction_date,
      SUM(effective_total) AS total_amount, SUM(effective_paid) AS paid_amount,
      SUM(qty) AS qty,
      string_agg(DISTINCT pod_product_name, ' | ' ORDER BY pod_product_name) AS items
    FROM vox_sales GROUP BY base_txn_sn, site, machine_id, official_name
  ),
  adyen_settled AS (
    SELECT a.merchant_reference, SUM(a.captured_amount_value) AS captured_settled,
      MAX(a.psp_reference) AS psp_reference, MAX(a.funding_source) AS funding_source,
      MAX(a.payment_method) AS payment_method, MAX(a.token_payment_variant) AS token_payment_variant,
      MAX(a.value_aed) AS value_aed
    FROM v_adyen_transactions_attributed a
    WHERE a.status='SettledBulk' AND a.transaction_type='Purchase'
      AND a.pos_transaction_date::date >= p_date_from - INTERVAL '7 days'
      AND a.pos_transaction_date::date <= p_date_to + INTERVAL '7 days'
    GROUP BY a.merchant_reference
  ),
  adyen_refunds AS (
    SELECT a.merchant_reference, SUM(a.captured_amount_value) AS captured_refunded,
      SUM(COALESCE(a.refunded_amount_value,0)) AS refund_returned,
      MAX(a.psp_reference) AS psp_reference
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
  vox_joined AS (
    SELECT t.*,
      (COALESCE(s.captured_settled,0) + COALESCE(r.captured_refunded,0) - COALESCE(r.refund_returned,0)) AS adyen_captured,
      COALESCE(r.refund_returned, 0) AS refund_returned,
      COALESCE(cr.cash_recovered, 0) AS cash_recovered,
      (COALESCE(s.captured_settled,0) + COALESCE(r.captured_refunded,0) - COALESCE(r.refund_returned,0) + COALESCE(cr.cash_recovered,0)) AS captured,
      s.value_aed, s.funding_source, s.payment_method, s.token_payment_variant,
      COALESCE(s.psp_reference, r.psp_reference) AS psp_reference
    FROM vox_txns t
    LEFT JOIN adyen_settled s ON s.merchant_reference = t.base_txn_sn
    LEFT JOIN adyen_refunds r ON r.merchant_reference = t.base_txn_sn
    LEFT JOIN cash_recovered_by_ref cr ON cr.merchant_reference = t.base_txn_sn
  ),
  default_stats AS (
    SELECT COUNT(*) AS matched_txns, COALESCE(SUM(total_amount), 0) AS matched_total,
      COALESCE(SUM(captured), 0) AS matched_captured,
      COALESCE(SUM(GREATEST(total_amount - captured, 0)) FILTER (WHERE refund_returned = 0), 0) AS default_gap,
      COUNT(*) FILTER (WHERE refund_returned = 0 AND total_amount - captured > 0.01) AS default_count
    FROM vox_joined WHERE psp_reference IS NOT NULL
  ),
  discrepancies AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'psp', psp_reference, 'merchant_ref', base_txn_sn,
      'date', to_char(transaction_date, 'DD Mon'), 'site', site, 'machine', official_name,
      'total', total_amount, 'captured', captured,
      'adyen_captured', COALESCE(adyen_captured, 0), 'cash_recovered', cash_recovered,
      'gap', ROUND(total_amount - captured, 2), 'items', items
    ) ORDER BY transaction_date DESC), '[]'::jsonb) AS data
    FROM vox_joined WHERE psp_reference IS NOT NULL AND refund_returned = 0 AND total_amount - captured > 0.01
  ),
  summary AS (
    SELECT jsonb_build_object(
      'total_sales', COALESCE(SUM(total_amount), 0), 'total_paid', COALESCE(SUM(paid_amount), 0),
      'total_txns', COUNT(*), 'total_units', COALESCE(SUM(qty), 0),
      'total_captured', COALESCE((SELECT SUM(captured) FROM vox_joined WHERE psp_reference IS NOT NULL), 0),
      'total_adyen_captured', COALESCE((SELECT SUM(adyen_captured) FROM vox_joined WHERE psp_reference IS NOT NULL), 0),
      'total_cash_recovered', COALESCE((SELECT SUM(cash_recovered) FROM vox_joined), 0),
      'total_refunded', COALESCE((SELECT SUM(refund_returned) FROM vox_joined), 0),
      'refunded_txns', (SELECT COUNT(*) FROM vox_joined WHERE refund_returned > 0),
      'adyen_txn_count', (SELECT COUNT(*) FROM vox_joined WHERE psp_reference IS NOT NULL),
      'num_machines', (SELECT COUNT(DISTINCT machine_id) FROM vox_sales),
      'has_adyen_data', EXISTS(SELECT 1 FROM vox_joined WHERE psp_reference IS NOT NULL),
      'matched_txns', (SELECT matched_txns FROM default_stats),
      'unmatched_txns', COUNT(*) FILTER (WHERE psp_reference IS NULL),
      'pending_txns', COUNT(*) FILTER (WHERE psp_reference IS NULL AND transaction_date > now() - INTERVAL '48 hours'),
      'wallet_txns', COUNT(*) FILTER (WHERE psp_reference IS NULL AND transaction_date <= now() - INTERVAL '48 hours'),
      'adyen_match_pct', CASE WHEN COUNT(*) > 0 THEN ROUND(COUNT(psp_reference)::numeric / COUNT(*)::numeric * 100, 1) ELSE 0 END,
      'matched_total', (SELECT matched_total FROM default_stats),
      'matched_captured', (SELECT matched_captured FROM default_stats),
      'default_rate', CASE WHEN (SELECT matched_total FROM default_stats) > 0
                       THEN ROUND((SELECT default_gap FROM default_stats) / (SELECT matched_total FROM default_stats) * 100, 2) ELSE 0 END,
      'default_gap', (SELECT default_gap FROM default_stats), 'disc_count', (SELECT default_count FROM default_stats),
      'date_from', p_date_from, 'date_to', p_date_to,
      'mercato', jsonb_build_object('total', COALESCE(SUM(total_amount) FILTER (WHERE site = 'Mercato'), 0),
        'txns', COUNT(*) FILTER (WHERE site = 'Mercato'), 'units', COALESCE(SUM(qty) FILTER (WHERE site = 'Mercato'), 0),
        'captured', COALESCE(SUM(captured) FILTER (WHERE site = 'Mercato' AND psp_reference IS NOT NULL), 0)),
      'mirdif', jsonb_build_object('total', COALESCE(SUM(total_amount) FILTER (WHERE site = 'Mirdif'), 0),
        'txns', COUNT(*) FILTER (WHERE site = 'Mirdif'), 'units', COALESCE(SUM(qty) FILTER (WHERE site = 'Mirdif'), 0),
        'captured', COALESCE(SUM(captured) FILTER (WHERE site = 'Mirdif' AND psp_reference IS NOT NULL), 0))
    ) AS data FROM vox_joined
  ),
  daily AS (SELECT jsonb_agg(jsonb_build_object('site', site, 'date', to_char(d, 'YYYY-MM-DD'), 'amount', day_total) ORDER BY d, site) AS data
    FROM (SELECT site, transaction_date::date AS d, SUM(effective_total) AS day_total FROM vox_sales GROUP BY site, transaction_date::date) sub),
  weekly AS (SELECT jsonb_agg(jsonb_build_object('site', site, 'week_start', to_char(ws, 'YYYY-MM-DD'),
      'week_label', 'W' || EXTRACT(WEEK FROM ws)::int, 'amount', week_total) ORDER BY ws, site) AS data
    FROM (SELECT site, date_trunc('week', transaction_date)::date AS ws, SUM(effective_total) AS week_total FROM vox_sales GROUP BY site, date_trunc('week', transaction_date)::date) sub),
  machines_agg AS (SELECT jsonb_agg(jsonb_build_object('site', site, 'machine', official_name, 'machine_id', machine_id, 'amount', mt) ORDER BY mt DESC) AS data
    FROM (SELECT site, machine_id, MAX(official_name) AS official_name, SUM(effective_total) AS mt FROM vox_sales GROUP BY site, machine_id) sub),
  products AS (SELECT jsonb_agg(jsonb_build_object('site', site, 'name', pod_product_name, 'revenue', pr, 'qty', pq) ORDER BY pr DESC) AS data
    FROM (SELECT site, pod_product_name, SUM(effective_total) AS pr, SUM(qty) AS pq FROM vox_sales GROUP BY site, pod_product_name) sub),
  hourly AS (SELECT jsonb_agg(jsonb_build_object('site', site, 'hour', hr, 'amount', ht) ORDER BY hr, site) AS data
    FROM (SELECT site, EXTRACT(HOUR FROM transaction_date) AS hr, SUM(effective_total) AS ht FROM vox_sales GROUP BY site, EXTRACT(HOUR FROM transaction_date)) sub),
  dow AS (SELECT jsonb_agg(jsonb_build_object('site', site, 'dow_n', dn,
      'dow', CASE dn WHEN 0 THEN 'Mon' WHEN 1 THEN 'Tue' WHEN 2 THEN 'Wed' WHEN 3 THEN 'Thu'
        WHEN 4 THEN 'Fri' WHEN 5 THEN 'Sat' WHEN 6 THEN 'Sun' END, 'amount', dt) ORDER BY dn, site) AS data
    FROM (SELECT site, EXTRACT(ISODOW FROM transaction_date)::int - 1 AS dn, SUM(effective_total) AS dt
          FROM vox_sales GROUP BY site, EXTRACT(ISODOW FROM transaction_date)::int - 1) sub),
  funding AS (SELECT COALESCE(jsonb_agg(jsonb_build_object('site', site, 'source', funding_source, 'count', fc, 'sum', fs) ORDER BY fs DESC), '[]'::jsonb) AS data
    FROM (SELECT site, funding_source, COUNT(*) AS fc, SUM(total_amount) AS fs FROM vox_joined WHERE funding_source IS NOT NULL GROUP BY site, funding_source) sub),
  cards AS (SELECT COALESCE(jsonb_agg(jsonb_build_object('site', site, 'method', payment_method, 'count', cc, 'sum', cs) ORDER BY cs DESC), '[]'::jsonb) AS data
    FROM (SELECT site, payment_method, COUNT(*) AS cc, SUM(total_amount) AS cs FROM vox_joined WHERE payment_method IS NOT NULL AND payment_method != '' GROUP BY site, payment_method) sub),
  wallets AS (SELECT COALESCE(jsonb_agg(jsonb_build_object('variant', token_payment_variant, 'count', wc, 'sum', ws) ORDER BY ws DESC), '[]'::jsonb) AS data
    FROM (SELECT token_payment_variant, COUNT(*) AS wc, SUM(total_amount) AS ws FROM vox_joined WHERE token_payment_variant IS NOT NULL AND token_payment_variant != '' GROUP BY token_payment_variant) sub),
  recent_txns AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'date', to_char(transaction_date, 'DD Mon'), 'time', to_char(transaction_date, 'HH24:MI'),
      'machine', official_name, 'site', site,
      'psp', COALESCE(LEFT(psp_reference, 16), '-'),
      'merchant_ref', base_txn_sn,
      'funding', COALESCE(funding_source, '-'), 'card', COALESCE(payment_method, '-'),
      'wallet', COALESCE(CASE token_payment_variant
        WHEN 'visa_applepay' THEN 'Apple Pay (V)' WHEN 'mc_applepay' THEN 'Apple Pay (M)'
        WHEN 'visa_googlepay' THEN 'Google Pay (V)' WHEN 'mc_googlepay' THEN 'Google Pay (M)'
        WHEN 'visa_samsungpay' THEN 'Samsung Pay' WHEN 'mc_samsungpay' THEN 'Samsung Pay (M)'
        ELSE token_payment_variant END, '-'),
      'total', total_amount, 'captured', captured,
      'adyen_captured', COALESCE(adyen_captured, 0), 'cash_recovered', cash_recovered,
      'refunded', refund_returned,
      'gap', ROUND(GREATEST(COALESCE(total_amount,0) - captured, 0), 2),
      'units', qty, 'items', items,
      'disc', (psp_reference IS NOT NULL AND refund_returned = 0 AND (total_amount - captured) > 0.01),
      'matched', (psp_reference IS NOT NULL),
      'pending', (psp_reference IS NULL AND transaction_date > now() - INTERVAL '48 hours'),
      'status', CASE
        WHEN refund_returned > 0 THEN 'refunded'
        WHEN psp_reference IS NOT NULL AND (total_amount - captured) <= 0.01 AND cash_recovered > 0 THEN 'matched_with_cash'
        WHEN psp_reference IS NOT NULL AND (total_amount - captured) <= 0.01 THEN 'matched'
        WHEN psp_reference IS NOT NULL THEN 'discrepancy'
        WHEN transaction_date > now() - INTERVAL '48 hours' THEN 'pending_settlement'
        ELSE 'wallet_or_offadyen' END
    ) ORDER BY transaction_date DESC), '[]'::jsonb) AS data
    FROM (SELECT * FROM vox_joined ORDER BY transaction_date DESC LIMIT 100000) sub
  )
  SELECT jsonb_build_object(
    'summary', (SELECT data FROM summary),
    'daily', COALESCE((SELECT data FROM daily), '[]'::jsonb),
    'weekly', COALESCE((SELECT data FROM weekly), '[]'::jsonb),
    'machines', COALESCE((SELECT data FROM machines_agg), '[]'::jsonb),
    'products', COALESCE((SELECT data FROM products), '[]'::jsonb),
    'hourly', COALESCE((SELECT data FROM hourly), '[]'::jsonb),
    'dow', COALESCE((SELECT data FROM dow), '[]'::jsonb),
    'funding', (SELECT data FROM funding), 'cards', (SELECT data FROM cards),
    'wallets', (SELECT data FROM wallets),
    'transactions', (SELECT data FROM recent_txns),
    'discrepancies', COALESCE((SELECT data FROM discrepancies), '[]'::jsonb),
    'meta', jsonb_build_object('generated_at', now(), 'pods_selected', to_jsonb(p_pods),
      'consolidated', p_consolidated, 'date_from', p_date_from, 'date_to', p_date_to,
      'machine_filter', p_machine, 'data_source', 'supabase', 'cash_recovery_included', true,
      'refund_source', 'refunded_amount_value')
  ) INTO v_result;
  RETURN v_result;
END;
$function$
