-- PRD-021 — abandon_intent service-role bypass.
-- Cody-approved (Articles 1, 4, 5, 8, 12). Applied to prod 2026-06-10 via MCP
-- (Supabase migration name `prd021_abandon_intent_service_role_bypass`); this file
-- keeps the repo in sync. Body verbatim except the one-line role-guard bypass:
--   v_user_id IS NULL OR NOT EXISTS(...)   ->   v_user_id IS NOT NULL AND NOT EXISTS(...)
-- so the service-role connection (auth.uid() IS NULL) passes while an authenticated
-- non-operator is still rejected. Same bypass class as
-- prd019_set_dispatch_include_service_role_bypass. Used to close the Ritz Cracker
-- decommission intent ba1ef467 (CS lifted the decommission 2026-06-10).

CREATE OR REPLACE FUNCTION public.abandon_intent(p_intent_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id        uuid;
  v_existing_status text;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'abandon_intent', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = v_user_id
      AND role = ANY (ARRAY['operator_admin','superadmin','manager'])
  ) THEN
    RAISE EXCEPTION 'abandon_intent: requires authenticated operator role';
  END IF;

  IF p_intent_id IS NULL THEN
    RAISE EXCEPTION 'p_intent_id required';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'p_reason required (non-empty)';
  END IF;

  SELECT status INTO v_existing_status
  FROM public.strategic_intents
  WHERE intent_id = p_intent_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'intent % not found', p_intent_id;
  END IF;
  IF v_existing_status NOT IN ('queued','in_progress','blocked') THEN
    RAISE EXCEPTION 'intent % is not abandonable (current status: %)',
      p_intent_id, v_existing_status;
  END IF;

  UPDATE public.strategic_intents
    SET status         = 'abandoned',
        closed_at      = now(),
        closed_by      = v_user_id,
        closure_reason = p_reason
  WHERE intent_id = p_intent_id;

  RETURN jsonb_build_object(
    'intent_id',   p_intent_id,
    'status',      'abandoned',
    'closed_by',   v_user_id,
    'reason',      p_reason
  );
END;
$function$;
