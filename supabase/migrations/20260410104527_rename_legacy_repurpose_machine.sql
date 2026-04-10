-- CC-14: Rename the legacy 8-parameter rename-in-place function to avoid overload ambiguity.
-- The Round 2 repurpose_machine (6-param, creates fresh machine_id) is the canonical function.
-- The older function (8-param, renames in place, preserves machine_id) is renamed for clarity.
-- Investigation result: zero frontend/backend callers use the legacy signature — no caller updates needed.
ALTER FUNCTION public.repurpose_machine(
  p_machine_id uuid,
  p_new_official_name text,
  p_new_location_type text,
  p_new_pod_location text,
  p_new_status text,
  p_include_in_refill boolean,
  p_cutover_date date,
  p_previous_location text
) RENAME TO rename_machine_in_place_legacy;

COMMENT ON FUNCTION public.rename_machine_in_place_legacy(
  uuid, text, text, text, text, boolean, date, text
) IS 'LEGACY: Rename-in-place pattern. Same machine_id is preserved across rename. Creates an alias in machine_name_aliases. Use this only for backwards-compat with existing field PWA flows. For new identity transitions, use repurpose_machine() which atomically creates a fresh machine_id (canonical pattern as of Round 2).';

-- Verify the Round 2 canonical repurpose_machine still exists with its 6-param signature
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname = 'repurpose_machine'
      AND pg_get_function_identity_arguments(oid) =
          'p_old_machine_id uuid, p_new_official_name text, p_new_pod_location text, p_new_location_type text, p_new_building_id text, p_new_source_of_supply text'
  ) THEN
    RAISE EXCEPTION 'Round 2 repurpose_machine (6-param) not found — aborting rename';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname = 'repurpose_machine'
      AND pg_get_function_identity_arguments(oid) LIKE '%p_cutover_date date%'
  ) THEN
    RAISE EXCEPTION 'Legacy repurpose_machine still exists after rename — aborting';
  END IF;
END $$;
