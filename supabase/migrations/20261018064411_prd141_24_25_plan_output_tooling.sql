-- PRD-141 items 24 (G2) and 25 (G1): plan lines can be rejected cleanly, and approving a machine no longer
-- re-runs the dispatch push once per row.
-- 25. trg_refill_plan_output_approve_to_dispatch was AFTER UPDATE OF operator_status FOR EACH ROW and called
--     push_plan_to_dispatch(plan_date, machine) for EVERY row that turned approved: a 40-row machine ran the
--     ~30k-character push 40 times in one transaction (and re-ran the WEIMI slot guard 40 times, which is why
--     the same guard alert appears 4-5 times). Replaced by a statement-level trigger with transition tables
--     that pushes once per distinct (plan_date, machine_name) that turned approved in the statement. Same
--     exception handling and alerts. (Transition tables cannot be combined with a column list, so the trigger
--     is AFTER UPDATE and the old condition moves into the function.)
-- 24. reject_plan_lines(plan_date, machine_id, line_ids, reason): one set-based UPDATE of pending rows to
--     rejected (all pending rows of that machine and date, or only the given ids). SECURITY DEFINER,
--     operator_admin / superadmin only. Replaces the raw FE update in RefillPlanReview, which had no
--     plan_date filter and rejected every pending date for the machine.
-- Rollback: supabase/rollbacks/prd141_24_25_rollback.sql.

CREATE OR REPLACE FUNCTION public.trg_fire_dispatch_on_approval_stmt()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  r record;
  v_push_result jsonb;
BEGIN
  FOR r IN
    SELECT DISTINCT n.plan_date, n.machine_name
      FROM new_rows n JOIN old_rows o ON o.id = n.id
     WHERE n.operator_status = 'approved'
       AND o.operator_status IS DISTINCT FROM 'approved'
       AND COALESCE(n.dispatched, false) = false
  LOOP
    BEGIN
      v_push_result := public.push_plan_to_dispatch(r.plan_date, r.machine_name);
      IF COALESCE(v_push_result->>'status','') <> 'ok' THEN
        INSERT INTO public.monitoring_alerts (source, severity, payload)
        VALUES ('dispatch_bridge_nonok', 'warning',
          jsonb_build_object('plan_date', r.plan_date, 'machine_name', r.machine_name,
                             'push_result', v_push_result, 'detected_at', now()));
      END IF;
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO public.monitoring_alerts (source, severity, payload)
      VALUES ('dispatch_bridge_exception', 'critical',
        jsonb_build_object('plan_date', r.plan_date, 'machine_name', r.machine_name,
                           'sqlerrm', SQLERRM, 'detected_at', now()));
    END;
  END LOOP;
  RETURN NULL;
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.trg_fire_dispatch_on_approval_stmt() FROM public, anon, authenticated;

DROP TRIGGER IF EXISTS trg_refill_plan_output_approve_to_dispatch ON public.refill_plan_output;
CREATE TRIGGER trg_refill_plan_output_approve_to_dispatch_stmt
  AFTER UPDATE ON public.refill_plan_output
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.trg_fire_dispatch_on_approval_stmt();

CREATE OR REPLACE FUNCTION public.reject_plan_lines(p_plan_date date, p_machine_id uuid, p_line_ids uuid[] DEFAULT NULL, p_reason text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role text;
  v_machine text;
  v_n int;
  v_t0 timestamptz := clock_timestamp();
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NULL OR v_role IS NULL OR v_role NOT IN ('operator_admin', 'superadmin') THEN
    RAISE EXCEPTION 'reject_plan_lines: forbidden for role %, operator_admin only', COALESCE(v_role, 'unknown');
  END IF;
  IF p_plan_date IS NULL OR p_machine_id IS NULL THEN
    RAISE EXCEPTION 'reject_plan_lines: p_plan_date and p_machine_id are required';
  END IF;
  SELECT official_name INTO v_machine FROM public.machines WHERE machine_id = p_machine_id;
  IF v_machine IS NULL THEN
    RAISE EXCEPTION 'reject_plan_lines: machine % not found', p_machine_id;
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'reject_plan_lines', true);
  PERFORM set_config('app.mutation_reason', format('reject_plan_lines %s %s by %s: %s', p_plan_date, v_machine, auth.uid(), COALESCE(p_reason, '')), true);

  UPDATE public.refill_plan_output
     SET operator_status = 'rejected',
         reviewed_at = now(),
         operator_comment = left(COALESCE(NULLIF(trim(operator_comment), '') || ' | ', '') || COALESCE(NULLIF(trim(p_reason), ''), 'rejected'), 500)
   WHERE plan_date = p_plan_date
     AND machine_name = v_machine
     AND operator_status = 'pending'
     AND (p_line_ids IS NULL OR id = ANY (p_line_ids));
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object('status', 'ok', 'plan_date', p_plan_date, 'machine', v_machine,
    'rejected', v_n, 'ms', round(extract(epoch FROM clock_timestamp() - v_t0) * 1000));
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.reject_plan_lines(date, uuid, uuid[], text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.reject_plan_lines(date, uuid, uuid[], text) TO authenticated, service_role;
