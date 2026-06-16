-- PRD-019 D1b: writability guard helper for the pod engine.
-- NOT APPLIED. Author-only; apply after CS sign-off (after D1a).
-- Read-only assertion (mirrors _assert_gate_zero). Raises when the pod engine
-- must NOT rebuild a plan_date:
--   1. the boonz-level plan already has approved refill_plan_output rows
--      (committed / dispatched intent) for the scope, or
--   2. the plan_date is locked by a DIFFERENT writer context than this session.
-- engine_add_pod / engine_swap_pod call it plan-wide; engine_finalize_pod calls
-- it machine-scoped (p_machine_ids) so a scoped commit/amend of other machines
-- is not blocked by an already-approved sibling.
CREATE OR REPLACE FUNCTION public._assert_refill_plan_writable(
  p_plan_date   date,
  p_machine_ids uuid[] DEFAULT NULL
) RETURNS void
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
DECLARE
  v_ctx  text := COALESCE(current_setting('app.refill_lock_context', true), '');
  v_lock public.refill_plan_lock%ROWTYPE;
  v_approved integer;
BEGIN
  -- (1) approved-output guard. refill_plan_output keys machines by official_name,
  -- so scope filtering maps the uuid[] through machines.
  SELECT COUNT(*) INTO v_approved
    FROM public.refill_plan_output rpo
   WHERE rpo.plan_date = p_plan_date
     AND rpo.operator_status = 'approved'
     AND (
       p_machine_ids IS NULL
       OR rpo.machine_name IN (
         SELECT m.official_name FROM public.machines m WHERE m.machine_id = ANY (p_machine_ids)
       )
     );

  IF v_approved > 0 THEN
    RAISE EXCEPTION
      'refill plan for % already has % approved refill_plan_output row(s)%; engine rebuild refused (PRD-019 D1b). Reset via reset_approved_undispatched / reset_and_restitch before rebuilding.',
      p_plan_date, v_approved,
      CASE WHEN p_machine_ids IS NULL THEN '' ELSE ' for the scoped machines' END;
  END IF;

  -- (2) cross-context lock guard.
  SELECT * INTO v_lock FROM public.refill_plan_lock WHERE plan_date = p_plan_date;
  IF FOUND AND v_lock.context <> v_ctx THEN
    RAISE EXCEPTION
      'refill plan for % is locked by context "%" (held since %); engine rebuild refused (PRD-019 D1b). Acquire the lock for your context or wait for release.',
      p_plan_date, v_lock.context, v_lock.locked_at;
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public._assert_refill_plan_writable(date, uuid[]) TO anon, authenticated, service_role;

COMMENT ON FUNCTION public._assert_refill_plan_writable(date, uuid[]) IS
'PRD-019 D1b guard. Raises if the plan_date has approved refill_plan_output rows (scope-aware) or is locked by another writer context. Called by engine_add_pod/engine_swap_pod (plan-wide) and engine_finalize_pod (machine-scoped) before any mutation.';
