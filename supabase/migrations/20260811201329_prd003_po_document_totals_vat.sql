-- PRD-003 — PO Document Totals: VAT, Discounts, Adjustments, Grand Total
-- Dara design + Cody verdict (9 binding conditions C-0..C-9) in docs/prds/procurement/PRD-003-REPORT.md
-- Articles: 1, 2, 3+S-308, 4, 6, 8, 12, 16.

-- 1. purchase_order_totals
CREATE TABLE IF NOT EXISTS public.purchase_order_totals (
  po_id                          text PRIMARY KEY,
  lines_subtotal_ex_vat_aed      numeric(12,2) NOT NULL DEFAULT 0,
  additions_subtotal_ex_vat_aed  numeric(12,2) NOT NULL DEFAULT 0,
  subtotal_ex_vat_aed            numeric(12,2) NOT NULL,
  discount_aed                   numeric(12,2) NOT NULL DEFAULT 0 CHECK (discount_aed >= 0),
  discount_label                 text,
  vat_rate                       numeric(6,4) NOT NULL DEFAULT 0.05
                                   CHECK (vat_rate >= 0 AND vat_rate <= 1),
  vat_aed                        numeric(12,2) NOT NULL DEFAULT 0 CHECK (vat_aed >= 0),
  vat_auto_aed                   numeric(12,2) NOT NULL DEFAULT 0,
  vat_is_override                boolean       NOT NULL DEFAULT false,
  other_adjustment_aed           numeric(12,2) NOT NULL DEFAULT 0,
  other_adjustment_label         text,
  grand_total_aed                numeric(12,2) NOT NULL,
  supplier_invoice_number        text,
  supplier_invoice_date          date,
  supplier_invoice_total_aed     numeric(12,2),
  line_price_regime              text NOT NULL DEFAULT 'unknown'
                                   CHECK (line_price_regime IN ('ex_vat','vat_inclusive','unknown')),
  source                         text NOT NULL DEFAULT 'receiving'
                                   CHECK (source IN ('receiving','edit','backfill')),
  created_at                     timestamptz NOT NULL DEFAULT now(),
  created_by                     uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  last_edited_at                 timestamptz,
  last_edited_by                 uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  CONSTRAINT po_totals_subtotal_split_coherent CHECK (
    subtotal_ex_vat_aed = lines_subtotal_ex_vat_aed + additions_subtotal_ex_vat_aed),
  CONSTRAINT po_totals_grand_total_coherent CHECK (
    grand_total_aed = subtotal_ex_vat_aed - discount_aed + vat_aed + other_adjustment_aed),
  CONSTRAINT po_totals_discount_labelled CHECK (
    discount_aed = 0 OR (discount_label IS NOT NULL AND length(btrim(discount_label)) > 0)),
  CONSTRAINT po_totals_adjustment_labelled CHECK (
    other_adjustment_aed = 0 OR (other_adjustment_label IS NOT NULL AND length(btrim(other_adjustment_label)) > 0))
);

COMMENT ON TABLE public.purchase_order_totals IS
  'PRD-003. Document-level PO financials: discount, recoverable input VAT, adjustments, grand total. Presentational / financial-reconciliation ONLY (PRD I-3). VAT here is a RECEIVABLE and must never reach warehouse_inventory, COGS or any Statement of Account (PRD I-2). Writes via set_po_document_totals only.';

