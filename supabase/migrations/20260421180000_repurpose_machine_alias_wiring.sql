-- CC-15: Extend repurpose_machine() with automatic alias wiring.
-- Root cause of ALHQ→JET, LLFP→MPMCC, IRIS→ACTIVATEMCC contaminations:
-- repurpose_machine() never wrote to machine_name_aliases, so the ETL
-- (process_weimi_staging) had no UUID anchor for old/new WEIMI names,
-- causing it to fall back to pod_location matching on the wrong machine.
--
-- This migration adds two alias steps to the atomic transaction:
--   Step 4 – wire OLD WEIMI name (pod_location or official_name) → OLD machine UUID
--   Step 5 – wire NEW WEIMI name (p_new_pod_location or p_new_official_name) → NEW machine UUID
--
-- Signature is unchanged (7 params). Return type gains aliases_wired column.
-- The Next.js API route (/api/machines/repurpose) and Edge Function callers
-- ignore unknown columns, so this is backwards-compatible.

DROP FUNCTION IF EXISTS public.repurpose_machine(
  uuid, text, text, text, text, text, text
);

CREATE FUNCTION public.repurpose_machine(
  p_old_machine_id       uuid,
  p_new_official_name    text,
  p_new_pod_location     text,
  p_new_location_type    text,
  p_new_building_id      text DEFAULT NULL,
  p_new_source_of_supply text DEFAULT NULL,
  p_new_venue_group      text DEFAULT 'INDEPENDENT'
)
RETURNS TABLE(
  old_machine_id  uuid,
  new_machine_id  uuid,
  slots_archived  integer,
  aliases_wired   integer,
  result          text
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_new_machine_id   uuid := gen_random_uuid();
  v_slots_archived   int;
  v_old_official     text;
  v_old_weimi_name   text;
  v_new_weimi_name   text;
  v_aliases_wired    int := 0;
BEGIN

  -- ── Validation ─────────────────────────────────────────────────────────────

  IF NOT EXISTS (
    SELECT 1 FROM public.machines
    WHERE machine_id = p_old_machine_id AND repurposed_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Machine % does not exist or is already repurposed', p_old_machine_id;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.machines
    WHERE official_name = p_new_official_name
      AND repurposed_at IS NULL
      AND machine_id    != p_old_machine_id
  ) THEN
    RAISE EXCEPTION 'An active machine with name % already exists', p_new_official_name;
  END IF;

  IF p_new_venue_group NOT IN ('ADDMIND','VOX','VML','WPP','OHMYDESK','INDEPENDENT') THEN
    RAISE EXCEPTION 'Invalid venue_group: %. Must be one of ADDMIND, VOX, VML, WPP, OHMYDESK, INDEPENDENT.', p_new_venue_group;
  END IF;

  -- Capture old identity before we overwrite it
  SELECT official_name,
         COALESCE(pod_location, official_name)
  INTO   v_old_official, v_old_weimi_name
  FROM   public.machines
  WHERE  machine_id = p_old_machine_id;

  -- New WEIMI name: use supplied pod_location, fall back to new official_name
  v_new_weimi_name := COALESCE(NULLIF(TRIM(p_new_pod_location), ''), p_new_official_name);

  -- ── Step 1: Archive the old machine row ────────────────────────────────────

  UPDATE public.machines
  SET
    repurposed_at             = CURRENT_DATE,
    previous_location         = official_name,
    adyen_status              = 'Switched off',
    adyen_inventory_in_store  = 'Switched off',
    include_in_refill         = false,
    updated_at                = now()
  WHERE machine_id = p_old_machine_id;

  -- ── Step 2: Archive active slot_lifecycle rows ─────────────────────────────

  UPDATE public.slot_lifecycle
  SET archived = true
  WHERE machine_id = p_old_machine_id
    AND archived   = false;
  GET DIAGNOSTICS v_slots_archived = ROW_COUNT;

  -- ── Step 3: Create new machine row ─────────────────────────────────────────

  INSERT INTO public.machines (
    machine_id, official_name, pod_location, location_type,
    building_id, source_of_supply, venue_group,
    adyen_status, adyen_inventory_in_store, include_in_refill,
    created_at, updated_at
  ) VALUES (
    v_new_machine_id, p_new_official_name, v_new_weimi_name, p_new_location_type,
    p_new_building_id, p_new_source_of_supply, p_new_venue_group,
    'Online today', 'Live', true,
    now(), now()
  );

  -- ── Step 4: Wire OLD WEIMI name → OLD machine UUID ─────────────────────────
  -- Update any NULL-machine_id aliases that point to the old official_name
  UPDATE public.machine_name_aliases
  SET machine_id = p_old_machine_id
  WHERE original_name = v_old_weimi_name
    AND machine_id IS NULL;

  -- Also handle the un-normalised form (underscores ↔ dashes)
  UPDATE public.machine_name_aliases
  SET machine_id = p_old_machine_id
  WHERE original_name = REPLACE(v_old_weimi_name, '-', '_')
    AND machine_id IS NULL;

  -- Ensure at least one clean alias exists for the old name → old UUID
  INSERT INTO public.machine_name_aliases (original_name, official_name, machine_id, is_active)
  VALUES (v_old_weimi_name, v_old_official, p_old_machine_id, true)
  ON CONFLICT (machine_id, original_name) DO NOTHING;

  -- ── Step 5: Wire NEW WEIMI name → NEW machine UUID ─────────────────────────
  -- Primary alias: new WEIMI route name
  INSERT INTO public.machine_name_aliases (original_name, official_name, machine_id, is_active)
  VALUES (v_new_weimi_name, p_new_official_name, v_new_machine_id, true)
  ON CONFLICT (machine_id, original_name) DO NOTHING;

  -- Secondary alias: official_name itself (covers WEIMI systems that use official name)
  INSERT INTO public.machine_name_aliases (original_name, official_name, machine_id, is_active)
  VALUES (p_new_official_name, p_new_official_name, v_new_machine_id, true)
  ON CONFLICT (machine_id, original_name) DO NOTHING;

  v_aliases_wired := 2; -- old + new

  -- ── Return ─────────────────────────────────────────────────────────────────

  RETURN QUERY
    SELECT p_old_machine_id, v_new_machine_id, v_slots_archived, v_aliases_wired, 'success'::text;

END;
$function$;

REVOKE ALL ON FUNCTION public.repurpose_machine(uuid, text, text, text, text, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.repurpose_machine(uuid, text, text, text, text, text, text) TO service_role;

COMMENT ON FUNCTION public.repurpose_machine(uuid, text, text, text, text, text, text) IS
'Atomically repurposes a machine: (1) archives old row with repurposed_at=today and include_in_refill=false, (2) archives slot_lifecycle, (3) creates fresh machine_id with new identity, (4) wires old WEIMI name → old UUID in machine_name_aliases, (5) wires new WEIMI name → new UUID in machine_name_aliases. Steps 4–5 prevent the ETL misattribution bug (ALHQ→JET, LLFP→MPMCC, IRIS→ACTIVATEMCC). Callable by service_role only — invoked via supabase edge function repurpose-machine.';
