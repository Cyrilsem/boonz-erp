-- ONE-LOOP-2 Block A step 3 (PRD-124 #37): confirm_machines_to_visit only
-- confirmed status='picked' rows, silently skipping 'cs_added' rows. A
-- machine an operator explicitly added to the pick list never got
-- confirmed_at set, so it never passed gate_zero, so it silently never
-- reached the refill plan even though it was on the list -- the exact
-- "packing rows not showing on /refill" shape PRD-124 named. Confirmed the
-- real cause by finding this function's WHERE clause directly; not a
-- different cause.
CREATE OR REPLACE FUNCTION public.confirm_machines_to_visit(p_plan_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_n int;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND role = ANY(ARRAY['operator_admin','superadmin'])
  ) THEN
    RAISE EXCEPTION 'forbidden: confirm_machines_to_visit requires operator_admin or superadmin';
  END IF;

  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'p_plan_date required';
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'confirm_machines_to_visit', true);

  UPDATE public.machines_to_visit
  SET confirmed_at = now(),
      confirmed_by = COALESCE(auth.uid()::text, current_user),
      updated_at   = now()
  WHERE plan_date = p_plan_date
    AND status IN ('picked', 'cs_added')
    AND confirmed_at IS NULL;

  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object(
    'plan_date',     p_plan_date,
    'confirmed_now', v_n,
    'status',        'gate_zero_passed'
  );
END $function$;