CREATE INDEX IF NOT EXISTS idx_po_totals_invoice_date
  ON public.purchase_order_totals (supplier_invoice_date) WHERE supplier_invoice_date IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_po_totals_created_at
  ON public.purchase_order_totals (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_po_additions_po_status
  ON public.po_additions (po_id, status);

ALTER TABLE public.purchase_order_totals ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS po_totals_select    ON public.purchase_order_totals;
DROP POLICY IF EXISTS po_totals_no_insert ON public.purchase_order_totals;
DROP POLICY IF EXISTS po_totals_no_update ON public.purchase_order_totals;
DROP POLICY IF EXISTS po_totals_no_delete ON public.purchase_order_totals;
CREATE POLICY po_totals_select    ON public.purchase_order_totals FOR SELECT TO authenticated USING (true);
CREATE POLICY po_totals_no_insert ON public.purchase_order_totals FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY po_totals_no_update ON public.purchase_order_totals FOR UPDATE TO authenticated USING (false);
CREATE POLICY po_totals_no_delete ON public.purchase_order_totals FOR DELETE TO authenticated USING (false);

-- C-1 (Article 3 + S-308): the write verbs are held by DEFAULT PRIVILEGE and must be revoked by name.
REVOKE ALL ON public.purchase_order_totals FROM anon, PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.purchase_order_totals FROM authenticated;
GRANT SELECT ON public.purchase_order_totals TO authenticated;
GRANT ALL    ON public.purchase_order_totals TO service_role;

-- 2. purchase_orders.source_addition_id
ALTER TABLE public.purchase_orders ADD COLUMN IF NOT EXISTS source_addition_id uuid;
COMMENT ON COLUMN public.purchase_orders.source_addition_id IS
  'PRD-003. Non-NULL when this line was mirrored from a po_additions row at receive time. NULL on every legacy line - there is deliberately NO backfill: historical po_additions.price_per_unit_aed values are pack totals, not unit prices (46 rows, AED 23.6k of fiction if mirrored). Consumers that count warehouse intake MUST exclude a po_additions row whose addition_id appears here, or the units are counted twice.';
CREATE UNIQUE INDEX IF NOT EXISTS uq_purchase_orders_source_addition
  ON public.purchase_orders (source_addition_id) WHERE source_addition_id IS NOT NULL;

-- 3. v_po_document_totals (Article 16 canonical object)
DROP VIEW IF EXISTS public.v_po_document_totals;
CREATE VIEW public.v_po_document_totals AS
WITH po_ids AS (
  SELECT po_id FROM public.purchase_orders
  UNION SELECT po_id FROM public.po_additions WHERE status = 'received'
  UNION SELECT po_id FROM public.purchase_order_totals
),
line_agg AS (
  SELECT l.po_id,
         ROUND(COALESCE(SUM(l.total_price_aed)
           FILTER (WHERE COALESCE(l.purchase_outcome,'') <> 'not_purchased'), 0), 2) AS lines_ex_vat,
         COUNT(*) FILTER (WHERE COALESCE(l.purchase_outcome,'') <> 'not_purchased') AS live_line_count
    FROM public.purchase_orders l GROUP BY l.po_id
),
prod_median AS (
  SELECT l.boonz_product_id,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY l.price_per_unit_aed) AS med_unit_price
    FROM public.purchase_orders l
   WHERE l.purchase_outcome = 'received' AND l.price_per_unit_aed > 0
   GROUP BY l.boonz_product_id
),
addn_agg AS (
  SELECT a.po_id,
         ROUND(COALESCE(SUM(a.qty * COALESCE(a.price_per_unit_aed, 0)), 0), 2) AS additions_ex_vat,
         COUNT(*) AS unmirrored_count,
         BOOL_OR(pm.med_unit_price IS NOT NULL AND a.price_per_unit_aed > 3 * pm.med_unit_price) AS price_suspect
    FROM public.po_additions a
    LEFT JOIN prod_median pm ON pm.boonz_product_id = a.boonz_product_id
   WHERE a.status = 'received'
     AND NOT EXISTS (SELECT 1 FROM public.purchase_orders l2 WHERE l2.source_addition_id = a.addition_id)
   GROUP BY a.po_id
)
SELECT
  p.po_id,
  COALESCE(la.lines_ex_vat, 0)                                    AS live_lines_ex_vat_aed,
  COALESCE(aa.additions_ex_vat, 0)                                AS live_additions_ex_vat_aed,
  COALESCE(la.lines_ex_vat, 0) + COALESCE(aa.additions_ex_vat, 0) AS live_subtotal_ex_vat_aed,
  COALESCE(la.live_line_count, 0)                                 AS live_line_count,
  COALESCE(aa.unmirrored_count, 0)                                AS live_unmirrored_additions,
  COALESCE(aa.price_suspect, false)                               AS additions_price_suspect,
  (t.po_id IS NOT NULL)                                           AS has_totals,
  t.lines_subtotal_ex_vat_aed, t.additions_subtotal_ex_vat_aed, t.subtotal_ex_vat_aed,
  t.discount_aed, t.discount_label,
  t.vat_rate, t.vat_aed, t.vat_auto_aed, t.vat_is_override,
  t.other_adjustment_aed, t.other_adjustment_label,
  t.grand_total_aed,
  t.supplier_invoice_number, t.supplier_invoice_date, t.supplier_invoice_total_aed,
  t.line_price_regime, t.source,
  t.created_at, t.created_by, t.last_edited_at, t.last_edited_by,
  CASE WHEN t.po_id IS NULL OR t.supplier_invoice_total_aed IS NULL THEN NULL
       ELSE ROUND(t.grand_total_aed - t.supplier_invoice_total_aed, 2) END AS invoice_variance_aed,
  (t.po_id IS NOT NULL AND (
       t.lines_subtotal_ex_vat_aed     IS DISTINCT FROM COALESCE(la.lines_ex_vat, 0)
    OR t.additions_subtotal_ex_vat_aed IS DISTINCT FROM COALESCE(aa.additions_ex_vat, 0)
  )) AS totals_stale
