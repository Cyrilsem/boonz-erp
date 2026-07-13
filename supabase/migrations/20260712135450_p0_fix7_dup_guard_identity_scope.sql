CREATE OR REPLACE FUNCTION public.prevent_duplicate_unstarted_dispatch()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF TG_OP = 'UPDATE'
     AND OLD.machine_id IS NOT DISTINCT FROM NEW.machine_id
     AND OLD.shelf_id IS NOT DISTINCT FROM NEW.shelf_id
     AND OLD.boonz_product_id IS NOT DISTINCT FROM NEW.boonz_product_id
     AND OLD.dispatch_date IS NOT DISTINCT FROM NEW.dispatch_date
     AND OLD.action IS NOT DISTINCT FROM NEW.action
  THEN RETURN NEW; END IF;
  IF NEW.include = true
     AND COALESCE(NEW.filled_quantity, 0) = 0
     AND COALESCE(NEW.packed, false) = false
     AND COALESCE(NEW.item_added, false) = false
     AND COALESCE(NEW.returned, false) = false
     AND NEW.action IN ('Refill', 'Add New') THEN
    IF EXISTS (
      SELECT 1
      FROM refill_dispatching
      WHERE machine_id       = NEW.machine_id
        AND shelf_id         = NEW.shelf_id
        AND boonz_product_id = NEW.boonz_product_id
        AND dispatch_date    = NEW.dispatch_date
        AND action           = NEW.action
        AND include          = true
        AND COALESCE(filled_quantity, 0) = 0
        AND COALESCE(packed, false) = false        -- new
        AND COALESCE(item_added, false) = false    -- new
        AND COALESCE(returned, false) = false      -- new
        AND COALESCE(skipped, false) = false
        AND COALESCE(cancelled, false) = false
        AND dispatch_id     != COALESCE(NEW.dispatch_id, '00000000-0000-0000-0000-000000000000'::uuid)
    ) THEN
      RAISE EXCEPTION
        'Duplicate unstarted dispatch row for (machine=%, shelf=%, product=%, action=%, date=%). Use slice rows (filled_quantity > 0) for multi-batch packs.',
        NEW.machine_id, NEW.shelf_id, NEW.boonz_product_id, NEW.action, NEW.dispatch_date;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$
