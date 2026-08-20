-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- VOX SOA reconciliation wave (recon_fix1..6, 2026-07-28). Rewrote v_adyen_transactions_attributed
-- to join machines/machine_terminal_history via LATERAL ... LIMIT 1 (was fanning out when >1 Active
-- machine claimed a terminal, doubling ~211 May-Jun VOX baskets / +6,039.83 phantom captured).
-- security_invoker=true preserved. Body below is the current live view definition, which already
-- reflects any later changes (CREATE OR REPLACE is idempotent for reconstruction purposes).

CREATE OR REPLACE VIEW public.v_adyen_transactions_attributed
WITH (security_invoker = true) AS
 SELECT a.adyen_txn_id,
    a.machine_id,
    a.psp_reference,
    a.merchant_reference,
    a.acquirer_reference,
    a.unique_terminal_id,
    a.store,
    a.store_description,
    a.creation_date,
    a.pos_transaction_date,
    a.timezone,
    a.value_aed,
    a.currency,
    a.payment_method,
    a.status,
    a.transaction_type,
    a.shopper_interaction,
    a.entry_mode,
    a.cvm_performed,
    a.cvm_result,
    a.issuer_country,
    a.shopper_country,
    a.funding_source,
    a.issuer,
    a.risk_score,
    a.card_number_summary,
    a.card_bin,
    a.store_and_forward,
    a.offline,
    a.captured_amount_value,
    a.captured_amount_currency,
    a.adjusted_amount_value,
    a.account_holder_name,
    a.user_name,
    a.created_at,
    a.token_payment_variant,
    COALESCE(h.attributed_name, m_current.official_name) AS attributed_machine_name,
    COALESCE(h.machine_id, m_current.machine_id) AS attributed_machine_id,
    COALESCE(h.attributed_venue_group, m_current.venue_group) AS attributed_venue_group,
        CASE
            WHEN h.history_id IS NOT NULL THEN 'historical_window'::text
            WHEN m_current.repurposed_at IS NOT NULL AND a.pos_transaction_date::date < m_current.repurposed_at THEN 'pre_repurpose_no_history'::text
            ELSE 'current'::text
        END AS attribution_source,
    a.refunded_amount_value,
    a.refund_date,
    a.net_captured_value
   FROM adyen_transactions a
     LEFT JOIN LATERAL ( SELECT m.official_name,
            m.machine_id,
            m.venue_group,
            m.repurposed_at
           FROM machines m
          WHERE m.adyen_unique_terminal_id = a.unique_terminal_id AND m.status = 'Active'::text
          ORDER BY m.official_name
         LIMIT 1) m_current ON true
     LEFT JOIN LATERAL ( SELECT h_1.history_id,
            h_1.attributed_name,
            h_1.machine_id,
            h_1.attributed_venue_group
           FROM machine_terminal_history h_1
          WHERE h_1.unique_terminal_id = a.unique_terminal_id AND a.pos_transaction_date::date >= h_1.effective_from AND a.pos_transaction_date::date < COALESCE(h_1.effective_until, 'infinity'::date)
          ORDER BY h_1.effective_from DESC
         LIMIT 1) h ON true;
