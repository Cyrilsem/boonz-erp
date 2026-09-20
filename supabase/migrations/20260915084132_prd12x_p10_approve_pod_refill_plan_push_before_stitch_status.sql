-- ONE-LOOP-3 Job 3 Phase 10 rehearsal: caught a real, live-affecting bug in
-- approve_pod_refill_plan (built earlier this session, migration
-- 20260915001300_prd12x_p6_confirm_and_build.sql) before it could bite
-- tonight's real 19:00 approve.
--
-- Sequence was: UPDATE pod_refill_plan SET status='approved' -> call
-- stitch_pod_to_boonz(...) -> loop `WHERE prp.status = 'approved'` to find
-- which machines to push_plan_to_dispatch. stitch_pod_to_boonz itself
-- advances status from 'approved' to 'stitched' as part of its own work, so
-- by the time the push loop's WHERE clause runs, zero rows are still
-- 'approved' -- push_results comes back empty and dispatch_row_count is
-- always 0, no matter how many rows were genuinely approved.
--
-- Verified directly (rolled-back transaction, 2026-09-16, 3 real machines):
-- pod_refill_plan status went draft (30) -> approved -> stitched (30) by the
-- time the push loop ran, and push_results was []. Confirmed harmless on
-- 09-15's real data (139 already-stitched rows there predate this migration
-- landing tonight, pushed via the pre-Phase-6 flow) but would have silently
-- no-op'd every approve_pod_refill_plan push from tonight's 19:00 live run
-- onward.
--
-- Fix: capture the machine names to push from the UPDATE...RETURNING itself
-- (the instant they are genuinely 'approved'), before stitch_pod_to_boonz
-- runs, instead of re-querying by status afterward.

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
  -- Captured HERE, the instant these rows are genuinely 'approved' -- before
  -- stitch_pod_to_boonz runs and moves them on to 'stitched'.
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
