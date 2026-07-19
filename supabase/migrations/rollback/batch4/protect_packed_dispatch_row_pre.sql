-- ROLLBACK PRE-IMAGE (Batch 4 / RC-07) — VERBATIM live body captured 2026-07-18 from eizcexopcuoycuosittm
-- object: protect_packed_dispatch_row()
-- md5(pg_get_functiondef) = 42217e9fde5538995739ca9646c2e4f2
-- restore via: CREATE OR REPLACE (same signature)
CREATE OR REPLACE FUNCTION public.protect_packed_dispatch_row()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  -- If the row was already packed, block changes to core identity fields
  IF OLD.packed = true THEN
    IF NEW.boonz_product_id IS DISTINCT FROM OLD.boonz_product_id THEN
      RAISE EXCEPTION 'Cannot change boonz_product_id on a packed dispatch line';
    END IF;
    IF NEW.pod_product_id IS DISTINCT FROM OLD.pod_product_id THEN
      RAISE EXCEPTION 'Cannot change pod_product_id on a packed dispatch line';
    END IF;
    IF NEW.machine_id IS DISTINCT FROM OLD.machine_id THEN
      RAISE EXCEPTION 'Cannot change machine_id on a packed dispatch line';
    END IF;
    IF NEW.shelf_id IS DISTINCT FROM OLD.shelf_id THEN
      RAISE EXCEPTION 'Cannot change shelf_id on a packed dispatch line';
    END IF;
    IF NEW.dispatch_date IS DISTINCT FROM OLD.dispatch_date THEN
      RAISE EXCEPTION 'Cannot change dispatch_date on a packed dispatch line';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$

