-- Revert of commit 747612c (rewrite_edge_function_wrappers_to_use_anon_key).
-- Restores vault-based auth on all Edge Function wrappers.
--
-- Reasons for revert:
-- 1. No JWT of any kind belongs in a migration file, even a public anon key.
-- 2. Granting refresh_fleet_data/trigger_lifecycle_eval to `authenticated` lets every
--    app user fire expensive Weimi syncs and full lifecycle recomputes.
-- 3. check_edge_function_wrappers_ready() only checked pg_net existence — not a real preflight.
-- 4. Credential rotation should be vault.update_secret(), not a new migration.
--
-- After this migration:
-- - check_edge_function_service_key() returns 'missing' until operator populates vault
-- - refresh_fleet_data() and trigger_lifecycle_eval() raise an exception if vault secret absent
-- - Both wrappers are EXECUTE service_role only
-- - check_edge_function_wrappers_ready() is dropped entirely
-- - No JWT appears anywhere in any function body

-- Restore vault-based readiness check
CREATE OR REPLACE FUNCTION public.check_edge_function_service_key()
RETURNS TABLE(status text, message text)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_secret_id uuid;
BEGIN
  SELECT id INTO v_secret_id FROM vault.secrets WHERE name = 'edge_function_service_key' LIMIT 1;
  IF v_secret_id IS NULL THEN
    RETURN QUERY SELECT 'missing'::text,
      'Secret edge_function_service_key not found in vault. Operator must run: SELECT vault.create_secret(''<service_role_key>'', ''edge_function_service_key'', ''Service role JWT for Edge Function wrapper auth'');'::text;
  ELSE
    RETURN QUERY SELECT 'present'::text, 'Secret found with id ' || v_secret_id::text;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.check_edge_function_service_key() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_edge_function_service_key() TO authenticated, service_role;

-- Drop the anon-key shim and its new function introduced in 747612c
DROP FUNCTION IF EXISTS public.check_edge_function_wrappers_ready();

-- Rewrite refresh_fleet_data to read service_role key from vault
CREATE OR REPLACE FUNCTION public.refresh_fleet_data(lookback_days int DEFAULT 90)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_service_key text;
  v_request_id  bigint;
  v_url         text := 'https://eizcexopcuoycuosittm.supabase.co/functions/v1/refresh-stage1';
BEGIN
  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets
  WHERE name = 'edge_function_service_key'
  LIMIT 1;

  IF v_service_key IS NULL THEN
    RAISE EXCEPTION 'edge_function_service_key not found in vault. Run check_edge_function_service_key() for instructions.';
  END IF;

  SELECT net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'apikey',        v_service_key,
      'Authorization', 'Bearer ' || v_service_key
    ),
    body    := jsonb_build_object('lookback_days', lookback_days)
  ) INTO v_request_id;

  RETURN v_request_id;
END;
$$;
REVOKE ALL ON FUNCTION public.refresh_fleet_data(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_fleet_data(int) TO service_role;

COMMENT ON FUNCTION public.refresh_fleet_data(int) IS
'Invokes refresh-stage1 Edge Function asynchronously via pg_net. Reads service_role JWT from supabase_vault (secret name: edge_function_service_key). Returns net.http_post request_id. Callable by service_role only. Nightly cron calls this as postgres (superuser bypass). See docs/refill_engine_bible_v4.html.';

-- Rewrite trigger_lifecycle_eval to read service_role key from vault
CREATE OR REPLACE FUNCTION public.trigger_lifecycle_eval()
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_service_key text;
  v_request_id  bigint;
BEGIN
  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets
  WHERE name = 'edge_function_service_key'
  LIMIT 1;

  IF v_service_key IS NULL THEN
    RAISE EXCEPTION 'edge_function_service_key not found in vault.';
  END IF;

  SELECT net.http_post(
    url     := 'https://eizcexopcuoycuosittm.supabase.co/functions/v1/evaluate-lifecycle',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'apikey',        v_service_key,
      'Authorization', 'Bearer ' || v_service_key
    ),
    body    := '{}'::jsonb
  ) INTO v_request_id;

  RETURN v_request_id;
END;
$$;
REVOKE ALL ON FUNCTION public.trigger_lifecycle_eval() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.trigger_lifecycle_eval() TO service_role;

COMMENT ON FUNCTION public.trigger_lifecycle_eval() IS
'Invokes evaluate-lifecycle Edge Function asynchronously via pg_net. Reads service_role JWT from supabase_vault. Callable by service_role only.';
