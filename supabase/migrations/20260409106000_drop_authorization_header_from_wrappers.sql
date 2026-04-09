-- Phase 0 R1 hotfix: drop Authorization header from Edge Function wrappers.
-- Smoke test of request_id 1 returned status_code=401 error="Invalid token"
-- because refresh-stage1 calls auth.getUser() on the Authorization: Bearer header,
-- which rejects service_role JWTs (they are not user access tokens).
-- The production n8n operational-signals workflow calls refresh-stage1 with apikey only
-- and works fine. Wrappers now match that pattern.
-- Vault secret lookup is preserved — centralized storage for rotation.
-- Grants unchanged: service_role only on both functions.

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
      'Content-Type', 'application/json',
      'apikey',       v_service_key
    ),
    body    := jsonb_build_object('lookback_days', lookback_days)
  ) INTO v_request_id;

  RETURN v_request_id;
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_fleet_data(int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_fleet_data(int) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_fleet_data(int) TO service_role;

COMMENT ON FUNCTION public.refresh_fleet_data(int) IS
'Invokes refresh-stage1 Edge Function asynchronously via pg_net. Sends apikey header only — no Authorization header (auth.getUser() rejects service_role JWTs with 401). Reads service_role JWT from supabase_vault (secret name: edge_function_service_key). Returns net.http_post request_id. Callable by service_role only. Nightly cron calls this as postgres (superuser bypass). See docs/refill_engine_bible_v4.html.';


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
      'Content-Type', 'application/json',
      'apikey',       v_service_key
    ),
    body    := '{}'::jsonb
  ) INTO v_request_id;

  RETURN v_request_id;
END;
$$;

REVOKE ALL ON FUNCTION public.trigger_lifecycle_eval() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.trigger_lifecycle_eval() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.trigger_lifecycle_eval() TO service_role;

COMMENT ON FUNCTION public.trigger_lifecycle_eval() IS
'Invokes evaluate-lifecycle Edge Function asynchronously via pg_net. Sends apikey header only — no Authorization header. Reads service_role JWT from supabase_vault. Callable by service_role only.';
