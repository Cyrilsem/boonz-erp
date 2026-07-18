-- ROLLBACK for 20260718090001_rc08a_canonical_wh_availability.sql
-- All objects here are additive/read-only. Rollback = drop the new functions and
-- restore v_wh_pickable to its pre-A column list. No data change -> instant.
--
-- ORDER: if RC-01 (090002) is live, its push binds wh_fefo_for_line — roll back RC-01
-- FIRST (rc01_rollback.sql) so nothing references wh_fefo_for_line, THEN run this.

DROP FUNCTION IF EXISTS public.wh_fefo_for_line(uuid, uuid, date, numeric, uuid[]);
DROP FUNCTION IF EXISTS public.wh_available_qty(uuid, uuid, date);
DROP FUNCTION IF EXISTS public.wh_available(uuid, date);

-- Restore v_wh_pickable to its pre-A definition (drops the 2 additive columns).
-- security_invoker=true preserved (verified live reloption 2026-07-18).
CREATE OR REPLACE VIEW public.v_wh_pickable
WITH (security_invoker = true) AS
 WITH dubai AS (
         SELECT (now() AT TIME ZONE 'Asia/Dubai'::text)::date AS today
        )
 SELECT wi.wh_inventory_id,
    wi.boonz_product_id,
    wi.warehouse_id,
    wi.wh_location,
    wi.batch_id,
    wi.warehouse_stock,
    wi.expiration_date,
    wi.reserved_for_machine_id,
    wi.snapshot_date
   FROM warehouse_inventory wi
     CROSS JOIN dubai d
  WHERE wi.status = 'Active'::text
    AND NOT COALESCE(wi.quarantined, false)
    AND (wi.expiration_date >= d.today OR wi.expiration_date IS NULL)
    AND wi.warehouse_stock > 0::numeric;

-- wh_central_id() is a harmless read-only helper. Drop ONLY after RC-08-B is rolled
-- back (its de-magicked functions call it). If B is still live, KEEP this function.
-- DROP FUNCTION IF EXISTS public.wh_central_id();
