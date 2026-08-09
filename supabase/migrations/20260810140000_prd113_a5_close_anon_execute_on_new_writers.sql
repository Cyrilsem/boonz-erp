-- PRD-113 A5 — close the `anon` EXECUTE surface on the three functions A2 added.
--
-- Found by `get_advisors(security)` immediately after A2 applied, and it is a defect A2
-- introduced, not a pre-existing one. Article 12: fixed forward, not by editing A2.
--
-- WHAT WAS WRONG
--   Supabase grants EXECUTE on every new function to PUBLIC by default, so A2's explicit
--   `GRANT ... TO authenticated, service_role` was additive noise on top of a grant `anon`
--   already held. All three functions were reachable at `/rest/v1/rpc/<name>` unauthenticated.
--
--   For `clear_internal_move_flag` that was merely untidy: it refuses a NULL `auth.uid()`
--   outright, so `anon` could never reach the write.
--
--   ⛔ For `mark_internal_move_legs` it was a REAL HOLE. Its role check reads:
--
--        IF v_uid IS NOT NULL THEN ...check the role... END IF;
--
--   which trusts a NULL uid as "the service_role / cron context". An `anon` caller also has
--   `auth.uid() = NULL`, so an unauthenticated POST would have skipped the role check
--   entirely and relabelled dispatch legs on any plan date it liked. Every leg it flagged
--   would have dropped out of the warehouse return queue — the exact denial-of-credit this
--   PRD is trying to make impossible in the other direction.
--
--   `tg_mark_internal_move_pair` is a trigger function and was likewise exposed. Calling it
--   over REST raises "trigger functions can only be called as triggers", so it was never
--   exploitable — but a trigger function has no business being an RPC endpoint at all.
--
-- TWO INDEPENDENT FIXES, because either alone would be luck rather than posture:
--   (1) REVOKE the grant, so the endpoints stop existing for `anon` / `PUBLIC`.
--   (2) Make the NULL-uid branch name the roles it actually means, so the guard holds even
--       if a future migration re-grants EXECUTE (the S-308 lesson: a default grant comes back
--       whenever someone is not looking).
--
-- ADDITIVE ONLY: one REVOKE set and one CREATE OR REPLACE. No signature changes.

REVOKE EXECUTE ON FUNCTION public.mark_internal_move_legs(date, uuid)  FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.clear_internal_move_flag(uuid, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.tg_mark_internal_move_pair()         FROM PUBLIC, anon, authenticated;

-- Fix (2): the NULL-uid branch now names the roles it means. Under PostgREST an anonymous
-- request runs as `anon` and a service-key request as `service_role`, so `current_user` is
-- the discriminator that `auth.uid() IS NULL` only pretended to be. Body is otherwise
-- identical to the A2 version.
CREATE OR REPLACE FUNCTION public.mark_internal_move_legs(
  p_dispatch_date date,
  p_machine_id    uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_marked   int := 0;
  v_uid      uuid := (SELECT auth.uid());
  v_role     text;
  v_prev_via text;
  v_ids      uuid[];
BEGIN
  IF p_dispatch_date IS NULL THEN
    RAISE EXCEPTION 'mark_internal_move_legs: p_dispatch_date is required';
  END IF;

  -- Article 4: validate the caller.
  IF v_uid IS NULL THEN
    -- PRD-113 A5: a NULL uid is ONLY the trusted backend context when the database role
    -- says so. `anon` also has a NULL uid, and the A2 body let it straight through.
    IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
      RAISE EXCEPTION 'mark_internal_move_legs: unauthenticated callers may not relabel dispatch legs (db role %)', current_user;
    END IF;
  ELSE
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    IF COALESCE(v_role, '') NOT IN ('warehouse', 'operator_admin', 'superadmin', 'manager') THEN
      RAISE EXCEPTION 'mark_internal_move_legs: role % may not relabel dispatch legs (need warehouse / operator_admin / superadmin / manager)',
        COALESCE(v_role, 'unknown');
    END IF;
  END IF;

  -- Article 4: provenance. mark_internal_move_legs is in the
  -- enforce_canonical_dispatch_write allowlist, so these two GUCs are what make its write a
  -- sanctioned one rather than a logged bypass.
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'mark_internal_move_legs', true);
  PERFORM set_config('app.mutation_reason',
    format('mark_internal_move_legs by %s on plan %s (machine %s): labelling in-machine move legs so they leave the warehouse return queue',
      COALESCE(v_uid::text, 'service_role'), p_dispatch_date,
      COALESCE(p_machine_id::text, 'ALL')), true);

  -- Restore before returning: a transaction-local set_config leaks into every later
  -- statement of the same transaction (the PRD-016B provenance-GUC leak).
  v_prev_via := current_setting('app.via_trigger', true);
  PERFORM set_config('app.via_trigger', 'true', true);

  WITH upd AS (
    UPDATE public.refill_dispatching rd
       SET is_internal_move = true
     WHERE rd.dispatch_date = p_dispatch_date
       AND (p_machine_id IS NULL OR rd.machine_id = p_machine_id)
       AND rd.action = 'Remove'
       AND rd.boonz_product_id IS NOT NULL
       AND rd.internal_move_cleared_at IS NULL
       AND COALESCE(rd.is_internal_move, false) = false
       AND COALESCE(rd.is_m2m,           false) = false
       AND COALESCE(rd.cancelled,        false) = false
       AND COALESCE(rd.returned,         false) = false
       AND COALESCE(rd.item_added,       false) = false
       AND rd.wh_approved_at IS NULL
       AND COALESCE(public.is_internal_move_dispatch(rd.dispatch_id), false)
    RETURNING rd.dispatch_id
  )
  SELECT array_agg(dispatch_id), count(*)::int INTO v_ids, v_marked FROM upd;

  PERFORM set_config('app.via_trigger', COALESCE(v_prev_via, ''), true);

  IF COALESCE(v_marked, 0) > 0 THEN
    INSERT INTO public.monitoring_alerts (source, severity, payload)
    VALUES ('prd113_internal_move_flagged', 'info',
      jsonb_build_object(
        'writer',        'mark_internal_move_legs',
        'actor',         v_uid,
        'db_role',       current_user,
        'dispatch_date', p_dispatch_date,
        'machine_id',    p_machine_id,
        'rows_marked',   v_marked,
        'dispatch_ids',  to_jsonb(v_ids),
        'message',       'In-machine move legs excluded from the warehouse return queue. '
                      || 'If any of these is a GENUINE return, call '
                      || 'clear_internal_move_flag(dispatch_id, reason).'));
  END IF;

  RETURN jsonb_build_object(
    'status',        'ok',
    'dispatch_date', p_dispatch_date,
    'machine_id',    p_machine_id,
    'rows_marked',   COALESCE(v_marked, 0),
    'dispatch_ids',  COALESCE(to_jsonb(v_ids), '[]'::jsonb));
END;
$function$;

-- CREATE OR REPLACE resets nothing about grants, but re-assert the intended set explicitly
-- so the posture is readable in one place rather than inferred from two migrations.
REVOKE EXECUTE ON FUNCTION public.mark_internal_move_legs(date, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.mark_internal_move_legs(date, uuid) TO authenticated, service_role;
