-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- UNDOCUMENTED in CHANGELOG.md / MIGRATIONS_REGISTRY.md / RPC_REGISTRY.md. Same-day continuation
-- (2026-07-29) immediately after 20260729113315_recon_fix7_commercial_boonz_borne_credit.sql
-- (schema_migrations version 20260729113355, 40s after fix7). Same VOX SOA reconciliation wave
-- as recon_fix1..5b (docs/architecture/CHANGELOG.md:2957-2959, RPC_REGISTRY.md:501).
--
-- Reconstructed by inspecting get_vox_commercial_report's live body: this migration's inferred
-- delta ("_net") is folding the `boonz_borne` credit (introduced by recon_fix7, prior migration)
-- INTO the net-revenue waterfall itself, rather than leaving it as an informational-only
-- waterfall figure: `net_revenue_calc`, `boonz_share`, `vox_share`, and `vox_net_dues` all read
-- `... + boonz_borne` in their formulas below. Net effect: a fully Boonz-absorbed basket still
-- contributes to net_revenue (and therefore to the boonz/vox split and vox_net_dues) instead of
-- silently vanishing from the commercial waterfall the way an ordinary unmatched default would.
-- GREEN — read directly off the live function body (no doc trace, not guessed).
-- NOTE: this function is CUMULATIVE (recon_fix4/5a/5b/6/7/7b, PLUS whatever recon_fix6 - owned
-- elsewhere, not in this reconstruction set - contributed). The body below is the full current
-- prod state, identical to the one shipped in 20260729113315 (fix7) since both migrations
-- landed within the same short apply window; CREATE OR REPLACE is idempotent across the
-- repeated re-application.

CREATE OR REPLACE FUNCTION public.get_vox_commercial_report(p_pods text[] DEFAULT ARRAY['Mercato'::text, 'Mirdif'::text], p_date_from date DEFAULT '2026-02-06'::date, p_date_to date DEFAULT CURRENT_DATE, p_include_transactions boolean DEFAULT true, p_txn_limit integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET "TimeZone" TO 'Asia/Dubai'
 SET statement_timeout TO '30s'
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
    SELECT sh.*, sm.site, sm.official_name,
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
    SELECT base_txn_sn, site, machine_id, official_name,
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
           SUM(COALESCE(a.refunded_amount_value, 0)) AS refund_returned
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
      (COALESCE(s.captured_settled, 0) + COALESCE(r.captured_refunded, 0)) AS adyen_captured_gross,
      (COALESCE(s.captured_settled, 0) + COALESCE(r.captured_refunded, 0) - COALESCE(r.refund_returned, 0)) AS adyen_captured_net,
      s.psp_reference
    FROM vox_txns t
    LEFT JOIN adyen_settled s ON s.merchant_reference = t.base_txn_sn
    LEFT JOIN adyen_refunds r ON r.merchant_reference = t.base_txn_sn
    LEFT JOIN cash_recovered_by_ref cr ON cr.merchant_reference = t.base_txn_sn
  ),
  txn_waterfall AS (
    SELECT
      base_txn_sn, transaction_date, site, machine_id, official_name, items,
      qty AS units, total_amount,
      (adyen_captured_gross + cash_recovered) AS captured_amount,
      adyen_captured_gross AS adyen_captured,
      cash_recovered,
      CASE WHEN psp_reference IS NOT NULL OR captured_refunded > 0 OR cash_recovered > 0
           THEN GREATEST(total_amount - (adyen_captured_gross + cash_recovered), 0)
           ELSE 0 END AS default_amount,
      refund_returned AS refunded_amount,
      -- recon_fix7: totally unmatched baskets (no Adyen match, no cash recovery) are credited
      -- to Boonz in full rather than left as a plain unrecovered default.
      CASE WHEN psp_reference IS NULL AND captured_refunded = 0 AND cash_recovered = 0
           THEN total_amount ELSE 0 END AS boonz_borne,
      CASE WHEN psp_reference IS NOT NULL OR captured_refunded > 0
           THEN ROUND(v_adyen_fixed + (adyen_captured_net * v_adyen_pct), 3)
           ELSE 0 END AS adyen_fees,
      psp_reference,
      (psp_reference IS NOT NULL OR captured_refunded > 0 OR cash_recovered > 0) AS is_matched,
      boonz_cogs
    FROM vox_joined
  ),
  txn_final AS (
    SELECT *,
      -- recon_fix7b: boonz_borne folded into the net-revenue formula (this migration's delta).
      (captured_amount - refunded_amount - adyen_fees + boonz_borne) AS net_revenue_calc,
      ROUND((captured_amount - refunded_amount - adyen_fees + boonz_borne) * v_boonz_pct, 3) AS boonz_share,
      ROUND((captured_amount - refunded_amount - adyen_fees + boonz_borne) * v_vox_pct,   3) AS vox_share,
      ROUND(((captured_amount - refunded_amount - adyen_fees + boonz_borne) * v_vox_pct) - boonz_cogs, 3) AS vox_net_dues
    FROM txn_waterfall
  )
  SELECT jsonb_build_object(
    'params', jsonb_build_object(
      'date_from', p_date_from, 'date_to', p_date_to, 'pods', p_pods,
      'adyen_fixed_fee', v_adyen_fixed, 'adyen_pct_fee', v_adyen_pct,
      'boonz_share_pct', v_boonz_pct, 'vox_share_pct', v_vox_pct,
      'cash_recovery_included', true,
      'refund_source', 'refunded_amount_value'
    ),
    'waterfall', jsonb_build_object(
      'total_amount',     COALESCE(ROUND(SUM(total_amount),    2), 0),
      'unmatched_amount', COALESCE(ROUND(SUM(total_amount) FILTER (WHERE NOT is_matched), 2), 0),
      'boonz_borne_amount', COALESCE(ROUND(SUM(boonz_borne), 2), 0),
      'accounted_total',  COALESCE(ROUND(SUM(total_amount) FILTER (WHERE is_matched), 2), 0),
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
    'transactions', CASE WHEN p_include_transactions THEN (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'txn_base',        base_txn_sn,
        'merchant_ref',    base_txn_sn,
        'psp',             COALESCE(LEFT(psp_reference,16), '-'),
        'psp_reference',   psp_reference,
        'matched',         is_matched,
        'txn_date',        transaction_date,
        'site',            site,
        'machine',         official_name,
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
      FROM (SELECT * FROM txn_final ORDER BY transaction_date DESC LIMIT p_txn_limit) txn_final
    ) ELSE '[]'::jsonb END
  ) INTO v_result FROM txn_final;
  RETURN v_result;
END;
$function$;
