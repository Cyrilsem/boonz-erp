-- PRD-CLEAN-14: close the post-swap slot_lifecycle write gap.
-- Root cause of the 2026-07-12 incident and the 2026-07-16 HUAWEI drift: receiving an
-- 'Add New' dispatch line writes pod_inventory but nothing rebinds slot_lifecycle, so
-- slot identity goes stale the moment a swap physically executes.
-- Host decision: TRIGGER on refill_dispatching.item_added false->true (the terminal
-- "physically confirmed at the machine" flip) rather than editing receive_dispatch_line:
-- item_added is set by receive_dispatch_line AND repack_machine (and any future writer),
-- so the trigger is the single choke point and runs in the same transaction.
-- Write rules mirror rebind_slot_lifecycle_from_weimi: archive the outgoing current row
-- (rotated_out_at), revive a prior row for the incoming pod if one exists (UNIQUE
-- machine+shelf+pod), else insert; idempotent when the shelf is already bound to the
-- incoming pod (multi-variant Add News of the same pod fire it repeatedly).
-- It writes ONLY slot_lifecycle - never refill_dispatching, never packed rows.
-- Rollback: docs/prds/rollback/prd_clean_14_rollback_2026-07-16.sql

CREATE OR REPLACE FUNCTION public.tg_rebind_slot_lifecycle_on_add_confirm()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_cur        slot_lifecycle%ROWTYPE;
  v_shelf_code text;
BEGIN
  SELECT * INTO v_cur FROM slot_lifecycle
   WHERE machine_id = NEW.machine_id AND shelf_id = NEW.shelf_id
     AND is_current = true AND archived = false
   FOR UPDATE;

  IF FOUND AND v_cur.pod_product_id = NEW.pod_product_id THEN
    RETURN NEW;  -- shelf already bound to the incoming pod: no-op
  END IF;

  IF FOUND THEN
    UPDATE slot_lifecycle
       SET archived = true, is_current = false,
           rotated_out_at = now(), last_evaluated_at = now()
     WHERE slot_lifecycle_id = v_cur.slot_lifecycle_id;
  END IF;

  UPDATE slot_lifecycle
     SET archived = false, is_current = true, rotated_in_at = now(),
         rotated_out_at = NULL, last_evaluated_at = now(), signal = 'KEEP'
   WHERE machine_id = NEW.machine_id AND shelf_id = NEW.shelf_id
     AND pod_product_id = NEW.pod_product_id;

  IF NOT FOUND THEN
    SELECT shelf_code INTO v_shelf_code
      FROM shelf_configurations WHERE shelf_id = NEW.shelf_id;
    INSERT INTO slot_lifecycle (machine_id, shelf_id, shelf_code, pod_product_id, signal)
    VALUES (NEW.machine_id, NEW.shelf_id, v_shelf_code, NEW.pod_product_id, 'KEEP');
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_rebind_slot_on_add_confirm ON public.refill_dispatching;
CREATE TRIGGER trg_rebind_slot_on_add_confirm
AFTER UPDATE OF item_added ON public.refill_dispatching
FOR EACH ROW
WHEN (NEW.item_added = true AND COALESCE(OLD.item_added, false) = false
      AND NEW.action IN ('Add New', 'Add')
      AND COALESCE(NEW.returned,  false) = false
      AND COALESCE(NEW.cancelled, false) = false
      AND COALESCE(NEW.skipped,   false) = false
      AND NEW.shelf_id IS NOT NULL AND NEW.pod_product_id IS NOT NULL
      AND COALESCE(NEW.filled_quantity, NEW.quantity, 0) > 0)
EXECUTE FUNCTION public.tg_rebind_slot_lifecycle_on_add_confirm();
