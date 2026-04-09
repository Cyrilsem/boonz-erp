-- CC-00b Step 5e: trigger_lifecycle_eval() — pg_net wrapper for evaluate-lifecycle Edge Function
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
    RAISE EXCEPTION 'edge_function_service_key not found in vault. Run check_edge_function_service_key() for instructions.';
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
'Invokes the evaluate-lifecycle Edge Function asynchronously via pg_net. Returns a net.http_post request_id. Poll with wait_for_request().';
