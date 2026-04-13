-- Fix upsert_device_status: never overwrite a good snapshot with empty cabinet data.
-- Root cause: ON CONFLICT DO UPDATE was unconditional — a --machine inspection call
-- returning empty door_statuses (cabinet_count=0) would zero out today's good snapshot.
-- Fix: GUARD at two levels:
--   1. Skip rows entirely if cabinets array is missing or empty (CONTINUE before INSERT)
--   2. WHERE clause on DO UPDATE ensures cabinet_count > 0 and stock >= 10% of existing
CREATE OR REPLACE FUNCTION upsert_device_status(items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  item jsonb;
  resolved_mid uuid;
  upserted_count int := 0;
  skipped_count int := 0;
  snap_date date := CURRENT_DATE;
  computed_stock int;
  device_code_val text;
  device_name_val text;
  cabinet_count_val int;
BEGIN
  FOR item IN SELECT * FROM jsonb_array_elements(items)
  LOOP
    device_code_val := item->>'deviceCode';
    device_name_val := NULLIF(item->>'deviceName', '');

    IF device_name_val IS NULL THEN
      skipped_count := skipped_count + 1;
      CONTINUE;
    END IF;

    -- GUARD: skip if cabinets array is empty or missing
    -- Never overwrite a good snapshot with empty data
    cabinet_count_val := COALESCE(jsonb_array_length(item->'cabinets'), 0);
    IF cabinet_count_val = 0 THEN
      skipped_count := skipped_count + 1;
      CONTINUE;
    END IF;

    resolved_mid := resolve_machine_id(device_name_val);
    IF resolved_mid IS NULL AND device_code_val IS NOT NULL THEN
      resolved_mid := resolve_machine_id(device_code_val);
    END IF;

    SELECT COALESCE(SUM(GREATEST((aisle->>'currStock')::int, 0)), 0)
    INTO computed_stock
    FROM jsonb_array_elements(item->'cabinets') cab,
         jsonb_array_elements(cab->'layers') layer,
         jsonb_array_elements(layer->'aisles') aisle;

    INSERT INTO weimi_device_status (
      machine_id, weimi_device_id, device_code, device_name,
      is_covered, is_running, total_curr_stock,
      cabinet_count, door_statuses, snapshot_date
    ) VALUES (
      resolved_mid, item->>'deviceId', device_code_val, device_name_val,
      true,
      COALESCE((item->>'isRunning')::int, 1) = 1,
      computed_stock,
      cabinet_count_val,
      item->'cabinets',
      snap_date
    )
    ON CONFLICT (weimi_device_id, snapshot_date) DO UPDATE SET
      machine_id       = COALESCE(EXCLUDED.machine_id, weimi_device_status.machine_id),
      is_covered       = true,
      is_running       = EXCLUDED.is_running,
      total_curr_stock = EXCLUDED.total_curr_stock,
      cabinet_count    = EXCLUDED.cabinet_count,
      door_statuses    = EXCLUDED.door_statuses,
      snapshot_at      = now()
    -- GUARD: only update if incoming data is better than existing
    WHERE EXCLUDED.cabinet_count > 0
      AND EXCLUDED.total_curr_stock >= weimi_device_status.total_curr_stock * 0.1;

    upserted_count := upserted_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'status', 'ok',
    'upserted', upserted_count,
    'skipped', skipped_count,
    'snapshot_date', snap_date
  );
END;
$$;
