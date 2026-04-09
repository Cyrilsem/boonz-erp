-- Phase 0 R1 gap fix: explicit REVOKE authenticated on wrapper functions.
-- CREATE OR REPLACE FUNCTION in 220af7e preserved the stale EXECUTE grant
-- on authenticated that was introduced in 747612c. Function bodies are
-- vault-gated so no active exploit existed, but the grant needed cleanup.
REVOKE EXECUTE ON FUNCTION public.refresh_fleet_data(int) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trigger_lifecycle_eval() FROM authenticated;
