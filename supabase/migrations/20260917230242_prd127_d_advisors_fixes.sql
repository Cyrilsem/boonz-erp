-- PRD-127 Block D: mcp__supabase__get_advisors findings on objects created or changed tonight.
--
-- Performance: 3 missing FK indexes on the two new tables.
-- Security: engine_add_pod and insert_driver_remove_line (both changed in Block C) are still
-- anon-executable (Supabase's default grant; unrelated to tonight's edits, but both are
-- objects this session changed, so in scope per the same rule ONE-LOOP-3 applied). Neither has
-- a legitimate unauthenticated use case -- engine_add_pod requires operator_admin internally
-- but lets a NULL auth.uid() (cron/service) through, which also means anon;
-- insert_driver_remove_line's own check would reject a NULL caller, but there is no reason to
-- leave the REST path reachable at all. propose_refill_plan, add_refill_directive,
-- retire_refill_directive, and bind_dispatch_fefo are correctly flagged as
-- authenticated-executable (WARN) but that is intentional and expected -- authenticated is the
-- only way a real signed-in operator/manager can call them, and each already gates its own
-- authorization internally; that lint fires on hundreds of pre-existing RPCs across this
-- codebase and is not something to "fix" per-function.

CREATE INDEX IF NOT EXISTS idx_refill_directives_created_by
  ON public.refill_directives (created_by);
CREATE INDEX IF NOT EXISTS idx_refill_directives_retired_by
  ON public.refill_directives (retired_by);
CREATE INDEX IF NOT EXISTS idx_refill_swap_params_updated_by
  ON public.refill_swap_params (updated_by);

REVOKE EXECUTE ON FUNCTION public.engine_add_pod(date, integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.insert_driver_remove_line(uuid, uuid, uuid, uuid, numeric, date, text) FROM anon;
