-- CC-09b: Merge the two duplicate VOXMCC-1009-0201-B0 rows.
-- v_old_id (148c4fcf): operational row — has weimi snapshots, sales, planogram, slot_lifecycle
-- v_new_id (ac9022a3): ghost row — has adyen fields, 37 refill_dispatching, 44 pod_inventory,
--                      283 adyen_transactions, 32 shelf_configurations, 4 lifecycle flags, 1 alias
-- Three unique constraints hit during resolution:
--   1. machines.pod_number           — NULL ghost first, then copy
--   2. machine_name_aliases(machine_id, original_name) — delete conflicts then reassign
--   3. shelf_configurations(machine_id, shelf_code)    — delete conflicts then reassign
DO $$
DECLARE
  v_old_id uuid := '148c4fcf-b794-43f0-a2a8-e6f17605b045';
  v_new_id uuid := 'ac9022a3-237c-4669-9bd1-aadb354f495e';
  v_ghost_pod_number     text;
  v_ghost_adyen_status   text;
  v_ghost_adyen_in_store text;
  v_ghost_pod_location   text;
  v_ghost_location_type  text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.machines WHERE machine_id = v_old_id AND official_name = 'VOXMCC-1009-0201-B0') THEN
    RAISE EXCEPTION 'Operational row % not found or name mismatch', v_old_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.machines WHERE machine_id = v_new_id AND official_name = 'VOXMCC-1009-0201-B0') THEN
    RAISE EXCEPTION 'Ghost row % not found or name mismatch', v_new_id;
  END IF;

  -- Step 1: Capture + NULL pod_number on ghost (unique constraint)
  SELECT pod_number, adyen_status, adyen_inventory_in_store, pod_location, location_type
  INTO v_ghost_pod_number, v_ghost_adyen_status, v_ghost_adyen_in_store, v_ghost_pod_location, v_ghost_location_type
  FROM public.machines WHERE machine_id = v_new_id;

  UPDATE public.machines SET pod_number = NULL, updated_at = now() WHERE machine_id = v_new_id;

  -- Step 2: Merge fields onto operational row
  UPDATE public.machines SET
    adyen_status             = v_ghost_adyen_status,
    adyen_inventory_in_store = v_ghost_adyen_in_store,
    pod_number               = COALESCE(v_ghost_pod_number, pod_number),
    pod_location             = COALESCE(v_ghost_pod_location, pod_location),
    location_type            = COALESCE(v_ghost_location_type, location_type),
    updated_at               = now()
  WHERE machine_id = v_old_id;

  -- Step 3: RESTRICT FK tables (must precede DELETE)
  UPDATE public.pod_inventory      SET machine_id = v_old_id WHERE machine_id = v_new_id;
  UPDATE public.refill_dispatching SET machine_id = v_old_id WHERE machine_id = v_new_id;

  -- Step 4: machine_name_aliases — delete conflicts, then reassign
  DELETE FROM public.machine_name_aliases
  WHERE machine_id = v_new_id
    AND original_name IN (SELECT original_name FROM public.machine_name_aliases WHERE machine_id = v_old_id);
  UPDATE public.machine_name_aliases SET machine_id = v_old_id WHERE machine_id = v_new_id;

  -- Step 5: shelf_configurations — delete conflicts (old row is canonical), then reassign
  DELETE FROM public.shelf_configurations
  WHERE machine_id = v_new_id
    AND shelf_code IN (SELECT shelf_code FROM public.shelf_configurations WHERE machine_id = v_old_id);
  UPDATE public.shelf_configurations SET machine_id = v_old_id WHERE machine_id = v_new_id;

  -- Remaining CASCADE FK tables
  UPDATE public.machine_product_pricing SET machine_id = v_old_id WHERE machine_id = v_new_id;
  UPDATE public.machine_summary         SET machine_id = v_old_id WHERE machine_id = v_new_id;
  UPDATE public.planogram               SET machine_id = v_old_id WHERE machine_id = v_new_id;
  UPDATE public.product_mapping         SET machine_id = v_old_id WHERE machine_id = v_new_id;
  UPDATE public.refill_instructions     SET machine_id = v_old_id WHERE machine_id = v_new_id;

  -- NO ACTION / SET NULL FK tables
  UPDATE public.adyen_transactions           SET machine_id = v_old_id WHERE machine_id = v_new_id;
  UPDATE public.lifecycle_data_quality_flags SET machine_id = v_old_id WHERE machine_id = v_new_id;
  UPDATE public.decision_log                 SET machine_id = v_old_id WHERE machine_id = v_new_id;
  UPDATE public.dispatch_photos              SET machine_id = v_old_id WHERE machine_id = v_new_id;
  UPDATE public.lifecycle_score_history      SET machine_id = v_old_id WHERE machine_id = v_new_id;
  UPDATE public.machine_issues               SET machine_id = v_old_id WHERE machine_id = v_new_id;
  UPDATE public.pod_inventory_edits          SET machine_id = v_old_id WHERE machine_id = v_new_id;
  UPDATE public.pod_inventory_edits          SET destination_machine_id = v_old_id WHERE destination_machine_id = v_new_id;
  UPDATE public.pod_inventory_snapshots      SET machine_id = v_old_id WHERE machine_id = v_new_id;
  UPDATE public.refill_dispatch_plan         SET machine_id = v_old_id WHERE machine_id = v_new_id;
  UPDATE public.sales_history                SET machine_id = v_old_id WHERE machine_id = v_new_id;
  UPDATE public.slot_lifecycle               SET machine_id = v_old_id WHERE machine_id = v_new_id;
  UPDATE public.trip_events                  SET machine_id = v_old_id WHERE machine_id = v_new_id;
  UPDATE public.warehouse_inventory          SET reserved_for_machine_id = v_old_id WHERE reserved_for_machine_id = v_new_id;
  UPDATE public.weimi_aisle_snapshots        SET machine_id = v_old_id WHERE machine_id = v_new_id;
  UPDATE public.weimi_device_status          SET machine_id = v_old_id WHERE machine_id = v_new_id;

  -- Delete ghost row
  DELETE FROM public.machines WHERE machine_id = v_new_id;

  RAISE NOTICE 'VOXMCC-1009 merge complete. Surviving machine_id: %', v_old_id;
END $$;