FROM po_ids p
LEFT JOIN line_agg la                    ON la.po_id = p.po_id
LEFT JOIN addn_agg aa                    ON aa.po_id = p.po_id
LEFT JOIN public.purchase_order_totals t ON t.po_id  = p.po_id;

COMMENT ON VIEW public.v_po_document_totals IS
  'PRD-003, Article 16 canonical object for "PO document grand total" and "recoverable input VAT". All consumers read this; no FE or RPC re-derives the arithmetic. Financial reconciliation only - no refill/packing/dispatch path may read it (PRD I-3).';

REVOKE ALL ON public.v_po_document_totals FROM anon, PUBLIC;
GRANT SELECT ON public.v_po_document_totals TO authenticated, service_role;

-- 4. C-3 BLOCKING: v_daily_flow_reconciliation must not double-count a mirrored addition.
-- The incumbent adds procurement_in_po + procurement_in_additions into net_wh_flow. A mirrored
-- addition carries received_qty on its line AND still exists in po_additions, so without the two
-- NOT EXISTS clauses below every mirrored addition overstates warehouse intake by exactly its
-- quantity, per product, per day, forever. Body is otherwise byte-faithful to the incumbent and
-- the column list is unchanged, so no consumer breaks.
CREATE OR REPLACE VIEW public.v_daily_flow_reconciliation AS
 WITH date_product AS (
         SELECT DISTINCT purchase_orders.received_date AS reconciliation_date,
            purchase_orders.boonz_product_id
           FROM purchase_orders
          WHERE purchase_orders.received_date IS NOT NULL AND purchase_orders.boonz_product_id IS NOT NULL
        UNION
         SELECT DISTINCT po_additions.received_at::date AS received_at,
            po_additions.boonz_product_id
           FROM po_additions
          WHERE po_additions.received_at IS NOT NULL AND po_additions.status = 'received'::text
            AND po_additions.boonz_product_id IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM purchase_orders l WHERE l.source_addition_id = po_additions.addition_id)
        UNION
         SELECT DISTINCT refill_dispatching.dispatch_date, refill_dispatching.boonz_product_id
           FROM refill_dispatching
          WHERE refill_dispatching.dispatch_date IS NOT NULL AND refill_dispatching.boonz_product_id IS NOT NULL
        UNION
         SELECT DISTINCT sales_history.transaction_date::date AS transaction_date, sales_history.boonz_product_id
           FROM sales_history
          WHERE sales_history.transaction_date IS NOT NULL AND sales_history.boonz_product_id IS NOT NULL
        ), po_in AS (
         SELECT purchase_orders.received_date AS d, purchase_orders.boonz_product_id,
            sum(purchase_orders.received_qty) AS qty_in
           FROM purchase_orders
          WHERE purchase_orders.received_date IS NOT NULL AND purchase_orders.received_qty IS NOT NULL
          GROUP BY purchase_orders.received_date, purchase_orders.boonz_product_id
        ), addn_in AS (
         SELECT po_additions.received_at::date AS d, po_additions.boonz_product_id,
            sum(po_additions.qty) AS qty_in
           FROM po_additions
          WHERE po_additions.received_at IS NOT NULL AND po_additions.status = 'received'::text
            AND NOT EXISTS (SELECT 1 FROM purchase_orders l WHERE l.source_addition_id = po_additions.addition_id)
          GROUP BY (po_additions.received_at::date), po_additions.boonz_product_id
        ), returns_in AS (
         SELECT refill_dispatching.dispatch_date AS d, refill_dispatching.boonz_product_id,
            sum(refill_dispatching.quantity) AS qty_in
           FROM refill_dispatching
          WHERE (refill_dispatching.action = ANY (ARRAY['Remove'::text, 'REMOVE'::text]))
            AND refill_dispatching.returned = true AND refill_dispatching.dispatched = true
            AND refill_dispatching.boonz_product_id IS NOT NULL
          GROUP BY refill_dispatching.dispatch_date, refill_dispatching.boonz_product_id
        ), packs_out AS (
         SELECT refill_dispatching.dispatch_date AS d, refill_dispatching.boonz_product_id,
            sum(refill_dispatching.quantity) AS qty_out
           FROM refill_dispatching
          WHERE (refill_dispatching.action = ANY (ARRAY['Refill'::text, 'Add New'::text, 'Add'::text]))
            AND refill_dispatching.packed = true AND refill_dispatching.boonz_product_id IS NOT NULL
          GROUP BY refill_dispatching.dispatch_date, refill_dispatching.boonz_product_id
        ), sales_out AS (
         SELECT sales_history.transaction_date::date AS d, sales_history.boonz_product_id,
            sum(sales_history.qty) AS qty_out
           FROM sales_history
          WHERE sales_history.transaction_date IS NOT NULL AND sales_history.boonz_product_id IS NOT NULL
          GROUP BY (sales_history.transaction_date::date), sales_history.boonz_product_id
        )
 SELECT dp.reconciliation_date, dp.boonz_product_id,
    COALESCE(po.qty_in, 0::numeric) AS procurement_in_po,
    COALESCE(ad.qty_in, 0::numeric) AS procurement_in_additions,
    COALESCE(rt.qty_in, 0::numeric) AS wh_in_from_returns,
    COALESCE(pk.qty_out, 0::numeric) AS wh_out_to_packs,
    COALESCE(sl.qty_out, 0::numeric) AS sales_out,
    COALESCE(po.qty_in, 0::numeric) + COALESCE(ad.qty_in, 0::numeric) + COALESCE(rt.qty_in, 0::numeric)
      - COALESCE(pk.qty_out, 0::numeric) AS net_wh_flow
   FROM date_product dp
     LEFT JOIN po_in po ON po.d = dp.reconciliation_date AND po.boonz_product_id = dp.boonz_product_id
     LEFT JOIN addn_in ad ON ad.d = dp.reconciliation_date AND ad.boonz_product_id = dp.boonz_product_id
     LEFT JOIN returns_in rt ON rt.d = dp.reconciliation_date AND rt.boonz_product_id = dp.boonz_product_id
     LEFT JOIN packs_out pk ON pk.d = dp.reconciliation_date AND pk.boonz_product_id = dp.boonz_product_id
     LEFT JOIN sales_out sl ON sl.d = dp.reconciliation_date AND sl.boonz_product_id = dp.boonz_product_id;
