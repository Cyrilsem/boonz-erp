-- Delete the 3 duplicate rows created by today's pack re-save.
-- Identified by: same (machine_id, shelf_id, boonz_product_id, dispatch_date,
-- expiry_date) as a dispatched sibling, but dispatched=false and created_at
-- later than the sibling.
--
-- Scoped to today only. No other dates are touched.

WITH duplicates AS (
  SELECT a.dispatch_id
  FROM refill_dispatching a
  JOIN refill_dispatching b
    ON a.machine_id        = b.machine_id
   AND a.shelf_id          = b.shelf_id
   AND a.boonz_product_id  = b.boonz_product_id
   AND a.dispatch_date     = b.dispatch_date
   AND COALESCE(a.expiry_date, '1900-01-01'::date)
       = COALESCE(b.expiry_date, '1900-01-01'::date)
   AND a.action            = b.action
   AND a.dispatch_id       <> b.dispatch_id
  WHERE a.dispatch_date = CURRENT_DATE
    AND a.dispatched = false
    AND b.dispatched = true
    AND a.created_at > b.created_at
)
DELETE FROM refill_dispatching
WHERE dispatch_id IN (SELECT dispatch_id FROM duplicates);
