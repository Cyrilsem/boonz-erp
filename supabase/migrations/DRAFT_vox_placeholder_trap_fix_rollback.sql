-- Rollback for DRAFT_vox_placeholder_trap_fix.sql: restore the original constraint vocabulary,
-- the original enforce_warehouse_expiry_sanity body (no sentinel exemption), and drop
-- ensure_vox_placeholder.

ALTER TABLE public.refill_dispatching DROP CONSTRAINT refill_dispatching_bind_fail_reason_check;
ALTER TABLE public.refill_dispatching ADD CONSTRAINT refill_dispatching_bind_fail_reason_check
  CHECK (bind_fail_reason IS NULL OR bind_fail_reason = ANY (ARRAY[
    'no_stock'::text, 'quarantined'::text, 'inactive_batch'::text, 'pinned_elsewhere'::text
  ]));

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

DROP FUNCTION IF EXISTS public.ensure_vox_placeholder(uuid, uuid, uuid);
