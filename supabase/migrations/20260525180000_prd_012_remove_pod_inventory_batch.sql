-- PRD-012 P3.B prerequisite: canonical RPC for driver bulk removals.
-- Wraps the existing FE direct INSERT at src/app/(field)/field/trips/[machineId]/removals/page.tsx:103
-- so the upcoming A.6 hard-block trigger can refuse direct INSERTs without
-- breaking the removals flow. Manager + driver callable (field_staff + warehouse + manager set).
-- Cody verdict: approve. Shape-preserving wrap of the existing INSERT.

CREATE OR REPLACE FUNCTION public.remove_pod_inventory_batch(
  p_machine_id uuid,
  p_lines      jsonb,
  p_caller_id  uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id     uuid;
  v_caller_role text;
  -- Dubai date semantic: matches the FE's getDubaiDate() helper. Not just
  -- CURRENT_DATE because the Boonz operations day is anchored to Asia/Dubai
  -- regardless of the DB server timezone.
  v_today       date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  v_inserted    int := 0;
  v_line        jsonb;
BEGIN
  v_user_id := COALESCE(p_caller_id, auth.uid());
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'remove_pod_inventory_batch: no caller identity';
  END IF;
  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller_role IS NULL
     OR v_caller_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'remove_pod_inventory_batch: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;

  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'remove_pod_inventory_batch: p_lines must be a non-empty jsonb array';
  END IF;

  PERFORM set_config('app.via_rpc',         'true', true);
  PERFORM set_config('app.rpc_name',        'remove_pod_inventory_batch', true);
  PERFORM set_config('app.mutation_reason', format('driver_bulk_removal machine=%s by=%s', p_machine_id, v_user_id), true);

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    IF (v_line->>'boonz_product_id') IS NULL THEN
      CONTINUE;
    END IF;
    INSERT INTO public.pod_inventory (
      machine_id, boonz_product_id, snapshot_date, current_stock, status, removal_reason
    ) VALUES (
      p_machine_id,
      (v_line->>'boonz_product_id')::uuid,
      v_today,
      0,
      'Removed / Expired',
      COALESCE(v_line->>'removal_reason', 'Other')
    );
    v_inserted := v_inserted + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'result',         'success',
    'inserted_count', v_inserted,
    'machine_id',     p_machine_id,
    'snapshot_date',  v_today
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.remove_pod_inventory_batch(uuid,jsonb,uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.remove_pod_inventory_batch(uuid,jsonb,uuid) TO authenticated;

COMMENT ON FUNCTION public.remove_pod_inventory_batch(uuid,jsonb,uuid) IS
  'PRD-012 P3.B prerequisite. Canonical writer wrapping the driver bulk-removals flow. Per-line jsonb input: {boonz_product_id, removal_reason}. INSERTs status=Removed/Expired marker rows. Skips lines without boonz_product_id (matches the pre-existing FE behavior where pod_products without a boonz mapping pass null). Roles: field_staff + manager set.';
