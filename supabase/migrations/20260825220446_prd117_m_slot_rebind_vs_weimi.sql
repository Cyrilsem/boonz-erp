-- PRD-117 item M: warn (never block, never touch the bind) when a genuine
-- slot rebind disagrees with WEIMI's own most recent label for that lane.
-- Verified against md5 245829a4a045c3af8afa8ad283ce80f8 of the prior body.
-- Reuses safe_monitoring_alert (live from PRD-117 item I, 20260824201616).
-- Alert insert is exception-isolated: a monitoring-write failure can never
-- roll back the slot_lifecycle rebind.

CREATE OR REPLACE FUNCTION public.tg_rebind_slot_lifecycle_on_add_confirm()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_cur           slot_lifecycle%ROWTYPE;
  v_shelf_code    text;
  v_new_pod_name  text;
  v_weimi_name    text;
  v_weimi_at      timestamptz;
BEGIN
  SELECT shelf_code INTO v_shelf_code
    FROM shelf_configurations WHERE shelf_id = NEW.shelf_id;

  SELECT * INTO v_cur FROM slot_lifecycle
   WHERE machine_id = NEW.machine_id AND shelf_id = NEW.shelf_id
     AND is_current = true AND archived = false
   FOR UPDATE;

  IF FOUND AND v_cur.pod_product_id = NEW.pod_product_id THEN
    RETURN NEW;  -- shelf already bound to the incoming pod: no-op
  END IF;

  IF FOUND THEN
    BEGIN
      SELECT pod_product_name INTO v_new_pod_name
        FROM pod_products WHERE pod_product_id = NEW.pod_product_id;
      SELECT w.product_name, w.snapshot_at INTO v_weimi_name, v_weimi_at
        FROM public.weimi_aisle_snapshots w
       WHERE w.machine_id = NEW.machine_id
         AND w.slot_code = LEFT(v_shelf_code,1) || (SUBSTR(v_shelf_code,2)::int)::text
       ORDER BY w.snapshot_at DESC
       LIMIT 1;
      IF v_weimi_name IS NOT NULL AND v_new_pod_name IS NOT NULL
         AND position(lower(trim(v_new_pod_name)) in lower(trim(v_weimi_name))) = 0
         AND position(lower(trim(v_weimi_name)) in lower(trim(v_new_pod_name))) = 0 THEN
        PERFORM public.safe_monitoring_alert('slot_rebind_disagrees_with_weimi', 'warning',
          jsonb_build_object('machine_id', NEW.machine_id, 'shelf_code', v_shelf_code,
            'old_pod_product_id', v_cur.pod_product_id, 'new_pod_product_id', NEW.pod_product_id,
            'new_pod_product_name', v_new_pod_name, 'weimi_product_name', v_weimi_name,
            'weimi_snapshot_at', v_weimi_at, 'dispatch_id', NEW.dispatch_id,
            'detected_by', 'tg_rebind_slot_lifecycle_on_add_confirm'));
      END IF;
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
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
    INSERT INTO slot_lifecycle (machine_id, shelf_id, shelf_code, pod_product_id, signal)
    VALUES (NEW.machine_id, NEW.shelf_id, v_shelf_code, NEW.pod_product_id, 'KEEP');
  END IF;

  RETURN NEW;
END;
$function$;
