-- CC-09: Retroactive ALHQ-1016 → JET-1016-0000-O1 identity split.
-- The row (967abf7a) was renamed in-place, contaminating 6+ months of ALHQ history.
-- This migration reverse-engineers the correct split: restore original ALHQ name,
-- then call repurpose_machine() to atomically archive and create a clean JET-1016 row.
-- OPERATOR FOLLOW-UP REQUIRED on new JET-1016 row:
--   - pod_location is placeholder 'JET-1016-0000-O1' — update to real location
--   - location_type 'coworking' — assumed from archived row, confirm
--   - source_of_supply 'BOONZ' — assumed, confirm
--   - Copy adyen_unique_terminal_id / pod_number from archived ALHQ row if same physical machine
DO $$
DECLARE
  v_target_id      uuid := '967abf7a-0d1e-4fb9-a0ec-29ba717a4c67';
  v_new_machine_id uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.machines
    WHERE machine_id = v_target_id
      AND official_name = 'JET-1016-0000-O1'
      AND repurposed_at IS NULL
  ) THEN
    RAISE EXCEPTION 'ALHQ target row % not found, already repurposed, or name changed unexpectedly', v_target_id;
  END IF;

  -- Step 1: Revert official_name to original ALHQ identity
  UPDATE public.machines
  SET official_name = 'ALHQ-1016-0000-O1', updated_at = now()
  WHERE machine_id = v_target_id;

  -- Step 2: Repurpose ALHQ → create fresh JET-1016
  SELECT new_machine_id INTO v_new_machine_id
  FROM public.repurpose_machine(
    p_old_machine_id       := v_target_id,
    p_new_official_name    := 'JET-1016-0000-O1',
    p_new_pod_location     := 'JET-1016-0000-O1',
    p_new_location_type    := 'coworking',
    p_new_building_id      := NULL,
    p_new_source_of_supply := 'BOONZ'
  );

  RAISE NOTICE 'ALHQ → JET-1016 split complete. ALHQ archived: %. New JET-1016: %', v_target_id, v_new_machine_id;
END $$;
