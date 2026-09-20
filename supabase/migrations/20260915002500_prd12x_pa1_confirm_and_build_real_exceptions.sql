-- ONE-LOOP-2 Block A step 1c: confirm_and_build's exceptions array was a
-- hard-coded '[]', with a comment saying it needed get_pod_refill_draft
-- extended first. That extension landed in the previous migration
-- (get_pod_refill_draft_exceptions). Wire it in. Nothing else in
-- confirm_and_build changes.

CREATE OR REPLACE FUNCTION public.confirm_and_build(p_plan_date date, p_machine_names text[] DEFAULT NULL, p_cars int DEFAULT 2)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '120s'
AS $function$
DECLARE
  v_user_id     uuid;
  v_role        text;
  v_dropped     int := 0;
  v_confirmed   int := 0;
  v_created     int := 0;
  v_build       jsonb;
  v_draft       jsonb;
  v_exceptions  jsonb;
  v_car         RECORD;
  v_n           int := 0;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'confirm_and_build', true);

  v_user_id := auth.uid();
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'confirm_and_build: caller % lacks required role', v_user_id;
  END IF;
  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'confirm_and_build: p_plan_date is required';
  END IF;
  IF p_machine_names IS NULL OR array_length(p_machine_names,1) = 0 THEN
    RAISE EXCEPTION 'confirm_and_build: p_machine_names must be a non-empty array (CS keeps the gate -- there is no automatic build, PRD-125 D5 replaced by ONE-LOOP Phase 6)';
  END IF;

  UPDATE public.machines_to_visit mtv
     SET status = 'cs_dropped', dropped_at = now(), dropped_by = v_user_id::text,
         dropped_reason = 'not in confirm_and_build list'
   WHERE mtv.plan_date = p_plan_date
     AND mtv.status IN ('picked','cs_added')
     AND NOT (mtv.official_name = ANY(p_machine_names));
  GET DIAGNOSTICS v_dropped = ROW_COUNT;

  UPDATE public.machines_to_visit mtv
     SET confirmed_at = now(), confirmed_by = v_user_id::text
   WHERE mtv.plan_date = p_plan_date
     AND mtv.official_name = ANY(p_machine_names)
     AND mtv.status IN ('picked','cs_added');
  GET DIAGNOSTICS v_confirmed = ROW_COUNT;

  INSERT INTO public.machines_to_visit (plan_date, machine_id, official_name, status, confirmed_at, confirmed_by, add_source)
  SELECT p_plan_date, m.machine_id, m.official_name, 'cs_added', now(), v_user_id::text, 'operator'
    FROM public.machines m
   WHERE m.official_name = ANY(p_machine_names)
     AND NOT EXISTS (
       SELECT 1 FROM public.machines_to_visit mtv2
        WHERE mtv2.plan_date = p_plan_date AND mtv2.machine_id = m.machine_id
          AND mtv2.status IN ('picked','cs_added')
     );
  GET DIAGNOSTICS v_created = ROW_COUNT;

  v_n := 0;
  FOR v_car IN
    SELECT mtv.machine_id,
           COALESCE(vmp.venue_group, vmp.building_id, mtv.official_name) AS cluster_key
      FROM public.machines_to_visit mtv
      LEFT JOIN public.v_machine_priority vmp ON vmp.machine_id = mtv.machine_id
     WHERE mtv.plan_date = p_plan_date
       AND mtv.official_name = ANY(p_machine_names)
       AND mtv.status IN ('picked','cs_added')
     ORDER BY COALESCE(vmp.venue_group, vmp.building_id, mtv.official_name),
              COALESCE(vmp.p_score_aed, vmp.p_score, 0) DESC
  LOOP
    UPDATE public.machines_to_visit
       SET car_no = (v_n % GREATEST(p_cars,1)) + 1
     WHERE plan_date = p_plan_date AND machine_id = v_car.machine_id
       AND status IN ('picked','cs_added');
    v_n := v_n + 1;
  END LOOP;

  BEGIN
    v_build := public._build_draft_core_v3(p_plan_date, false, false);
  EXCEPTION WHEN OTHERS THEN
    v_build := jsonb_build_object('status','error','error', SQLERRM);
  END;

  BEGIN
    SELECT jsonb_agg(d) INTO v_draft FROM public.get_pod_refill_draft(p_plan_date) d;
  EXCEPTION WHEN OTHERS THEN
    v_draft := jsonb_build_object('status','error','error', SQLERRM);
  END;

  BEGIN
    v_exceptions := public.get_pod_refill_draft_exceptions(p_plan_date);
  EXCEPTION WHEN OTHERS THEN
    v_exceptions := jsonb_build_array(jsonb_build_object('exception_type','error','detail',SQLERRM));
  END;

  RETURN jsonb_build_object(
    'plan_date', p_plan_date,
    'machines', p_machine_names,
    'cars', p_cars,
    'dropped', v_dropped,
    'confirmed', v_confirmed,
    'created_cs_added', v_created,
    'build', v_build,
    'draft', v_draft,
    'exceptions', v_exceptions
  );
END;
$function$;
