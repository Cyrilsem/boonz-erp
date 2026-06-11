-- Refill System v2 / Phase 2 (#7) - reset_and_restitch: re-derive + re-stitch a plan subset.
--
-- Today, correcting a live plan for a few machines requires ~8 raw dispatch edits. This RPC makes
-- that a single canonical call that COMPOSES the existing writers (no new raw write path beyond the
-- reset status-flip, which mirrors void_refill_plan's archive-only pattern):
--   (1) RESET   - supersede ALL active pod_refill_plan rows for the subset. Per CS, this is a FULL
--                 reset: manual adds AND manual qty-edits are discarded (manual adds have no engine
--                 source so they stay superseded; manual qty-edits on engine rows are overwritten in
--                 step 2's ON CONFLICT DO UPDATE).
--   (2) FINALIZE- engine_finalize_pod(p_plan_date, p_machine_ids)  [#6 subset-aware] re-derives the
--                 engine rows from pod_refills + pod_swaps back to status='draft'.
--   (3) APPROVE - approve_pod_refill_plan(p_plan_date, <subset names>) flips those drafts -> approved.
--   (4) STITCH  - stitch_pod_to_boonz(p_plan_date, false) re-emits refill_plan_output. SAFE for the
--                 rest of the fleet: write_refill_plan deletes per-machine AND pending-only, so
--                 already-dispatched (non-pending) machines are never touched.
--
-- DISPATCH GUARD: refuses if any subset refill_plan_output row is past 'pending' (already dispatched),
-- same posture as void/reschedule.
--
-- CAVEAT (documented): stitch is whole-plan (reads all status='approved' rows for the date), not
-- subset-aware like finalize now is. In steady state the subset is the only thing in 'approved'
-- (other machines are already 'stitched'), and the per-machine pending-only write bounds the blast
-- radius, so this is safe. Making stitch itself subset-aware is a separate future change.
--
-- Role gate: operator_admin/superadmin, with service-role bypass (auth.uid() IS NULL). reason >= 10.
-- APPLIED 2026-06-01 (CS sign-off; Cody-approved Articles 1,4,5,8,12; verified pg_proc).

CREATE OR REPLACE FUNCTION public.reset_and_restitch(
  p_plan_date   date,
  p_machine_ids uuid[],
  p_reason      text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id        uuid;
  v_machine_names  text[];
  v_dispatched     integer;
  v_reset          integer;
  v_approved_total integer;
  v_finalize       jsonb;
  v_approve        jsonb;
  v_stitch         jsonb;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'reset_and_restitch', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id AND up.role = ANY(ARRAY['operator_admin','superadmin'])
  ) THEN
    RAISE EXCEPTION 'reset_and_restitch: caller % lacks operator_admin/superadmin role', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN RAISE EXCEPTION 'p_plan_date required'; END IF;
  IF p_machine_ids IS NULL OR array_length(p_machine_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'p_machine_ids required (non-empty array)';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>= 10 chars)';
  END IF;

  -- Resolve official_names for approve_pod_refill_plan (takes text[]); also validates the ids exist.
  SELECT array_agg(m.official_name) INTO v_machine_names
    FROM public.machines m WHERE m.machine_id = ANY(p_machine_ids);
  IF v_machine_names IS NULL OR array_length(v_machine_names, 1) <> array_length(p_machine_ids, 1) THEN
    RAISE EXCEPTION 'reset_and_restitch: one or more machine_ids not found';
  END IF;

  -- Dispatch guard: refuse if any subset dispatch line is past 'pending'.
  SELECT COUNT(*) INTO v_dispatched
    FROM public.refill_plan_output rpo
   WHERE rpo.plan_date = p_plan_date
     AND rpo.machine_name = ANY(v_machine_names)
     AND rpo.operator_status <> 'pending';
  IF v_dispatched > 0 THEN
    RAISE EXCEPTION 'reset_and_restitch: % subset dispatch line(s) past pending; refusing to reset dispatched machine(s)', v_dispatched;
  END IF;

  -- (1) RESET: supersede all active subset plan rows (full reset; discards manual adds).
  UPDATE public.pod_refill_plan
     SET status     = 'superseded',
         reasoning  = COALESCE(reasoning, '{}'::jsonb)
                      || jsonb_build_object('reset_and_restitch', p_reason, 'reset_at', now()),
         updated_at = now()
   WHERE plan_date  = p_plan_date
     AND machine_id = ANY(p_machine_ids)
     AND status NOT IN ('superseded','voided');
  GET DIAGNOSTICS v_reset = ROW_COUNT;

  -- (2) RE-DERIVE engine rows -> draft (subset-aware finalize).
  v_finalize := public.engine_finalize_pod(p_plan_date, p_machine_ids);

  -- (3) APPROVE the subset's fresh drafts -> approved.
  v_approve := public.approve_pod_refill_plan(p_plan_date, v_machine_names);

  -- (4) RE-STITCH -> refill_plan_output, only if there is something approved to stitch.
  SELECT COUNT(*) INTO v_approved_total
    FROM public.pod_refill_plan
   WHERE plan_date = p_plan_date AND status = 'approved';
  IF v_approved_total > 0 THEN
    v_stitch := public.stitch_pod_to_boonz(p_plan_date, false);
  ELSE
    v_stitch := jsonb_build_object('status','skipped','reason','no approved rows after re-derive');
  END IF;

  RETURN jsonb_build_object(
    'reset_and_restitch', 'done',
    'plan_date',     p_plan_date,
    'machine_ids',   p_machine_ids,
    'machine_names', v_machine_names,
    'rows_reset',    v_reset,
    'finalize',      v_finalize,
    'approve',       v_approve,
    'stitch',        v_stitch,
    'engine_version','v1_compose_finalize_approve_stitch'
  );
END;
$function$;
GRANT EXECUTE ON FUNCTION public.reset_and_restitch(date, uuid[], text) TO authenticated;
