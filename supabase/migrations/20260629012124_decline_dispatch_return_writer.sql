-- decline_dispatch_return - force-decline a VOX/Remove dispatch return with NO warehouse credit.
-- GENERATED FROM LIVE PROD for git parity (PRD-ALL overnight run, 2026-06-30).
-- Already applied to prod as supabase_migrations version 20260629012124 (decline_dispatch_return_writer)
-- via MCP apply_migration. This file reproduces the live function definition verbatim. Idempotent
-- (CREATE OR REPLACE). DO NOT re-run as a new migration; it is already in prod history.

CREATE OR REPLACE FUNCTION public.decline_dispatch_return(p_dispatch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_role text;
  v_row  public.refill_dispatching%ROWTYPE;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','decline_dispatch_return',true);

  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'decline_dispatch_return: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  IF p_reason IS NULL OR length(trim(p_reason)) < 5 THEN
    RAISE EXCEPTION 'decline_dispatch_return: p_reason required (>= 5 chars)';
  END IF;

  SELECT * INTO v_row FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'decline_dispatch_return: dispatch % not found', p_dispatch_id; END IF;
  IF v_row.action <> 'Remove' THEN
    RAISE EXCEPTION 'decline_dispatch_return: only Remove lines (got %)', v_row.action;
  END IF;
  IF COALESCE(v_row.item_added,false) OR COALESCE(v_row.returned,false) OR v_row.wh_approved_at IS NOT NULL THEN
    RETURN jsonb_build_object('status','noop','dispatch_id',p_dispatch_id,'note','already resolved');
  END IF;

  PERFORM set_config('app.mutation_reason', p_reason, true);

  UPDATE public.refill_dispatching
     SET returned = true,
         return_reason = p_reason,
         include = false
   WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object('status','declined','dispatch_id',p_dispatch_id,
    'no_wh_credit', true, 'no_pod_change', true, 'reason', p_reason);
END
$function$;
