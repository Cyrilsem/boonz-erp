-- Refill System v2 / Phase 2 (#8 / F5) - refill_commit_log table + commit_refill_plan RPC.
--
-- Captures every refill-plan "commit/push" with the operator's free-text comment so push comments
-- are durably recorded (DONE-WHEN: "push comments captured"). Append-only audit-shaped log, written
-- ONLY by the DEFINER commit_refill_plan; no UPDATE/DELETE (Article 7). Table design by Dara.
-- APPLIED 2026-06-01 (CS sign-off; Cody-approved Articles 2,4,7,12,14; verified pg_proc + 3 RLS policies).

-- ── Table (Dara) ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.refill_commit_log (
  commit_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_date     date        NOT NULL,
  comment       text        NOT NULL,
  committed_by  uuid        REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  committed_at  timestamptz NOT NULL DEFAULT now(),
  machine_ids   uuid[],
  scope         text        NOT NULL DEFAULT 'all' CHECK (scope IN ('all','subset')),
  summary       jsonb       NOT NULL DEFAULT '{}'::jsonb,
  via_rpc       boolean     NOT NULL DEFAULT false,
  rpc_name      text,
  CONSTRAINT refill_commit_log_comment_nonempty CHECK (length(trim(comment)) >= 1)
);

CREATE INDEX IF NOT EXISTS idx_refill_commit_log_plan_date
  ON public.refill_commit_log (plan_date, committed_at DESC);

ALTER TABLE public.refill_commit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS refill_commit_log_select ON public.refill_commit_log;
CREATE POLICY refill_commit_log_select ON public.refill_commit_log
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles
                 WHERE id = (SELECT auth.uid())
                   AND role = ANY (ARRAY['operator_admin','superadmin','manager'])));

DROP POLICY IF EXISTS refill_commit_log_no_update ON public.refill_commit_log;
CREATE POLICY refill_commit_log_no_update ON public.refill_commit_log FOR UPDATE USING (false);

DROP POLICY IF EXISTS refill_commit_log_no_delete ON public.refill_commit_log;
CREATE POLICY refill_commit_log_no_delete ON public.refill_commit_log FOR DELETE USING (false);
-- No INSERT policy: authenticated cannot insert directly; the DEFINER RPC (owner) bypasses RLS.

-- ── RPC (canonical writer) ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.commit_refill_plan(
  p_plan_date   date,
  p_comment     text,
  p_machine_ids uuid[] DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid;
  v_scope   text;
  v_summary jsonb;
  v_commit_id uuid;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'commit_refill_plan', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id AND up.role = ANY(ARRAY['operator_admin','superadmin','manager'])
  ) THEN
    RAISE EXCEPTION 'commit_refill_plan: caller % lacks operator_admin/superadmin/manager role', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN RAISE EXCEPTION 'p_plan_date required'; END IF;
  IF p_comment IS NULL OR length(trim(p_comment)) < 1 THEN
    RAISE EXCEPTION 'p_comment required (non-empty)';
  END IF;

  v_scope := CASE WHEN p_machine_ids IS NULL OR array_length(p_machine_ids,1) IS NULL
                  THEN 'all' ELSE 'subset' END;

  -- Snapshot of what is being committed: line counts by action + machine count, from refill_plan_output.
  WITH lines AS (
    SELECT rpo.machine_name, rpo.action
      FROM public.refill_plan_output rpo
     WHERE rpo.plan_date = p_plan_date
       AND (p_machine_ids IS NULL OR rpo.machine_name IN (
             SELECT official_name FROM public.machines WHERE machine_id = ANY(p_machine_ids)))
  ),
  by_action AS (
    SELECT action, COUNT(*) AS n FROM lines GROUP BY action
  )
  SELECT jsonb_build_object(
           'total_lines', (SELECT COUNT(*) FROM lines),
           'machines',    (SELECT COUNT(DISTINCT machine_name) FROM lines),
           'by_action',   COALESCE((SELECT jsonb_object_agg(action, n) FROM by_action), '{}'::jsonb)
         )
    INTO v_summary;

  INSERT INTO public.refill_commit_log(plan_date, comment, committed_by, machine_ids, scope, summary, via_rpc, rpc_name)
  VALUES (p_plan_date, trim(p_comment), v_user_id, p_machine_ids, v_scope, v_summary, true, 'commit_refill_plan')
  RETURNING commit_id INTO v_commit_id;

  RETURN jsonb_build_object(
    'status','ok', 'commit_id', v_commit_id, 'plan_date', p_plan_date,
    'scope', v_scope, 'summary', v_summary
  );
END;
$function$;
GRANT EXECUTE ON FUNCTION public.commit_refill_plan(date, text, uuid[]) TO authenticated;
