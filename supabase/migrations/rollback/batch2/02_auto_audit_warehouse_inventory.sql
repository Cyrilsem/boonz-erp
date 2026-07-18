-- ROLLBACK: restore live pre-Batch-2 body of auto_audit_warehouse_inventory
-- captured 2026-07-18 from eizcexopcuoycuosittm
-- md5(pg_get_functiondef) = a282e4f9d4e0de3c93165e3d63c1c868
CREATE OR REPLACE FUNCTION public.auto_audit_warehouse_inventory()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_reason text;
  v_uid uuid;
BEGIN
  IF OLD.warehouse_stock IS DISTINCT FROM NEW.warehouse_stock
     OR OLD.consumer_stock IS DISTINCT FROM NEW.consumer_stock THEN
    v_uid := (SELECT auth.uid());
    v_reason := COALESCE(
      current_setting('app.mutation_reason', true),
      CASE WHEN v_uid IS NULL THEN 'service_role_write_unattributed' ELSE 'authenticated_write_no_reason_set' END
    );
    INSERT INTO inventory_audit_log
      (wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason, audited_at, provenance_reason, source_event_id)
    VALUES
      (NEW.wh_inventory_id, NEW.boonz_product_id, v_uid, OLD.warehouse_stock, NEW.warehouse_stock, v_reason, now(), NEW.provenance_reason, NEW.source_event_id);
  END IF;
  RETURN NEW;
END $function$
