-- ONE-LOOP-3 Job 4: mcp__supabase__get_advisors (security) flagged
-- anon_security_definer_function_executable on three more functions changed
-- tonight -- get_machine_health (gained p_score_aed/car_no/
-- top_contributors_aed), push_plan_to_dispatch and approve_pod_refill_plan
-- (both real bug fixes). All Supabase's default grant, none with a
-- legitimate unauthenticated use case: get_machine_health is FE dashboard
-- data, the other two mutate live dispatch/plan state.
REVOKE EXECUTE ON FUNCTION public.get_machine_health() FROM anon;
REVOKE EXECUTE ON FUNCTION public.push_plan_to_dispatch(date, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.approve_pod_refill_plan(date, text[]) FROM anon;
