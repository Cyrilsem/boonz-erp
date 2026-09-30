-- Rollback for PRD-137 F1b (auto pickup on full machine completion + mark_picked_up takes every
-- currently-packed line at press time, drafted 2026-09-30 daytime, NOT YET APPLIED -- see the
-- migration file's own header). Restores mark_picked_up to its pre-F1b body (literal
-- p_dispatch_ids only) and drops the new completion trigger/function.
DROP TRIGGER IF EXISTS trg_auto_pickup_on_completion_insert ON public.refill_dispatching;
DROP TRIGGER IF EXISTS trg_auto_pickup_on_completion_update ON public.refill_dispatching;
DROP FUNCTION IF EXISTS public.tg_auto_pickup_on_machine_complete();

CREATE OR REPLACE FUNCTION public.mark_picked_up(p_dispatch_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role           text;
  v_caller_id             uuid;
  v_picked_up_count       int := 0;
  v_already_picked_up_ids uuid[];
  v_not_packed_ids        uuid[];
  v_not_found_ids         uuid[];
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'mark_picked_up', true);

  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'No authenticated caller');
  END IF;

  -- Role validation: field driver, warehouse manager (in case they pick up themselves), or admin.
  SELECT role INTO v_caller_role
  FROM public.user_profiles
  WHERE id = v_caller_id;

  IF v_caller_role NOT IN ('field_staff', 'warehouse', 'operator_admin', 'superadmin', 'manager') THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'error',  'Insufficient role — pickup requires field_staff / warehouse / admin'
    );
  END IF;

  IF p_dispatch_ids IS NULL OR array_length(p_dispatch_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'p_dispatch_ids must be a non-empty array');
  END IF;

  -- Compute "not found" / "not packed" / "already picked up" before the UPDATE
  SELECT array_agg(id) INTO v_not_found_ids
  FROM unnest(p_dispatch_ids) AS id
  WHERE NOT EXISTS (
    SELECT 1 FROM public.refill_dispatching d WHERE d.dispatch_id = id
  );

  SELECT array_agg(d.dispatch_id) INTO v_not_packed_ids
  FROM public.refill_dispatching d
  WHERE d.dispatch_id = ANY(p_dispatch_ids)
    AND d.packed     = false;

  SELECT array_agg(d.dispatch_id) INTO v_already_picked_up_ids
  FROM public.refill_dispatching d
  WHERE d.dispatch_id = ANY(p_dispatch_ids)
    AND d.packed      = true
    AND d.picked_up   = true;

  -- Apply: only flip rows that are packed=true AND picked_up=false (Article 5 state machine)
  UPDATE public.refill_dispatching
  SET picked_up = true
  WHERE dispatch_id = ANY(p_dispatch_ids)
    AND packed     = true
    AND picked_up  = false;

  GET DIAGNOSTICS v_picked_up_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'status',                'ok',
    'picked_up_count',       v_picked_up_count,
    'already_picked_up_ids', COALESCE(v_already_picked_up_ids, ARRAY[]::uuid[]),
    'not_packed_ids',        COALESCE(v_not_packed_ids,        ARRAY[]::uuid[]),
    'not_found_ids',         COALESCE(v_not_found_ids,         ARRAY[]::uuid[]),
    'caller_id',             v_caller_id,
    'caller_role',           v_caller_role
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'status', 'error',
    'error',  SQLERRM,
    'detail', SQLSTATE
  );
END;
$function$;
