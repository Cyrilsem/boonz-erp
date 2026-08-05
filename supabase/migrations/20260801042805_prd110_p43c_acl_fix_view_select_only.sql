-- PRD-110 P4.3c ACL correction (leg 88, forward-only per Article 12).
-- S-140: the Supabase default-privileges trap is WIDER than leg 87 recorded.
-- It grants explicitly PER ROLE, so `REVOKE ALL ... FROM PUBLIC` removes nothing,
-- and it applies to VIEWS and to `authenticated`, not only to functions and `anon`.
-- v_proposal_acceptance_v3 landed with authenticated=arwdDxtm; Cody required the
-- v_planning_pins_active_v3 convention (authenticated=r). Read relacl back, always.
REVOKE ALL ON public.v_proposal_acceptance_v3 FROM authenticated;
GRANT SELECT ON public.v_proposal_acceptance_v3 TO authenticated;
