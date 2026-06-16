-- PRD-019 D1a: single-writer plan lock for the refill pipeline.
-- NOT APPLIED. Author-only per PRD-019 rules; apply after CS sign-off.
-- New table refill_plan_lock + canonical DEFINER writers acquire/release.
-- Chat-engine (service) AND FE Commit (operator_admin) both acquire; the second
-- caller for the same plan_date is rejected with a clear error. Prevents the
-- 2026-06-15/16 chat/FE stitch collision (R-D1).
--
-- Constitution notes:
--  - refill_plan_lock is an ephemeral coordination table, NOT a protected entity.
--    release legitimately DELETEs the lock row (that IS the release); the
--    no_delete RLS policy blocks direct authenticated DELETE, the DEFINER writer
--    (owner) bypasses RLS. This is the one place a DELETE is the correct verb.
--  - Both writers set app.via_rpc + app.rpc_name, validate role + inputs, and the
--    generic audit trigger (audit_log_write) records every mutation (Article 8).

CREATE TABLE IF NOT EXISTS public.refill_plan_lock (
  plan_date  date PRIMARY KEY,
  locked_by  uuid,
  locked_at  timestamptz NOT NULL DEFAULT now(),
  context    text NOT NULL
);

COMMENT ON TABLE public.refill_plan_lock IS
'PRD-019 D1a single-writer lock: at most one writer context per plan_date may drive the refill pipeline. Acquired via acquire_refill_plan_lock, released via release_refill_plan_lock. Ephemeral coordination table (not a protected entity).';

ALTER TABLE public.refill_plan_lock ENABLE ROW LEVEL SECURITY;

-- Read for operator/manager/superadmin (mirrors refill_commit_log).
CREATE POLICY refill_plan_lock_select ON public.refill_plan_lock
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE user_profiles.id = (SELECT auth.uid())
      AND user_profiles.role = ANY (ARRAY['operator_admin','superadmin','manager'])
  ));

-- No direct authenticated writes; the DEFINER writers (table owner) bypass RLS.
CREATE POLICY refill_plan_lock_no_update ON public.refill_plan_lock
  FOR UPDATE TO authenticated USING (false);
CREATE POLICY refill_plan_lock_no_delete ON public.refill_plan_lock
  FOR DELETE TO authenticated USING (false);
CREATE POLICY refill_plan_lock_no_insert ON public.refill_plan_lock
  FOR INSERT TO authenticated WITH CHECK (false);

-- Universal audit (Article 8): fires once app.via_rpc is set by the writer.
-- audit_log_write reads the PK column from TG_ARGV[0] (defaults to 'id'); this
-- table is keyed by plan_date, so it MUST be passed explicitly or the trigger
-- throws "column id does not exist" on every write.
CREATE TRIGGER tg_audit_refill_plan_lock
  AFTER INSERT OR UPDATE OR DELETE ON public.refill_plan_lock
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_write('plan_date');

-- ── acquire ────────────────────────────────────────────────────────────────
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
  v_stale_min integer := 30;  -- a lock older than this is assumed orphaned and may be stolen
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

  -- Mark this session's writer context so its own subsequent engine calls pass
  -- the D1b guard. Session-scoped (is_local = false) so it survives across the
  -- caller's commit chain within the same connection.
  PERFORM set_config('app.refill_lock_context', p_context, false);

  -- Race-safe claim: insert wins, conflict falls through to the holder logic.
  INSERT INTO public.refill_plan_lock (plan_date, locked_by, locked_at, context)
  VALUES (p_plan_date, v_user, now(), p_context)
  ON CONFLICT (plan_date) DO NOTHING;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'acquired', true, 'plan_date', p_plan_date, 'context', p_context, 'locked_at', now());
  END IF;

  SELECT * INTO v_existing FROM public.refill_plan_lock WHERE plan_date = p_plan_date FOR UPDATE;

  IF v_existing.context = p_context THEN
    -- Re-entrant acquire by the same context: refresh, allow.
    UPDATE public.refill_plan_lock
       SET locked_by = COALESCE(v_user, locked_by), locked_at = now()
     WHERE plan_date = p_plan_date;
    RETURN jsonb_build_object(
      'acquired', true, 'reentrant', true, 'plan_date', p_plan_date, 'context', p_context);
  END IF;

  IF v_existing.locked_at < now() - make_interval(mins => v_stale_min) THEN
    -- Orphaned lock (caller crashed without releasing): steal it, record the takeover.
    UPDATE public.refill_plan_lock
       SET locked_by = v_user, locked_at = now(), context = p_context
     WHERE plan_date = p_plan_date;
    RETURN jsonb_build_object(
      'acquired', true, 'stole_stale_lock', true,
      'previous_context', v_existing.context, 'previous_locked_at', v_existing.locked_at,
      'plan_date', p_plan_date, 'context', p_context);
  END IF;

  RAISE EXCEPTION
    'acquire_refill_plan_lock: plan_date % is already locked by context "%" since % (locked_by %). Second writer rejected (PRD-019 D1a). Wait for release_refill_plan_lock or retry after the holder finishes.',
    p_plan_date, v_existing.context, v_existing.locked_at, v_existing.locked_by;
END;
$function$;

-- ── release ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.release_refill_plan_lock(
  p_plan_date date
) RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
DECLARE
  v_user uuid;
  v_n    integer;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'release_refill_plan_lock', true);

  v_user := auth.uid();
  IF v_user IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user AND up.role = ANY (ARRAY['operator_admin','superadmin','manager'])
  ) THEN
    RAISE EXCEPTION 'release_refill_plan_lock: caller % lacks operator_admin/manager role', v_user;
  END IF;

  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'release_refill_plan_lock: p_plan_date required';
  END IF;

  DELETE FROM public.refill_plan_lock WHERE plan_date = p_plan_date;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  PERFORM set_config('app.refill_lock_context', '', false);

  RETURN jsonb_build_object('released', v_n > 0, 'plan_date', p_plan_date);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.acquire_refill_plan_lock(date, text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.release_refill_plan_lock(date)       TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.acquire_refill_plan_lock(date, text) IS
'PRD-019 D1a. Claims the single-writer lock for a plan_date under a named context (commit, chat_engine). Re-entrant for the same context; steals locks older than 30 min; rejects a second live context with a clear error. Sets session GUC app.refill_lock_context so the holder''s own engine calls pass the D1b guard.';
COMMENT ON FUNCTION public.release_refill_plan_lock(date) IS
'PRD-019 D1a. Releases the plan_date lock (DELETE is the release) and clears app.refill_lock_context.';
