-- CC-00b Step 5c: refresh_fleet_data() — pg_net wrapper for refresh-stage1 Edge Function
-- Returns the pg_net request_id (bigint). Poll with wait_for_request().
-- Requires edge_function_service_key in supabase_vault.
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
'Invokes the refresh-stage1 Edge Function asynchronously via pg_net. Returns a net.http_post request_id. Poll net._http_response for completion. Used by Claude via execute_sql for autonomous data refresh.';
