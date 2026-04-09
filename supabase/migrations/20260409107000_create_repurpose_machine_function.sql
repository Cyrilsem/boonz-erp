-- CC-08: Atomic machine repurpose function.
-- Replaces the rename-in-place pattern that caused the ALHQ→JET-1016 contamination.
-- NOTE: machines table has no weimi_device_id or location_name columns — those references
-- from the spec are omitted. Physical device rebinding is done by the operator via
-- the admin UI after repurposing.
-- slot_lifecycle.archived column already existed before this migration.
CREATE OR REPLACE FUNCTION public.repurpose_machine(
  p_old_machine_id      uuid,
  p_new_official_name   text,
  p_new_pod_location    text,
  p_new_location_type   text,
  p_new_building_id     text DEFAULT NULL,
  p_new_source_of_supply text DEFAULT NULL
)
RETURNS TABLE(old_machine_id uuid, new_machine_id uuid, slots_archived int, result text)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_new_machine_id uuid := gen_random_uuid();
  v_slots_archived int;
BEGIN
  -- Validate old machine exists and is not already repurposed
  IF NOT EXISTS (
    SELECT 1 FROM public.machines
    WHERE machine_id = p_old_machine_id AND repurposed_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Machine % does not exist or is already repurposed', p_old_machine_id;
  END IF;

  -- Validate new name doesn't conflict with any active (non-repurposed) machine
  IF EXISTS (
    SELECT 1 FROM public.machines
    WHERE official_name = p_new_official_name
      AND repurposed_at IS NULL
      AND machine_id != p_old_machine_id
  ) THEN
    RAISE EXCEPTION 'An active machine with name % already exists', p_new_official_name;
  END IF;

  -- Step 1: Archive the old row
  UPDATE public.machines
  SET
    repurposed_at             = CURRENT_DATE,
    previous_location         = official_name,
    adyen_status              = 'Switched off',
    adyen_inventory_in_store  = 'Switched off',
    include_in_refill         = false,
    updated_at                = now()
  WHERE machine_id = p_old_machine_id;

  -- Step 2: Archive all active slot_lifecycle rows for the old machine
  UPDATE public.slot_lifecycle
  SET archived = true
  WHERE machine_id = p_old_machine_id
    AND archived = false;
  GET DIAGNOSTICS v_slots_archived = ROW_COUNT;

  -- Step 3: Create new machine row with fresh identity
  INSERT INTO public.machines (
    machine_id,
    official_name,
    pod_location,
    location_type,
    building_id,
    source_of_supply,
    adyen_status,
    adyen_inventory_in_store,
    include_in_refill,
    created_at,
    updated_at
  ) VALUES (
    v_new_machine_id,
    p_new_official_name,
    p_new_pod_location,
    p_new_location_type,
    p_new_building_id,
    p_new_source_of_supply,
    'Online today',
    'Live',
    true,
    now(),
    now()
  );

  RETURN QUERY SELECT p_old_machine_id, v_new_machine_id, v_slots_archived, 'success'::text;
END;
$$;

REVOKE ALL ON FUNCTION public.repurpose_machine(uuid, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.repurpose_machine(uuid, text, text, text, text, text) TO service_role;

COMMENT ON FUNCTION public.repurpose_machine(uuid, text, text, text, text, text) IS
'Atomically repurposes a machine: archives the old row (repurposed_at = today, include_in_refill = false, slot_lifecycle archived), creates a fresh row with new identity. Use this instead of updating official_name in-place. Callable by service_role only — invoked via frontend RPC with elevated role.';
