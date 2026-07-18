-- ROLLBACK: restore live pre-Batch-2 body of auto_audit_warehouse_inventory_insert
-- captured 2026-07-18 from eizcexopcuoycuosittm
-- md5(pg_get_functiondef) = c82fd784cc7b175ef8916e1542b5455a
CREATE OR REPLACE FUNCTION public.auto_audit_warehouse_inventory_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_reason text;
  v_uid uuid;
BEGIN
  IF COALESCE(NEW.warehouse_stock, 0) > 0 OR COALESCE(NEW.consumer_stock, 0) > 0 THEN
    v_uid := (SELECT auth.uid());
    v_reason := COALESCE(
      current_setting('app.mutation_reason', true),
      CASE WHEN v_uid IS NULL THEN 'service_role_insert_unattributed'
           ELSE 'authenticated_insert_no_reason_set' END
    );
    INSERT INTO inventory_audit_log
      (wh_inventory_id, boonz_product_id, adjusted_by,
       old_qty, new_qty, reason, audited_at,
       provenance_reason, source_event_id)
    VALUES
      (NEW.wh_inventory_id, NEW.boonz_product_id, v_uid,
       0,
       COALESCE(NEW.warehouse_stock, 0) + COALESCE(NEW.consumer_stock, 0),
       v_reason, now(),
       NEW.provenance_reason, NEW.source_event_id);
  END IF;
  RETURN NEW;
END;
$function$
