-- PRD-019 F2: lock TTL 15 min (was 30) + operator force-release.
-- NOT APPLIED. Author-only; apply after CS sign-off (after 110411 D1a).
-- Re-CREATEs acquire_refill_plan_lock with a 15-minute stale window, and adds a
-- gated, audited manual override. Forward-only (supersedes the 30-min body).

CREATE OR REPLACE FUNCTION public.acquire_refill_plan_lock(
  p_plan_date date,
  p_context   text DEFAULT 'unknown'
) RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
DECLARE
  v_user      uuid;
  v_existing  public.refill_plan_lock%ROWTYPE;
  v_stale_min integer := 15;  -- PRD-019 F2: was 30. Older than this = orphaned, stealable.
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'acquire_refill_plan_lock', true);

  v_user := auth.uid();
  IF v_user IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user AND up.role = ANY (ARRAY['operator_admin','superadmin','manager'])
  ) THEN
    RAISE EXCEPTION 'acquire_refill_plan_lock: caller % lacks operator_admin/manager role', v_user;
  END IF;

  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'acquire_refill_plan_lock: p_plan_date required';
  END IF;
  IF p_context IS NULL OR btrim(p_context) = '' THEN
    RAISE EXCEPTION 'acquire_refill_plan_lock: p_context required (e.g. commit, chat_engine)';
  END IF;

  PERFORM set_config('app.refill_lock_context', p_context, false);

  INSERT INTO public.refill_plan_lock (plan_date, locked_by, locked_at, context)
  VALUES (p_plan_date, v_user, now(), p_context)
  ON CONFLICT (plan_date) DO NOTHING;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'acquired', true, 'plan_date', p_plan_date, 'context', p_context, 'locked_at', now());
  END IF;

  SELECT * INTO v_existing FROM public.refill_plan_lock WHERE plan_date = p_plan_date FOR UPDATE;

  IF v_existing.context = p_context THEN
    UPDATE public.refill_plan_lock
       SET locked_by = COALESCE(v_user, locked_by), locked_at = now()
     WHERE plan_date = p_plan_date;
    RETURN jsonb_build_object(
      'acquired', true, 'reentrant', true, 'plan_date', p_plan_date, 'context', p_context);
  END IF;

  IF v_existing.locked_at < now() - make_interval(mins => v_stale_min) THEN
    UPDATE public.refill_plan_lock
       SET locked_by = v_user, locked_at = now(), context = p_context
     WHERE plan_date = p_plan_date;
    RETURN jsonb_build_object(
      'acquired', true, 'stole_stale_lock', true,
      'previous_context', v_existing.context, 'previous_locked_at', v_existing.locked_at,
      'plan_date', p_plan_date, 'context', p_context);
  END IF;

  RAISE EXCEPTION
    'acquire_refill_plan_lock: plan_date % is already locked by context "%" since % (locked_by %). Second writer rejected (PRD-019 D1a). Wait for release_refill_plan_lock or use force_release_refill_plan_lock.',
    p_plan_date, v_existing.context, v_existing.locked_at, v_existing.locked_by;
END;
$function$;

-- Manual override for a wedged lock: operator_admin/superadmin only, reason >= 10
-- chars (audited via the table trigger + mutation_reason).
CREATE OR REPLACE FUNCTION public.force_release_refill_plan_lock(
  p_plan_date date,
  p_reason    text
) RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
DECLARE
  v_user uuid;
  v_existing public.refill_plan_lock%ROWTYPE;
  v_n integer;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'force_release_refill_plan_lock', true);

  v_user := auth.uid();
  IF v_user IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user AND up.role = ANY (ARRAY['operator_admin','superadmin'])
  ) THEN
    RAISE EXCEPTION 'force_release_refill_plan_lock: caller % lacks operator_admin/superadmin role', v_user;
  END IF;
  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'force_release_refill_plan_lock: p_plan_date required';
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'force_release_refill_plan_lock: p_reason required (>= 10 chars) for the audit trail';
  END IF;

  SELECT * INTO v_existing FROM public.refill_plan_lock WHERE plan_date = p_plan_date;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('released', false, 'plan_date', p_plan_date, 'note', 'no lock held');
  END IF;

  PERFORM set_config('app.mutation_reason',
    format('force_release_refill_plan_lock: %s stole context "%s" (held since %s) - reason: %s',
      COALESCE(v_user::text, 'service'), v_existing.context, v_existing.locked_at, p_reason),
    true);

  DELETE FROM public.refill_plan_lock WHERE plan_date = p_plan_date;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object(
    'released', v_n > 0, 'plan_date', p_plan_date,
    'forced_from_context', v_existing.context, 'previous_locked_at', v_existing.locked_at);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.acquire_refill_plan_lock(date, text)        TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.force_release_refill_plan_lock(date, text)   TO authenticated, service_role;

COMMENT ON FUNCTION public.force_release_refill_plan_lock(date, text) IS
'PRD-019 F2. Operator override for a wedged plan lock. operator_admin/superadmin only; reason >= 10 chars; the delete is audited with the actor + prior holder + reason.';
