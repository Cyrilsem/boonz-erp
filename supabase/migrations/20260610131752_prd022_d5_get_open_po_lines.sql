-- PRD-022 D5 — read-only reader for open PO lines (powers D1 ordered-state chips + D3 Open POs list).
-- Migration name: prd022_d5_get_open_po_lines
-- Articles: 4 (read-only DEFINER), 1 (no writes). The only new DB object in PRD-022 beyond DF1/DF2.
--
-- "Open" line = received_date IS NULL AND not cancelled (purchase_outcome <> 'not_purchased') —
-- IDENTICAL to the on_order definition in get_procurement_demand, so the D1 chips reconcile with
-- the RPC's on_order column. Server-side supplier filter (no fetch-then-filter). DEFINER for parity
-- with the other procurement readers (get_procurement_demand*), reading the same RLS-gated sources.

CREATE OR REPLACE FUNCTION public.get_open_po_lines(p_supplier_id uuid DEFAULT NULL)
RETURNS TABLE(
  po_line_id          uuid,
  po_id               text,
  po_number           integer,
  supplier_id         uuid,
  supplier_name       text,
  boonz_product_id    uuid,
  boonz_product_name  text,
  ordered_qty         numeric,
  price_per_unit_aed  numeric,
  expiry_date         date,
  purchase_date       date,
  age_days            integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT
    po.po_line_id,
    po.po_id,
    po.po_number,
    po.supplier_id,
    s.supplier_name,
    po.boonz_product_id,
    bp.boonz_product_name,
    po.ordered_qty,
    po.price_per_unit_aed,
    po.expiry_date,
    po.purchase_date,
    (CURRENT_DATE - po.purchase_date)::int AS age_days
  FROM public.purchase_orders po
  LEFT JOIN public.suppliers      s  ON s.supplier_id = po.supplier_id
  LEFT JOIN public.boonz_products bp ON bp.product_id = po.boonz_product_id
  WHERE po.received_date IS NULL
    AND COALESCE(po.purchase_outcome, '') <> 'not_purchased'
    AND (p_supplier_id IS NULL OR po.supplier_id = p_supplier_id)
  ORDER BY po.purchase_date DESC, po.po_id, bp.boonz_product_name;
$function$;

GRANT EXECUTE ON FUNCTION public.get_open_po_lines(uuid) TO authenticated, service_role;

COMMENT ON FUNCTION public.get_open_po_lines(uuid) IS
  'PRD-022 D5. Read-only open PO lines (received_date IS NULL AND purchase_outcome <> not_purchased) - same definition as get_procurement_demand.on_order so chips reconcile. Optional server-side supplier filter. Powers /app/procurement D1 ordered-state chips + D3 Open POs drawer list. age_days = CURRENT_DATE - purchase_date.';
