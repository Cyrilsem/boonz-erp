-- ROLLBACK: restore live pre-Batch-2 body of set_warehouse_inventory_provenance
-- captured 2026-07-18 from eizcexopcuoycuosittm
-- md5(pg_get_functiondef) = 591a5223fcb1ee9900fc150e9f083834
CREATE OR REPLACE FUNCTION public.set_warehouse_inventory_provenance()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_reason text := current_setting('app.provenance_reason', true);
  v_event  text := current_setting('app.source_event_id', true);
BEGIN
  IF v_reason IS NOT NULL AND v_reason <> '' THEN
    NEW.provenance_reason := v_reason;
  END IF;
  IF v_event IS NOT NULL AND v_event <> '' THEN
    BEGIN
      NEW.source_event_id := v_event::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      NEW.source_event_id := NULL;
    END;
  END IF;
  RETURN NEW;
END $function$
