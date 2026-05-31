-- PRD-015 Phase A / AC#11 — canonical toggle writers for machines_to_visit.is_included.
-- SECURITY DEFINER, role-gated, set app.via_rpc/app.rpc_name (Article 4), addressed by
-- machine_id (Article 3: no raw FE writes). Pattern mirrors confirm_machines_to_visit.
-- Depends on 20260531090000_phaseF_mtv_is_included. NOT YET APPLIED (per-phase sign-off).

-- per-machine toggle
CREATE OR REPLACE FUNCTION public.set_machine_inclusion(
  p_plan_date  date,
  p_machine_id uuid,
  p_is_included boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_n int;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND role = ANY(ARRAY['operator_admin','superadmin','warehouse'])
  ) THEN
    RAISE EXCEPTION 'forbidden: set_machine_inclusion requires operator_admin / superadmin / warehouse';
  END IF;
  IF p_plan_date IS NULL OR p_machine_id IS NULL OR p_is_included IS NULL THEN
    RAISE EXCEPTION 'p_plan_date, p_machine_id, p_is_included all required';
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'set_machine_inclusion', true);

  UPDATE public.machines_to_visit
     SET is_included = p_is_included, updated_at = now()
   WHERE plan_date = p_plan_date AND machine_id = p_machine_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'set_machine_inclusion: no machines_to_visit row for plan_date % machine %', p_plan_date, p_machine_id;
  END IF;

  RETURN jsonb_build_object('plan_date', p_plan_date, 'machine_id', p_machine_id,
    'is_included', p_is_included, 'rows', v_n, 'status', 'ok');
END $function$;
GRANT EXECUTE ON FUNCTION public.set_machine_inclusion(date,uuid,boolean) TO authenticated;

-- include/exclude all for a plan_date (picked + cs_added route members; never touches dropped rows)
CREATE OR REPLACE FUNCTION public.bulk_set_machine_inclusion(
  p_plan_date date,
  p_is_included boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_n int;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND role = ANY(ARRAY['operator_admin','superadmin','warehouse'])
  ) THEN
    RAISE EXCEPTION 'forbidden: bulk_set_machine_inclusion requires operator_admin / superadmin / warehouse';
  END IF;
  IF p_plan_date IS NULL OR p_is_included IS NULL THEN
    RAISE EXCEPTION 'p_plan_date, p_is_included required';
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'bulk_set_machine_inclusion', true);

  UPDATE public.machines_to_visit
     SET is_included = p_is_included, updated_at = now()
   WHERE plan_date = p_plan_date
     AND status IN ('picked','cs_added');
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object('plan_date', p_plan_date, 'is_included', p_is_included,
    'rows', v_n, 'status', 'ok');
END $function$;
GRANT EXECUTE ON FUNCTION public.bulk_set_machine_inclusion(date,boolean) TO authenticated;
