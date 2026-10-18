-- Rollback for 20261018074026_prd141_27_approve_per_machine.sql: remove the per-machine loop and its variables.
-- FE part (RefillPlanningTab and RefillPlanReview read status / results): git revert the commit
-- "feat(prd-141): item 27 approve_refill_plan per-machine results" first.
DO $rb$
DECLARE v text; i int; j int; tail text;
BEGIN
  v := pg_get_functiondef('public.approve_refill_plan(date,text[],jsonb)'::regprocedure);
  i := strpos(v, '  -- PRD-141 item 27 (per-machine results)');
  j := strpos(v, '  v_pm_dispatch      int := 0;' || chr(10));
  v := substr(v, 1, i - 1) || substr(v, j + length('  v_pm_dispatch      int := 0;' || chr(10)));
  tail := '      ''results'', v_pm_results, ''writer'', ''push_plan_to_dispatch'');' || chr(10) || '  END IF;';
  i := strpos(v, chr(10) || chr(10) || '  -- PRD-141 item 27: several machines');
  j := strpos(v, tail);
  v := substr(v, 1, i) || substr(v, j + length(tail) + 1);
  EXECUTE v;
END $rb$;
REVOKE EXECUTE ON FUNCTION public.approve_refill_plan(date, text[], jsonb) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.approve_refill_plan(date, text[], jsonb) TO authenticated, service_role;
