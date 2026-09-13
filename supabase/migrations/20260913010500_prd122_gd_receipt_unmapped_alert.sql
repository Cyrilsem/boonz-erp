-- PRD-122 Phase 2, Guard G-D: goods-receipt assortability alert.
-- AFTER INSERT trigger on warehouse_inventory -- never blocks receipt (the mission
-- explicitly requires receipt to always succeed). Fires when the new row has stock
-- and boonz_product_id has zero Active product_mapping anywhere in the fleet
-- (machine-specific or global). This is exactly the gap that let 180 units of
-- Hunter Canister land on 13 Sep with nothing objecting.
--
-- Note: this migration only ADDS an alert row on a real problem -- it does not change
-- any write behavior on a protected entity, so per the goal brief's own carve-out
-- ("guards that only ADD alerts do not [need Cody review]"), no Cody review was run.
--
-- Severity is written as 'critical', not 'high' as the goal brief phrased it --
-- monitoring_alerts.severity has a CHECK constraint allowing only
-- ('info','warning','critical'); 'critical' is the closest match to the brief's intent.
--
-- Backtested in a rolled-back transaction: inserting stock against a currently-unmapped
-- product (the original 3 Hunter Canister SKUs are now mapped by the 13 Sep hand-fix,
-- so a fresh unmapped product was used instead) raises a receipt_unmapped/critical
-- alert while the insert itself still succeeds; inserting a correctly-mapped product
-- (Aquafina - Regular) raises no alert.

CREATE OR REPLACE FUNCTION public.alert_on_unmapped_goods_receipt()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_mapped boolean;
BEGIN
  IF COALESCE(NEW.warehouse_stock, 0) > 0 THEN
    SELECT EXISTS (
      SELECT 1 FROM public.product_mapping pm
      WHERE pm.boonz_product_id = NEW.boonz_product_id AND pm.status = 'Active'
    ) INTO v_mapped;

    IF NOT v_mapped THEN
      INSERT INTO public.monitoring_alerts (source, severity, payload)
      VALUES (
        'receipt_unmapped',
        'critical',
        jsonb_build_object(
          'wh_inventory_id', NEW.wh_inventory_id,
          'boonz_product_id', NEW.boonz_product_id,
          'warehouse_stock', NEW.warehouse_stock,
          'batch_id', NEW.batch_id,
          'warehouse_id', NEW.warehouse_id,
          'created_at', NEW.created_at
        )
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_alert_on_unmapped_goods_receipt ON public.warehouse_inventory;

CREATE TRIGGER trg_alert_on_unmapped_goods_receipt
AFTER INSERT ON public.warehouse_inventory
FOR EACH ROW EXECUTE FUNCTION public.alert_on_unmapped_goods_receipt();
