-- PRD-122 Phase 2, Guard G-B (DDL): mark test/E2E products so they can never land in
-- WH_CENTRAL again. Adds boonz_products.is_test and a BEFORE INSERT guard on
-- warehouse_inventory that rejects any is_test product. This migration is DDL only;
-- the data backfill (flagging existing TEST/E2E products) is a separate migration.
--
-- This guard does NOT retro-delete existing TEST rows already sitting in
-- warehouse_inventory -- that is Phase 3's purge_test_inventory, gated on CS approval.
--
-- Cody: Approve. Articles 2 (RLS already enabled on both tables), 12 (forward-only).
-- New column is a plain boolean flag, no new writer created; the trigger only rejects.

ALTER TABLE public.boonz_products ADD COLUMN IF NOT EXISTS is_test boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.enforce_no_test_product_in_warehouse()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_is_test boolean;
BEGIN
  SELECT is_test INTO v_is_test FROM public.boonz_products WHERE product_id = NEW.boonz_product_id;
  IF COALESCE(v_is_test, false) THEN
    RAISE EXCEPTION 'warehouse_inventory: boonz_product_id % is flagged is_test and may not be written to warehouse_inventory', NEW.boonz_product_id;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_enforce_no_test_product_in_warehouse ON public.warehouse_inventory;

CREATE TRIGGER trg_enforce_no_test_product_in_warehouse
BEFORE INSERT ON public.warehouse_inventory
FOR EACH ROW EXECUTE FUNCTION public.enforce_no_test_product_in_warehouse();
