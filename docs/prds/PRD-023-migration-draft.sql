-- ============================================================================
-- PRD-023 VOX Dashboard Commercial Fixes -- BACKEND MIGRATION SET (DRAFT)
-- Status: DRAFT for Cody review + CS approval. NOT applied. Read-only RPCs only.
-- Project: eizcexopcuoycuosittm. Verified live 2026-06-11.
--
-- Parity anchors (06 Feb - 30 Apr, Mercato+Mirdif), validated read-only pre-draft:
--   commercial waterfall already returns: total 36,940.00 | captured 36,389.40 |
--     default 550.60 (1.49%) | refund 115.00 | boonz_cogs 1,878.02 | 1592 txns | 2448 units
--   machine identity: 8 distinct machine_id vs 9 machine_mapping (ACTIVATE-2005 dupes as MPMCC-2005)
--   line aggregation (Dubai TZ): SUM(line_total) 36,940.00, SUM(line_cogs) 1,878.02, 2448 units, 1592 txns
--
-- JUDGMENT CALLS flagged for Cody/CS (see notes inline):
--   J1. p_machine added by DROP + CREATE (single fn, no overload -> avoids PGRST203). Callers use named params.
--   J2. supply_source: source_of_supply has THREE values (BOONZ / VOX / LLFP). PRD wants 'Boonz' | 'VOX'.
--       Draft maps BOONZ -> 'Boonz', everything else (VOX, LLFP) -> 'VOX' (all venue-sourced, COGS 0).
--   J3. "VOX dashboard role": no dedicated Postgres role exists. vox_admin is an app_metadata JWT claim;
--       /api/vox/* routes call as service_role. Grants mirror the existing two RPCs (anon, authenticated, service_role).
--   J4. consumer total_captured now derived from the matched set (AC6), removing the buggy adyen_full store_description CTE.
-- ============================================================================


-- ============================================================================
-- (a) get_vox_commercial_report -- AC2 machine display by official_name (DISPLAY-ONLY; money untouched)
--     Changes vs live: carry machine_id + official_name through vox_sales -> vox_txns;
--     transactions[].machine = official_name (was machine_mapping). No money logic changed.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_vox_commercial_report(
  p_pods text[] DEFAULT ARRAY['Mercato'::text, 'Mirdif'::text],
  p_date_from date DEFAULT '2026-02-06'::date,
  p_date_to date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET "TimeZone" TO 'Asia/Dubai'
AS $function$
DECLARE
  v_result      jsonb;
  v_adyen_fixed numeric := 0.50;
  v_adyen_pct   numeric := 0.026;
  v_boonz_pct   numeric := 0.20;
  v_vox_pct     numeric := 0.80;
BEGIN
  WITH vox_machines AS (
    SELECT m.machine_id, m.official_name,
      CASE WHEN m.pod_location ILIKE '%Mercato%' THEN 'Mercato'
           WHEN m.pod_location ILIKE '%Mirdi%'   THEN 'Mirdif' ELSE 'Other' END AS site
    FROM machines m WHERE m.venue_group = 'VOX' AND m.status = 'Active'
  ),
  selected_machines AS (SELECT * FROM vox_machines WHERE site = ANY(p_pods)),
  vox_sales AS (
    SELECT sh.*, sm.site, sm.official_name,                         -- AC2: carry official_name
      regexp_replace(sh.internal_txn_sn, '_\d+$', '') AS base_txn_sn,
      COALESCE(sh.total_amount, sh.paid_amount, 0) AS effective_total,
      vpm.cost_incl_vat AS unit_cogs,
      (COALESCE(vpm.cost_incl_vat, 0) * COALESCE(sh.qty, 0))::numeric AS line_cogs
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
    -- machine_id/official_name are 1:1 with base_txn_sn; carry via GROUP BY (no max(uuid) aggregate)
    SELECT base_txn_sn, site, machine_id, official_name,   -- AC2 (was MAX(machine_mapping))
      MIN(transaction_date) AS transaction_date,
      SUM(effective_total) AS total_amount,
      SUM(COALESCE(paid_amount, 0)) AS paid_amount,
      SUM(COALESCE(refunded_amount, 0)) AS refunded_amount,
      SUM(COALESCE(qty, 0)) AS qty,
      SUM(line_cogs) AS boonz_cogs,
      string_agg(DISTINCT pod_product_name, ' | ' ORDER BY pod_product_name) AS items
    FROM vox_sales GROUP BY base_txn_sn, site, machine_id, official_name
  ),
  adyen_settled AS (
    SELECT a.merchant_reference,
           SUM(a.captured_amount_value) AS captured_settled,
           MAX(a.psp_reference) AS psp_reference
    FROM v_adyen_transactions_attributed a
    WHERE a.status='SettledBulk' AND a.transaction_type='Purchase'
      AND a.pos_transaction_date::date >= p_date_from - INTERVAL '7 days'
      AND a.pos_transaction_date::date <= p_date_to + INTERVAL '7 days'
    GROUP BY a.merchant_reference
  ),
  adyen_refunds AS (
    SELECT a.merchant_reference,
           SUM(a.captured_amount_value) AS captured_refunded,
           SUM(COALESCE(a.adjusted_amount_value, 0)) AS refund_returned
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
      COALESCE(s.captured_settled, 0)  AS captured_settled,
      COALESCE(r.captured_refunded, 0) AS captured_refunded,
      COALESCE(r.refund_returned, 0)   AS refund_returned,
      COALESCE(cr.cash_recovered, 0)   AS cash_recovered,
      (COALESCE(s.captured_settled, 0) + COALESCE(r.captured_refunded, 0) - COALESCE(r.refund_returned, 0)) AS adyen_captured_net,
      s.psp_reference
    FROM vox_txns t
    LEFT JOIN adyen_settled s ON s.merchant_reference = t.base_txn_sn
    LEFT JOIN adyen_refunds r ON r.merchant_reference = t.base_txn_sn
    LEFT JOIN cash_recovered_by_ref cr ON cr.merchant_reference = t.base_txn_sn
  ),
  txn_waterfall AS (
    SELECT
      base_txn_sn, transaction_date, site, machine_id, official_name, items,   -- AC2
      qty AS units, total_amount,
      (adyen_captured_net + cash_recovered) AS captured_amount,
      adyen_captured_net AS adyen_captured,
      cash_recovered,
      CASE WHEN psp_reference IS NOT NULL OR captured_refunded > 0 OR cash_recovered > 0
           THEN GREATEST(total_amount - (adyen_captured_net + cash_recovered), 0)
           ELSE 0 END AS default_amount,
      refund_returned AS refunded_amount,
      CASE WHEN psp_reference IS NOT NULL
           THEN ROUND(v_adyen_fixed + (adyen_captured_net * v_adyen_pct), 3)
           ELSE 0 END AS adyen_fees,
      psp_reference,
      (psp_reference IS NOT NULL OR captured_refunded > 0 OR cash_recovered > 0) AS is_matched,
      boonz_cogs
    FROM vox_joined
  ),
  txn_final AS (
    SELECT *,
      (captured_amount - refunded_amount - adyen_fees) AS net_revenue_calc,
      ROUND((captured_amount - refunded_amount - adyen_fees) * v_boonz_pct, 3) AS boonz_share,
      ROUND((captured_amount - refunded_amount - adyen_fees) * v_vox_pct,   3) AS vox_share,
      ROUND(((captured_amount - refunded_amount - adyen_fees) * v_vox_pct) - boonz_cogs, 3) AS vox_net_dues
    FROM txn_waterfall
  )
  SELECT jsonb_build_object(
    'params', jsonb_build_object(
      'date_from', p_date_from, 'date_to', p_date_to, 'pods', p_pods,
      'adyen_fixed_fee', v_adyen_fixed, 'adyen_pct_fee', v_adyen_pct,
      'boonz_share_pct', v_boonz_pct, 'vox_share_pct', v_vox_pct,
      'cash_recovery_included', true
    ),
    'waterfall', jsonb_build_object(
      'total_amount',     COALESCE(ROUND(SUM(total_amount),    2), 0),
      'default_amount',   COALESCE(ROUND(SUM(default_amount),  2), 0),
      'captured_amount',  COALESCE(ROUND(SUM(captured_amount), 2), 0),
      'adyen_captured',   COALESCE(ROUND(SUM(adyen_captured),  2), 0),
      'cash_recovered',   COALESCE(ROUND(SUM(cash_recovered),  2), 0),
      'refund_amount',    COALESCE(ROUND(SUM(refunded_amount), 2), 0),
      'adyen_fees',       COALESCE(ROUND(SUM(adyen_fees),      2), 0),
      'net_revenue',      COALESCE(ROUND(SUM(net_revenue_calc),2), 0),
      'boonz_share',      COALESCE(ROUND(SUM(boonz_share),     2), 0),
      'vox_share',        COALESCE(ROUND(SUM(vox_share),       2), 0),
      'boonz_cogs',       COALESCE(ROUND(SUM(boonz_cogs),      2), 0),
      'vox_net_dues',     COALESCE(ROUND(SUM(vox_net_dues),    2), 0),
      'txn_count',        COUNT(*),
      'matched_txns',     COUNT(*) FILTER (WHERE is_matched),
      'unmatched_txns',   COUNT(*) FILTER (WHERE NOT is_matched),
      'units_sold',       COALESCE(SUM(units), 0),
      'default_rate_pct', CASE WHEN SUM(total_amount) FILTER (WHERE is_matched) > 0
                               THEN ROUND(SUM(default_amount) /
                                 SUM(total_amount) FILTER (WHERE is_matched) * 100, 2)
                               ELSE 0 END,
      'cogs_ratio_pct',   CASE WHEN SUM(captured_amount) > 0
                               THEN ROUND(SUM(boonz_cogs)/SUM(captured_amount)*100, 2)
                               ELSE 0 END,
      'adyen_fee_pct',    CASE WHEN SUM(captured_amount) > 0
                               THEN ROUND(SUM(adyen_fees)/SUM(captured_amount)*100, 2)
                               ELSE 0 END,
      'boonz_total_receipts', COALESCE(ROUND(SUM(boonz_share) + SUM(boonz_cogs), 2), 0)
    ),
    'by_site', (
      SELECT COALESCE(jsonb_agg(row_to_json(s)::jsonb ORDER BY s.site), '[]'::jsonb)
      FROM (
        SELECT site,
          ROUND(SUM(total_amount),    2) AS total_amount,
          ROUND(SUM(captured_amount), 2) AS captured_amount,
          ROUND(SUM(adyen_captured),  2) AS adyen_captured,
          ROUND(SUM(cash_recovered),  2) AS cash_recovered,
          ROUND(SUM(default_amount),  2) AS default_amount,
          ROUND(SUM(adyen_fees),      2) AS adyen_fees,
          ROUND(SUM(net_revenue_calc),2) AS net_revenue,
          ROUND(SUM(boonz_share),     2) AS boonz_share,
          ROUND(SUM(vox_share),       2) AS vox_share,
          ROUND(SUM(boonz_cogs),      2) AS boonz_cogs,
          ROUND(SUM(vox_net_dues),    2) AS vox_net_dues,
          COUNT(*) AS txns, SUM(units) AS units
        FROM txn_final GROUP BY site
      ) s
    ),
    'transactions', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'txn_base',        base_txn_sn,
        'merchant_ref',    base_txn_sn,
        'psp',             COALESCE(LEFT(psp_reference,16), '-'),
        'psp_reference',   psp_reference,
        'matched',         is_matched,
        'txn_date',        transaction_date,
        'site',            site,
        'machine',         official_name,            -- AC2 (was machine_mapping)
        'machine_id',      machine_id,
        'items',           items,
        'units',           units,
        'total_amount',    total_amount,
        'captured_amount', captured_amount,
        'adyen_captured',  adyen_captured,
        'cash_recovered',  cash_recovered,
        'default_amount',  default_amount,
        'refunded_amount', refunded_amount,
        'adyen_fees',      adyen_fees,
        'net_revenue',     net_revenue_calc,
        'boonz_share',     boonz_share,
        'vox_share',       vox_share,
        'boonz_cogs',      boonz_cogs,
        'vox_net_dues',    vox_net_dues
      ) ORDER BY transaction_date DESC), '[]'::jsonb)
      FROM txn_final
    )
  ) INTO v_result FROM txn_final;
  RETURN v_result;
END;
$function$;


-- ============================================================================
-- (b) get_vox_consumer_report -- AC1(P2 refund netting) + AC2(machine_id) + AC3(p_machine) + AC6(total_captured)
--     J1: DROP + CREATE to add p_machine without a second overload (PGRST203 safe). Callers use named params.
-- ============================================================================
DROP FUNCTION IF EXISTS public.get_vox_consumer_report(text[], boolean, date, date);

CREATE OR REPLACE FUNCTION public.get_vox_consumer_report(
  p_pods text[] DEFAULT ARRAY['Mercato'::text, 'Mirdif'::text],
  p_consolidated boolean DEFAULT true,
  p_date_from date DEFAULT '2026-02-06'::date,
  p_date_to date DEFAULT CURRENT_DATE,
  p_machine uuid DEFAULT NULL)                                  -- AC3 (J1)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET "TimeZone" TO 'Asia/Dubai'
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
      SELECT sh.*, sm.site, sm.machine_name AS official_name,           -- AC2: carry official_name
        regexp_replace(sh.internal_txn_sn, '_\d+$', '') AS base_txn_sn,
        COALESCE(sh.paid_amount, 0) AS effective_paid,
        COALESCE(sh.total_amount, sh.paid_amount, 0) AS effective_total,
        SUM(COALESCE(sh.total_amount, 0) + COALESCE(sh.paid_amount, 0))
          OVER (PARTITION BY regexp_replace(sh.internal_txn_sn, '_\d+$', '')) AS basket_amount
      FROM sales_history sh JOIN selected_machines sm ON sm.machine_id = sh.machine_id
      WHERE sh.transaction_date::date >= p_date_from AND sh.transaction_date::date <= p_date_to
        AND (p_machine IS NULL OR sh.machine_id = p_machine)             -- AC3 server-side scope
    ) q
    WHERE basket_amount > 0
  ),
  vox_txns AS (
    -- machine_id/official_name are 1:1 with base_txn_sn; carry via GROUP BY (no max(uuid) aggregate)
    SELECT base_txn_sn, site, machine_id, official_name,  -- AC2 (was MAX(machine_mapping))
      MIN(transaction_date) AS transaction_date,
      SUM(effective_total) AS total_amount, SUM(effective_paid) AS paid_amount,
      SUM(qty) AS qty,
      string_agg(DISTINCT pod_product_name, ' | ' ORDER BY pod_product_name) AS items
    FROM vox_sales GROUP BY base_txn_sn, site, machine_id, official_name
  ),
  -- AC1/P2: net refunds, mirror commercial RefundedBulk pattern. Replaces the raw, statusless
  -- adyen_transactions join (gross of refunds, and could multi-row a ref with both Settled+Refunded).
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
  vox_joined AS (
    SELECT t.*,
      (COALESCE(s.captured_settled,0) + COALESCE(r.captured_refunded,0) - COALESCE(r.refund_returned,0)) AS adyen_captured,
      COALESCE(cr.cash_recovered, 0) AS cash_recovered,
      (COALESCE(s.captured_settled,0) + COALESCE(r.captured_refunded,0) - COALESCE(r.refund_returned,0) + COALESCE(cr.cash_recovered,0)) AS captured,
      s.value_aed, s.funding_source, s.payment_method, s.token_payment_variant, s.psp_reference
    FROM vox_txns t
    LEFT JOIN adyen_settled s ON s.merchant_reference = t.base_txn_sn
    LEFT JOIN adyen_refunds r ON r.merchant_reference = t.base_txn_sn
    LEFT JOIN cash_recovered_by_ref cr ON cr.merchant_reference = t.base_txn_sn
  ),
  default_stats AS (
    SELECT COUNT(*) AS matched_txns, COALESCE(SUM(total_amount), 0) AS matched_total,
      COALESCE(SUM(captured), 0) AS matched_captured,
      COALESCE(SUM(GREATEST(total_amount - captured, 0)), 0) AS default_gap,
      COUNT(*) FILTER (WHERE total_amount - captured > 0.01) AS default_count
    FROM vox_joined WHERE psp_reference IS NOT NULL
  ),
  discrepancies AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'psp', psp_reference, 'merchant_ref', base_txn_sn,
      'date', to_char(transaction_date, 'DD Mon'), 'site', site, 'machine', official_name,   -- AC2
      'total', total_amount, 'captured', captured,
      'adyen_captured', COALESCE(adyen_captured, 0), 'cash_recovered', cash_recovered,
      'gap', ROUND(total_amount - captured, 2), 'items', items
    ) ORDER BY transaction_date DESC), '[]'::jsonb) AS data
    FROM vox_joined WHERE psp_reference IS NOT NULL AND total_amount - captured > 0.01
  ),
  summary AS (
    SELECT jsonb_build_object(
      'total_sales', COALESCE(SUM(total_amount), 0), 'total_paid', COALESCE(SUM(paid_amount), 0),
      'total_txns', COUNT(*), 'total_units', COALESCE(SUM(qty), 0),
      -- AC6 (J4): derive from matched set, not the adyen_full store_description join (returned NULL)
      'total_captured', COALESCE((SELECT SUM(captured) FROM vox_joined WHERE psp_reference IS NOT NULL), 0),
      'total_adyen_captured', COALESCE((SELECT SUM(adyen_captured) FROM vox_joined WHERE psp_reference IS NOT NULL), 0),
      'total_cash_recovered', COALESCE((SELECT SUM(cash_recovered) FROM vox_joined), 0),
      'adyen_txn_count', (SELECT COUNT(*) FROM vox_joined WHERE psp_reference IS NOT NULL),
      'num_machines', (SELECT COUNT(DISTINCT machine_id) FROM vox_sales),      -- AC2 (was DISTINCT machine_mapping)
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
  -- AC2: group machine aggregate by machine_id, display official_name (was machine_mapping)
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
      'machine', official_name, 'site', site,                                  -- AC2 (was machine_mapping)
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
      'gap', ROUND(GREATEST(COALESCE(total_amount,0) - captured, 0), 2),
      'units', qty, 'items', items,
      'disc', (psp_reference IS NOT NULL AND (total_amount - captured) > 0.01),
      'matched', (psp_reference IS NOT NULL),
      'pending', (psp_reference IS NULL AND transaction_date > now() - INTERVAL '48 hours'),
      'status', CASE
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
      'machine_filter', p_machine, 'data_source', 'supabase', 'cash_recovery_included', true)
  ) INTO v_result;
  RETURN v_result;
END;
$function$;


-- ============================================================================
-- (c) get_vox_commercial_txn_lines -- NEW, read-only. AC4 SKU-level export.
--     One row per sales_history line, ALL lines (Boonz + venue-sourced). Txn money repeated per line (txn_*).
--     Reuses the commercial RPC's per-txn waterfall so txn_captured/default match the cards exactly.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_vox_commercial_txn_lines(
  p_pods text[] DEFAULT ARRAY['Mercato'::text, 'Mirdif'::text],
  p_date_from date DEFAULT '2026-02-06'::date,
  p_date_to date DEFAULT CURRENT_DATE)
 RETURNS TABLE(
   base_txn_sn text, psp_reference text, transaction_date timestamptz,
   site text, machine text, pod_product_name text,
   qty numeric, unit_price numeric, line_total numeric,
   unit_cogs numeric, line_cogs numeric, supply_source text,
   txn_captured numeric, txn_default numeric, txn_refunded numeric, txn_status text)
 LANGUAGE sql
 STABLE
 SET "TimeZone" TO 'Asia/Dubai'
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
           ELSE vpm.source_of_supply END AS supply_source,  -- J2: three-valued (Boonz/VOX/LLFP); unmapped surfaced, not folded
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
      COALESCE(r.refund_returned,0) AS refunded_amount,
      (s.psp_reference IS NOT NULL OR COALESCE(r.captured_refunded,0) > 0 OR COALESCE(cr.cash_recovered,0) > 0) AS is_matched,
      t.total_amount
    FROM vox_txns t
    LEFT JOIN adyen_settled s ON s.merchant_reference = t.base_txn_sn
    LEFT JOIN adyen_refunds r ON r.merchant_reference = t.base_txn_sn
    LEFT JOIN cash_recovered_by_ref cr ON cr.merchant_reference = t.base_txn_sn
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
    CASE WHEN tm.is_matched AND (tm.total_amount - COALESCE(tm.captured_amount,0)) <= 0.01 THEN 'matched'
         WHEN tm.is_matched THEN 'discrepancy'
         ELSE 'unmatched' END AS txn_status
  FROM vox_sales vs
  LEFT JOIN txn_money tm ON tm.base_txn_sn = vs.base_txn_sn
  ORDER BY vs.transaction_date DESC, vs.base_txn_sn, vs.pod_product_name;
$function$;


-- ============================================================================
-- (d) GRANTs -- AC5. J3: no dedicated VOX Postgres role (vox_admin is an app_metadata claim; /api/vox/*
--     routes call as service_role). CS decision: DROP anon. Confirmed no client-side anon rpc() to these.
--     NOTE: CREATE-d functions default to PUBLIC EXECUTE, so REVOKE FROM PUBLIC, anon then grant narrow.
-- ============================================================================
REVOKE EXECUTE ON FUNCTION public.get_vox_commercial_report(text[], date, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_vox_commercial_report(text[], date, date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_vox_consumer_report(text[], boolean, date, date, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_vox_consumer_report(text[], boolean, date, date, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_vox_commercial_txn_lines(text[], date, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_vox_commercial_txn_lines(text[], date, date) TO authenticated, service_role;

-- ============================================================================
-- POST-APPLY PARITY HARNESS (run in a rolled-back tx after apply; do NOT ship if any fails):
--   1. get_vox_commercial_report(...,'2026-02-06','2026-04-30')->'waterfall' == reference (unchanged).
--   2. (get_vox_consumer_report ribbon fields) tracked by FE -> commercial; consumer num_machines = 8.
--   3. SELECT SUM(line_total), SUM(line_cogs), COUNT(DISTINCT base_txn_sn) FROM get_vox_commercial_txn_lines(...)
--      == 36,940.00 / 1,878.02 / 1592.
--   4. ACTIVATE-2005 appears once in commercial transactions[].machine for a window spanning 28 Apr.
--   5. get_vox_consumer_report(p_machine := <VOXMCC-1005 id>) products revenue == that machine's agg row.
--   6. A5 regression: decommission crediting untouched (no change in this migration set).
-- ============================================================================
