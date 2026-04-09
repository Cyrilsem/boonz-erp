-- Phase 0 R1 follow-up: rewrite Edge Function wrappers to use public anon key.
-- Removes vault dependency — vault.secrets was never populated and the Edge Functions
-- only require an apikey header, which the anon key satisfies.
-- The anon key is already published in the Vercel frontend bundle and n8n workflows.
-- Authorization: Bearer header removed entirely; only apikey + Content-Type sent.
--
-- Function rename:
--   check_edge_function_service_key()  → now a shim that calls check_edge_function_wrappers_ready()
--   check_edge_function_wrappers_ready() → new canonical preflight (checks pg_net is installed)
-- Shim kept for backwards compatibility with any existing scripts.
--
-- wait_for_request() is unchanged.
-- supabase_vault extension is NOT dropped — retained for future use (Weimi credentials, etc).
-- refresh_fleet_data() grant extended to authenticated (in addition to service_role) so
-- Claude's execute_sql calls work without needing to switch roles.

-- 1. refresh_fleet_data()
CREATE OR REPLACE FUNCTION public.refresh_fleet_data(lookback_days int DEFAULT 90)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_anon_key constant text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVpemNleG9wY3VveWN1b3NpdHRtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzMyMjk0NzYsImV4cCI6MjA4ODgwNTQ3Nn0.GES2oJ0GLA3P1LsycQhp4XkVsnmERB0jIwNn8eSFSXg';
  v_request_id bigint;
BEGIN
  SELECT net.http_post(
    url     := 'https://eizcexopcuoycuosittm.supabase.co/functions/v1/refresh-stage1',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey',       v_anon_key
    ),
    body    := jsonb_build_object('lookback_days', lookback_days)
  ) INTO v_request_id;

  RETURN v_request_id;
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_fleet_data(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_fleet_data(int) TO service_role, authenticated;

COMMENT ON FUNCTION public.refresh_fleet_data(int) IS
'Invokes refresh-stage1 Edge Function async via pg_net using the public anon key (safe to hardcode — it is already published in the frontend bundle). Returns a net.http_post request_id. Poll net._http_response for completion via wait_for_request().';


-- 2. trigger_lifecycle_eval()
CREATE OR REPLACE FUNCTION public.trigger_lifecycle_eval()
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_anon_key constant text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVpemNleG9wY3VveWN1b3NpdHRtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzMyMjk0NzYsImV4cCI6MjA4ODgwNTQ3Nn0.GES2oJ0GLA3P1LsycQhp4XkVsnmERB0jIwNn8eSFSXg';
  v_request_id bigint;
BEGIN
  SELECT net.http_post(
    url     := 'https://eizcexopcuoycuosittm.supabase.co/functions/v1/evaluate-lifecycle',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey',       v_anon_key
    ),
    body    := '{}'::jsonb
  ) INTO v_request_id;

  RETURN v_request_id;
END;
$$;

REVOKE ALL ON FUNCTION public.trigger_lifecycle_eval() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.trigger_lifecycle_eval() TO service_role, authenticated;

COMMENT ON FUNCTION public.trigger_lifecycle_eval() IS
'Invokes evaluate-lifecycle Edge Function async via pg_net using the public anon key. Returns a net.http_post request_id. Poll with wait_for_request().';


-- 3. New canonical preflight: check_edge_function_wrappers_ready()
CREATE OR REPLACE FUNCTION public.check_edge_function_wrappers_ready()
RETURNS TABLE(status text, message text)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_pg_net_installed boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_extension WHERE extname = 'pg_net'
  ) INTO v_pg_net_installed;

  IF NOT v_pg_net_installed THEN
    RETURN QUERY SELECT 'error'::text,
      'pg_net extension is not installed. Run: CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;'::text;
    RETURN;
  END IF;

  RETURN QUERY SELECT 'ready'::text,
    'pg_net is installed. Wrappers use the public anon key (no vault secret required). Call refresh_fleet_data(90) to invoke refresh-stage1, or trigger_lifecycle_eval() to invoke evaluate-lifecycle.'::text;
END;
$$;

REVOKE ALL ON FUNCTION public.check_edge_function_wrappers_ready() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_edge_function_wrappers_ready() TO authenticated, service_role;

COMMENT ON FUNCTION public.check_edge_function_wrappers_ready() IS
'Preflight check for the pg_net Edge Function wrappers. Confirms pg_net is installed. No vault secret is required — wrappers use the public anon key.';


-- 4. Backwards-compat shim for check_edge_function_service_key()
CREATE OR REPLACE FUNCTION public.check_edge_function_service_key()
RETURNS TABLE(status text, message text)
LANGUAGE sql SECURITY DEFINER AS $$
  SELECT * FROM public.check_edge_function_wrappers_ready();
$$;

REVOKE ALL ON FUNCTION public.check_edge_function_service_key() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_edge_function_service_key() TO authenticated, service_role;

COMMENT ON FUNCTION public.check_edge_function_service_key() IS
'Backwards-compat shim — delegates to check_edge_function_wrappers_ready(). Vault secret no longer required.';
