-- PRD-040 C1 follow-up: revoke anon EXECUTE on get_vox_returns.
-- Supabase ALTER DEFAULT PRIVILEGES auto-granted EXECUTE to anon at CREATE; this DEFINER reader
-- bypasses RLS and resolves staff full_name, so it must not be callable pre-auth (operator-facing only).
-- Forward-only privilege tightening; authenticated + service_role retain EXECUTE.
REVOKE EXECUTE ON FUNCTION public.get_vox_returns(date, date, uuid) FROM anon;
