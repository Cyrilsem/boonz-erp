-- PRD-019 Phase E: atomic commit RPC (supersedes the FE D2 saga).
-- NOT APPLIED. Author-only; apply after CS sign-off (after 110411-110416).
-- A plpgsql DEFINER function runs in ONE transaction: any RAISE rolls back the
-- whole chain, so the pipeline can never land "stitched but dispatch empty".
--
-- Commit does NOT re-finalize (corrected 2026-06-16). The reviewed pod_refill_plan
-- draft IS the source of truth at commit time. engine_finalize_pod first does
-- `UPDATE pod_refill_plan SET status='superseded' WHERE status='draft' AND machine_id=ANY(ids)`
-- then rebuilds the draft from pod_refills. Any row living only in pod_refill_plan
-- (every add_pod_refill_row / swap_pod_refill_row / edit_pod_refill_row qty change)
-- is NOT in pod_refills, so re-finalizing inside Commit would erase manual
-- adds/swaps and revert manual edits (the PRD-018 clobber). Finalize belongs only
-- to the BUILD path (cron + Path C); Commit never calls it.
--
-- Chain: lock assert -> approve_pod_refill_plan -> stitch_pod_to_boonz(false)
--        -> approve_refill_plan -> invariants. approve_pod_refill_plan stays
-- because stitch RAISES 'no approved rows' unless pod_refill_plan.status='approved'.
-- approve_refill_plan SWALLOWS exceptions (returns {status:error}); stitch reports
-- lines_built + write_result.status. So inspect each return AND run hard invariants.
-- The dispatch write happens inside approve_refill_plan (direct INSERT) within this
-- same transaction, so the counts below see it and roll back with everything else.
CREATE OR REPLACE FUNCTION public.commit_refill_plan_atomic(
  p_plan_date     date,
  p_machine_names text[]
) RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
DECLARE
  v_user        uuid;
  v_lock_ctx    text;
  v_ids         uuid[];
  v_stitch      jsonb;
  v_appr        jsonb;
  v_lines_built integer;
  v_output_rows integer;
  v_dispatch_rows integer;
  v_no_dispatch text[];
  v_soft        jsonb := '[]'::jsonb;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'commit_refill_plan_atomic', true);

  v_user := auth.uid();
  IF v_user IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user AND up.role = ANY (ARRAY['operator_admin','superadmin','manager'])
  ) THEN
    RAISE EXCEPTION 'commit_refill_plan_atomic: caller % lacks operator_admin/manager role', v_user;
  END IF;

  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'commit_refill_plan_atomic: p_plan_date required';
  END IF;
  IF p_machine_names IS NULL OR array_length(p_machine_names, 1) IS NULL THEN
    RAISE EXCEPTION 'commit_refill_plan_atomic: p_machine_names must be a non-empty array';
  END IF;

  -- (1) Assert/acquire the single-writer lock under the 'commit' context. If the
  -- FE already acquired it, this is re-entrant; a foreign context is rejected.
  SELECT context INTO v_lock_ctx FROM public.refill_plan_lock WHERE plan_date = p_plan_date FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO public.refill_plan_lock (plan_date, locked_by, locked_at, context)
    VALUES (p_plan_date, v_user, now(), 'commit');
  ELSIF v_lock_ctx <> 'commit' THEN
    RAISE EXCEPTION 'commit_refill_plan_atomic: plan % is locked by context "%"; commit refused (PRD-019 D1).', p_plan_date, v_lock_ctx;
  END IF;
  PERFORM set_config('app.refill_lock_context', 'commit', false);

  -- (2) Resolve names -> ids for the dispatch verification below.
  SELECT array_agg(m.machine_id) INTO v_ids
  FROM public.machines m WHERE m.official_name = ANY (p_machine_names);
  IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'commit_refill_plan_atomic: none of the named machines resolve to a machine_id';
  END IF;

  -- (3) Approve the reviewed pod draft (stitch only reads status='approved'),
  -- scoped to names. NO finalize: the draft as reviewed is the source of truth.
  PERFORM public.approve_pod_refill_plan(p_plan_date, p_machine_names);

  -- (4) Stitch (commit mode). Must write ok, else roll back.
  v_stitch := public.stitch_pod_to_boonz(p_plan_date, false);
  v_lines_built := COALESCE((v_stitch->>'lines_built')::int, 0);
  IF COALESCE(v_stitch->'write_result'->>'status', '') <> 'ok' THEN
    RAISE EXCEPTION 'commit_refill_plan_atomic: stitch write_result=% — rolling back (PRD-019 E2).', COALESCE(v_stitch->'write_result'->>'status', 'null');
  END IF;

  -- (5) Approve the boonz plan -> writes refill_dispatching (the dispatch bridge),
  -- always the FINAL write step. approve_refill_plan swallows errors, so check.
  v_appr := public.approve_refill_plan(p_plan_date, p_machine_names);
  IF COALESCE(v_appr->>'status', '') <> 'ok' THEN
    RAISE EXCEPTION 'commit_refill_plan_atomic: approve_refill_plan failed (%) — rolling back.', COALESCE(v_appr->>'error', v_appr::text);
  END IF;

  -- (6) Verified counts (in-transaction).
  SELECT COUNT(*) INTO v_output_rows
  FROM public.refill_plan_output
  WHERE plan_date = p_plan_date AND machine_name = ANY (p_machine_names)
    AND operator_status = 'approved';

  SELECT COUNT(*) INTO v_dispatch_rows
  FROM public.refill_dispatching
  WHERE dispatch_date = p_plan_date AND machine_id = ANY (v_ids) AND include = true;

  -- HARD invariant (set-level): the commit produced real output across the set.
  -- Catches the empty-stitch bug. A single dud machine does NOT trip this.
  IF v_lines_built = 0 OR v_output_rows = 0 OR v_dispatch_rows = 0 THEN
    RAISE EXCEPTION
      'commit_refill_plan_atomic: empty commit (lines_built=%, output_rows=%, dispatch_rows=%) — rolling back (PRD-019 E2).',
      v_lines_built, v_output_rows, v_dispatch_rows;
  END IF;

  -- SOFT flag (report, never roll back): named machines that produced 0 actionable
  -- dispatch rows (everything blocked/dropped). Complete-but-Partial (cf. PRD-020).
  SELECT array_agg(name) INTO v_no_dispatch
  FROM unnest(p_machine_names) AS name
  WHERE NOT EXISTS (
    SELECT 1 FROM public.refill_dispatching d
    JOIN public.machines m ON m.machine_id = d.machine_id
    WHERE d.dispatch_date = p_plan_date AND m.official_name = name AND d.include = true);

  IF v_no_dispatch IS NOT NULL THEN
    SELECT jsonb_agg(jsonb_build_object('machine', name, 'note', 'committed_no_actionable_lines'))
      INTO v_soft FROM unnest(v_no_dispatch) AS name;
  END IF;

  RETURN jsonb_build_object(
    'status', 'ok',
    'plan_date', p_plan_date,
    'machines', array_length(v_ids, 1),
    'output_rows', v_output_rows,
    'dispatch_rows', v_dispatch_rows,
    'lines_built', v_lines_built,
    'soft_flags', v_soft
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.commit_refill_plan_atomic(date, text[]) TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.commit_refill_plan_atomic(date, text[]) IS
'PRD-019 Phase E (corrected 2026-06-16). Single-transaction commit: assert/acquire lock(commit) -> approve_pod_refill_plan -> stitch_pod_to_boonz(false) -> approve_refill_plan. Does NOT re-finalize (the reviewed pod_refill_plan draft is the source of truth; finalize would clobber manual adds/swaps/edits). HARD rollback only on a set-level empty commit (lines_built/output_rows/dispatch_rows all must be > 0); per-machine zero-dispatch is a SOFT flag (committed_no_actionable_lines), never a rollback. Returns verified {output_rows, dispatch_rows, machines, lines_built, soft_flags}.';
