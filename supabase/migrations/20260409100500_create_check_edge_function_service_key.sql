-- CC-00b Step 5b: Vault secret verification function
-- The service role key must be stored manually in supabase_vault by the operator.
-- Run: SELECT * FROM public.check_edge_function_service_key(); to verify.
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

COMMENT ON FUNCTION public.check_edge_function_service_key() IS
'Verifies that the edge_function_service_key secret exists in supabase_vault. Run this before using refresh_fleet_data() or trigger_lifecycle_eval().';
