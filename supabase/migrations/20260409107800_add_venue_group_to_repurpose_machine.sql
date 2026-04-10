-- CC-02b retry: Extend repurpose_machine() with p_new_venue_group parameter.
-- DROP + CREATE (not CREATE OR REPLACE) because the parameter signature is changing.
-- p_new_venue_group defaults to 'INDEPENDENT' so all existing callers are unbroken.
DROP FUNCTION IF EXISTS public.repurpose_machine(uuid, text, text, text, text, text);

CREATE FUNCTION public.repurpose_machine(
  p_old_machine_id       uuid,
  p_new_official_name    text,
  p_new_pod_location     text,
  p_new_location_type    text,
  p_new_building_id      text DEFAULT NULL,
  p_new_source_of_supply text DEFAULT NULL,
  p_new_venue_group      text DEFAULT 'INDEPENDENT'
)
RETURNS TABLE(old_machine_id uuid, new_machine_id uuid, slots_archived integer, result text)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
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

  -- Validate new name doesn't conflict with any active machine
  IF EXISTS (
    SELECT 1 FROM public.machines
    WHERE official_name = p_new_official_name
      AND repurposed_at IS NULL
      AND machine_id != p_old_machine_id
  ) THEN
    RAISE EXCEPTION 'An active machine with name % already exists', p_new_official_name;
  END IF;

  -- Validate venue_group is one of the allowed values (CHECK constraint will also catch this)
  IF p_new_venue_group NOT IN ('ADDMIND', 'VOX', 'VML', 'WPP', 'OHMYDESK', 'INDEPENDENT') THEN
    RAISE EXCEPTION 'Invalid venue_group: %. Must be one of ADDMIND, VOX, VML, WPP, OHMYDESK, INDEPENDENT.', p_new_venue_group;
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

  -- Step 3: Create new machine row with fresh identity, including venue_group
  INSERT INTO public.machines (
    machine_id,
    official_name,
    pod_location,
    location_type,
    building_id,
    source_of_supply,
    venue_group,
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
    p_new_venue_group,
    'Online today',
    'Live',
    true,
    now(),
    now()
  );

  RETURN QUERY SELECT p_old_machine_id, v_new_machine_id, v_slots_archived, 'success'::text;
END;
$function$;

REVOKE ALL ON FUNCTION public.repurpose_machine(uuid, text, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.repurpose_machine(uuid, text, text, text, text, text, text) TO service_role;

COMMENT ON FUNCTION public.repurpose_machine(uuid, text, text, text, text, text, text) IS
'Atomically repurposes a machine: archives old row (repurposed_at, include_in_refill = false, slot_lifecycle archived), creates fresh machine_id with new identity and venue_group. Callable by service_role only via /api/machines/repurpose. Do NOT confuse with rename_machine_in_place_legacy which is the older rename-in-place pattern.';
