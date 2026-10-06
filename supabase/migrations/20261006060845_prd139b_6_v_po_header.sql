-- PRD-139b Item 6: one canonical PO header status view.
--
-- Investigated before writing this (see docs/prds/PRD-139b-log.md): v_po_header does
-- not exist anywhere (clean slate). cancel_po_line sets purchase_outcome =
-- 'not_purchased' without touching received_date (confirmed live). Live distribution
-- of (purchase_outcome, received_date IS NOT NULL): ('not_purchased', false)=165,
-- ('not_purchased', true)=352, ('received', true)=1096, (NULL, false)=9 -- the
-- "received_lines" predicate is purchase_outcome='received' (not received_date alone,
-- since some not_purchased rows also carry a received_date from history before being
-- cancelled); "cancelled_lines" is purchase_outcome='not_purchased' regardless of
-- received_date; "open_lines" is exactly the spec's literal definition
-- (purchase_outcome IS NULL AND received_date IS NULL).

CREATE OR REPLACE VIEW public.v_po_header AS
SELECT
  po.po_id,
  MIN(po.po_number) AS po_number,
  (array_agg(po.supplier_id))[1] AS supplier_id,
  MIN(po.purchase_date) AS purchase_date,
  COUNT(*) AS lines,
  COALESCE(SUM(po.ordered_qty), 0) AS ordered_qty,
  COALESCE(SUM(po.received_qty), 0) AS received_qty,
  COUNT(*) FILTER (WHERE po.purchase_outcome IS NULL AND po.received_date IS NULL) AS open_lines,
  COUNT(*) FILTER (WHERE po.purchase_outcome = 'not_purchased') AS cancelled_lines,
  COUNT(*) FILTER (WHERE po.purchase_outcome = 'received') AS received_lines,
  CASE
    WHEN COUNT(*) FILTER (WHERE po.purchase_outcome = 'not_purchased') = COUNT(*)
      THEN 'Cancelled'
    WHEN COUNT(*) FILTER (WHERE po.purchase_outcome IS NULL AND po.received_date IS NULL) > 0
         AND COUNT(*) FILTER (WHERE po.purchase_outcome = 'received') = 0
      THEN 'Pending'
    WHEN COUNT(*) FILTER (WHERE po.purchase_outcome IS NULL AND po.received_date IS NULL) > 0
         AND COUNT(*) FILTER (WHERE po.purchase_outcome = 'received') > 0
      THEN 'Partial'
    WHEN COUNT(*) FILTER (WHERE po.purchase_outcome IS NULL AND po.received_date IS NULL) = 0
         AND COUNT(*) FILTER (WHERE po.purchase_outcome = 'received') > 0
         AND COUNT(*) FILTER (WHERE po.purchase_outcome = 'not_purchased') > 0
      THEN 'Closed short'
    WHEN COUNT(*) FILTER (WHERE po.purchase_outcome IS NULL AND po.received_date IS NULL) = 0
         AND COUNT(*) FILTER (WHERE po.purchase_outcome = 'not_purchased') = 0
      THEN 'Received'
    ELSE 'Pending'
  END AS status
FROM public.purchase_orders po
GROUP BY po.po_id;

-- New views in public are born anon-SELECT and authenticated-write by Supabase's
-- default privileges. Close that the same way Item 2A closed it for functions.
REVOKE ALL ON public.v_po_header FROM anon, PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.v_po_header FROM authenticated;
GRANT SELECT ON public.v_po_header TO authenticated, service_role;
