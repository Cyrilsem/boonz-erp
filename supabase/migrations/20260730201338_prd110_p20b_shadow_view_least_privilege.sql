-- PRD-110 P2.0b follow-up. Default privileges granted `authenticated` the full
-- arwdDxtm set on v_blocked_demand_shadow_v3; the original migration's REVOKE
-- targeted `anon` only. Writes through the view fail today at the base table
-- (authenticated holds SELECT only on pod_refills_shadow), so this closes a
-- paper hole rather than a live one — but a future grant on the base table
-- would open it silently, which is exactly the class of drift Article 3 exists
-- to prevent. Least privilege, stated explicitly.
--
-- ⚠️ NOTE FOR A LATER LEG: v_shadow_vs_live_plan_v3 (leg 12) carries the same
-- authenticated=arwdDxtm grant. Left untouched here deliberately — it is
-- outside this atomic unit (LAW 10). Recorded as RISK 73.

REVOKE ALL ON public.v_blocked_demand_shadow_v3 FROM authenticated;
GRANT SELECT ON public.v_blocked_demand_shadow_v3 TO authenticated;
