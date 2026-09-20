-- ONE-LOOP-3 Job 3 Phase 10 rehearsal: second, deeper bug in the same
-- approve_pod_refill_plan chain, found after the push-before-stitch-status
-- fix (20260915084132) still showed dispatch_row_count=0.
--
-- stitch_pod_to_boonz -> write_refill_plan always inserts fresh
-- refill_plan_output rows with operator_status hardcoded to 'pending'
-- (confirmed by calling write_refill_plan directly and reading the row back).
-- push_plan_to_dispatch's own FOR loop only picks up
-- `operator_status = 'approved'` rows. Nothing in confirm_and_build ->
-- approve_pod_refill_plan -> stitch_pod_to_boonz ever flips
-- refill_plan_output.operator_status from 'pending' to 'approved' -- so the
-- explicit push loop always iterates over machines with zero eligible rows,
-- and dispatch_row_count is always 0 no matter how many rows were "approved"
-- at the pod_refill_plan level.
--
-- This also explains a live trigger already sitting on the table:
-- trg_refill_plan_output_approve_to_dispatch fires
-- `push_plan_to_dispatch(NEW.plan_date, NEW.machine_name)` itself whenever a
-- row's operator_status transitions TO 'approved' with dispatched=false --
-- the schema was clearly designed for this UPDATE to be the trigger for
-- dispatch, but approve_pod_refill_plan never performs it.
--
-- Fix: after stitch_pod_to_boonz, flip operator_status to 'approved' for the
-- rows just written for the approved machines. This both fires the existing
-- trigger AND makes the function's own explicit push loop (kept as-is,
-- push_plan_to_dispatch is idempotent per dispatch line via its own
-- existing-row / ON CONFLICT checks, so the trigger and the loop both firing
-- is redundant but harmless, not duplicative) find real rows to push.
--
-- Verified in a rolled-back transaction: dispatch_row_count went from 0 to a
-- real positive count on the same 3-machine, 2026-09-16 test case.

CREATE OR REPLACE FUNCTION public.approve_pod_refill_plan(p_plan_date date, p_machine_names text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '120s'
AS $function$
DECLARE
  v_user_id      uuid;
  v_approved     integer;
  v_stitch       jsonb;
  v_push_results jsonb := '[]'::jsonb;
  v_machine      text;
  v_push_one     jsonb;
  v_dispatch_rows int := 0;
  v_approved_machines text[];
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'approve_pod_refill_plan', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id AND up.role = 'operator_admin'
  ) THEN
    RAISE EXCEPTION 'approve_pod_refill_plan: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'p_plan_date required';
  END IF;

  WITH targets AS (
    SELECT prp.plan_date, prp.machine_id, prp.shelf_id, prp.pod_product_id, prp.action
      FROM public.pod_refill_plan prp
      JOIN public.machines m ON m.machine_id = prp.machine_id
     WHERE prp.plan_date = p_plan_date
       AND prp.status = 'draft'
       AND (p_machine_names IS NULL OR m.official_name = ANY(p_machine_names))
  ),
  updated AS (
    UPDATE public.pod_refill_plan prp
       SET status      = 'approved',
           approved_at = now(),
           approved_by = v_user_id,
           updated_at  = now()
      FROM targets t
     WHERE prp.plan_date     = t.plan_date
       AND prp.machine_id    = t.machine_id
       AND prp.shelf_id      = t.shelf_id
       AND prp.pod_product_id= t.pod_product_id
       AND prp.action        = t.action
    RETURNING prp.machine_id
  )
  SELECT array_agg(DISTINCT m.official_name), count(*)
    INTO v_approved_machines, v_approved
    FROM updated u
    JOIN public.machines m ON m.machine_id = u.machine_id;
  v_approved := COALESCE(v_approved, 0);

  BEGIN
    v_stitch := public.stitch_pod_to_boonz(p_plan_date, false, false, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_stitch := jsonb_build_object('status','error','error', SQLERRM);
  END;

  -- write_refill_plan (called inside stitch_pod_to_boonz) always writes fresh
  -- refill_plan_output rows with operator_status='pending'. Flip them to
  -- 'approved' here -- this is what trg_refill_plan_output_approve_to_dispatch
  -- is waiting on, and what push_plan_to_dispatch's own WHERE clause requires.
  UPDATE public.refill_plan_output
     SET operator_status = 'approved'
   WHERE plan_date = p_plan_date
     AND (p_machine_names IS NULL OR machine_name = ANY(COALESCE(v_approved_machines, p_machine_names)))
     AND operator_status = 'pending'
     AND COALESCE(dispatched, false) = false;

  FOR v_machine IN
    SELECT unnest(COALESCE(v_approved_machines, ARRAY[]::text[]))
  LOOP
    BEGIN
      v_push_one := public.push_plan_to_dispatch(p_plan_date, v_machine);
    EXCEPTION WHEN OTHERS THEN
      v_push_one := jsonb_build_object('status','error','error', SQLERRM, 'machine', v_machine);
    END;
    v_push_results := v_push_results || jsonb_build_array(v_push_one || jsonb_build_object('machine', v_machine));
  END LOOP;

  SELECT count(*) INTO v_dispatch_rows
    FROM public.refill_dispatching rd
    JOIN public.machines m ON m.machine_id = rd.machine_id
   WHERE rd.dispatch_date = p_plan_date
     AND (p_machine_names IS NULL OR m.official_name = ANY(p_machine_names))
     AND COALESCE(rd.cancelled,false) = false
     AND COALESCE(rd.skipped,false) = false;

  RETURN jsonb_build_object(
    'plan_date',        p_plan_date,
    'approved_rows',    v_approved,
    'scope',            CASE WHEN p_machine_names IS NULL THEN 'all' ELSE 'subset' END,
    'machine_count',    COALESCE(array_length(p_machine_names, 1), 0),
    'stitch',           v_stitch,
    'push_results',     v_push_results,
    'dispatch_row_count', v_dispatch_rows
  );
END;
$function$;
