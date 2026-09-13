-- PRD-122 Phase 2, Guard G-C: expiry-sanity guard on warehouse_inventory.
-- Rejects any expiration_date more than 3 years after created_at or more than 2 years
-- before it. Closes off fake-dated rows like the 8 "7 Days Hazelnut" rows dated 2031
-- (batch ids S5-<timestamp>-X/-Y, written by something outside the database).
--
-- Cody: Approve. Articles 2 (RLS already enabled, untouched), 12 (forward-only).
-- Pure rejection guard, no new writer, no new alerts.
--
-- Backtested in a rolled-back transaction: all 8 2031-dated Active CENTRAL rows
-- rejected on touch; all 137 other Active CENTRAL rows (145 total) pass unchanged.

CREATE OR REPLACE FUNCTION public.enforce_warehouse_expiry_sanity()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_created date := COALESCE(NEW.created_at, now())::date;
BEGIN
  IF NEW.expiration_date IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.expiration_date > v_created + interval '3 years' THEN
    RAISE EXCEPTION 'warehouse_inventory.expiration_date: % is more than 3 years after created_at (%) for wh_inventory_id %', NEW.expiration_date, v_created, NEW.wh_inventory_id;
  END IF;

  IF NEW.expiration_date < v_created - interval '2 years' THEN
    RAISE EXCEPTION 'warehouse_inventory.expiration_date: % is more than 2 years before created_at (%) for wh_inventory_id %', NEW.expiration_date, v_created, NEW.wh_inventory_id;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_enforce_warehouse_expiry_sanity ON public.warehouse_inventory;

CREATE TRIGGER trg_enforce_warehouse_expiry_sanity
BEFORE INSERT OR UPDATE OF expiration_date ON public.warehouse_inventory
FOR EACH ROW EXECUTE FUNCTION public.enforce_warehouse_expiry_sanity();
