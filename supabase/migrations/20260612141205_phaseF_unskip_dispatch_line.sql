-- PRD-028 dispatch-state-integrity step 3: explicit, logged un-skip writer.
-- APPLIED to prod 2026-06-12 via MCP as phaseF_unskip_dispatch_line (version 20260612141205).
-- set_dispatch_include only flips include and cannot clear skipped; with the
-- phaseF_dispatch_state_guards refusals live, skipped lines need an explicit
-- reactivation path that names the actor (PRD section 2a).
CREATE OR REPLACE FUNCTION public.unskip_dispatch_line(p_dispatch_id uuid, p_actor uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_d refill_dispatching%ROWTYPE;
  v_actor uuid;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'unskip_dispatch_line', true);
  v_actor := COALESCE(p_actor, auth.uid());
  SELECT * INTO v_d FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_d.cancelled = true THEN
    RAISE EXCEPTION 'unskip_dispatch_line: dispatch % is CANCELLED (skip_reason: %). Cancellation cannot be reversed from packing.', p_dispatch_id, COALESCE(v_d.skip_reason, 'no reason recorded');
  END IF;
  IF v_d.skipped = false AND COALESCE(v_d.include, true) = true THEN
    RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'status', 'noop', 'message', 'line is not skipped or excluded');
  END IF;
  PERFORM set_config('app.mutation_reason',
    format('unskip_dispatch_line: dispatch %s re-activated by %s (was skipped=%s include=%s, skip_reason: %s)',
      p_dispatch_id, COALESCE(v_actor::text, 'unknown actor'), v_d.skipped, v_d.include, COALESCE(v_d.skip_reason, 'none')),
    true);
  UPDATE refill_dispatching SET skipped = false, include = true WHERE dispatch_id = p_dispatch_id;
  RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'status', 'unskipped', 'by', v_actor, 'previous_skip_reason', v_d.skip_reason);
END;
$function$;
